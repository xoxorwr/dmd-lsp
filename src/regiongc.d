// A partitioned region GC for the dmd-lsp frontend-as-library experiment.
//
// The conservative GC cannot reclaim a previous dmd universe (retained by
// globals/stack/register roots), so a long-lived in-process analyser cannot
// bound memory with per-edit resets. This GC keeps two pools:
//
//   * an *arena* for dmd's objects (allocations whose TypeInfo belongs to the
//     `dmd.` package, i.e. the compiler AST and instantiated bodies), and
//   * a *persistent* pool for everything else (druntime/phobos).
//
// `regionCheckpoint()` / `regionResetTo()` free only the arena, so the
// runtime is never disturbed, while the whole dmd universe is reclaimed
// wholesale (exact, reachability-independent) between runs.
//
// It is not a collector: `collect`/`free` are no-ops. Register with
// `--DRT-gcopt=gc:region`.

module regiongc;

import core.gc.gcinterface : GC, Root, Range, RootIterator, RangeIterator,
    BlkAttr, BlkInfo;
import core.thread.threadbase : ThreadBase;
import core.gc.registry : registerGCFactory;
static import core.memory;

import core.stdc.stdlib : c_malloc = malloc, c_free = free;
import core.stdc.string : memcpy, memset, strlen;

private:

enum CHUNK = 8 * 1024 * 1024;
enum HDR = 32;
enum ALIGN = 16;
enum MAGIC = 0x52474E;

struct Block
{
    size_t cap;
    size_t used;
    uint attr;
    uint magic;
    size_t reserved;
}

struct Chunk
{
    ubyte* base;
    size_t top;
    size_t cap;
    Chunk* next;
}

private size_t alignUp(size_t n) nothrow @nogc
{
    return (n + ALIGN - 1) & ~(ALIGN - 1);
}

// True if `ti` is a class TypeInfo from the dmd package (or its AST classes).
private bool isDmdTypeInfo(const TypeInfo ti) nothrow
{
    if (!ti)
        return false;
    // Read only plain fields (the `name` properties may allocate / not be
    // @nogc, and running during GC init is unsafe).
    foreach (m; [cast(const(void)[]) null]) {} // (no-op to keep structure clear)
    if (auto si = cast(const TypeInfo_Struct) ti)
    {
        auto m = si.mangledName; // e.g. "S3dmd..."
        foreach (i; 0 .. (m.length >= 4 ? m.length - 3 : 0))
            if (m[i] == '3' && m[i + 1] == 'd' && m[i + 2] == 'm' && m[i + 3] == 'd')
                return true;
        return false;
    }
    if (auto ci = cast(const TypeInfo_Class) ti)
    {
        auto name = ci.name;
        return name.length >= 4 && name[0] == 'd' && name[1] == 'm' && name[2] == 'd' && name[3] == '.';
    }
    // Aggregates of dmd types (arrays/pointers/AAs) belong to the run too.
    if (auto ai = cast(const TypeInfo_Array) ti)
        return ai.value !is null && isDmdTypeInfo(ai.value);
    if (auto pi = cast(const TypeInfo_Pointer) ti)
        return pi.m_next !is null && isDmdTypeInfo(pi.m_next);
    if (auto xi = cast(const TypeInfo_AssociativeArray) ti)
        return (xi.value !is null && isDmdTypeInfo(xi.value))
            || (xi.key !is null && isDmdTypeInfo(xi.key));
    if (auto ki = cast(const TypeInfo_Const) ti) // also immutable/shared
        return ki.base !is null && isDmdTypeInfo(ki.base);
    if (auto ti2 = cast(const TypeInfo_Tuple) ti)
    {
        foreach (e; ti2.elements)
            if (e !is null && isDmdTypeInfo(e))
                return true;
        return false;
    }
    return false;
}

final class RegionGC : GC
{
    Chunk* pchunks;            // persistent (runtime) chunks
    Chunk* achunks;            // arena (dmd) chunks
    Chunk* spares;             // freed arena chunks, reused across resets
    ulong allocated;
    size_t arenaUsed;
    size_t persistentUsed;

    this() nothrow {}

    private Chunk* newChunk(size_t need) nothrow
    {
        size_t cap = need > CHUNK ? need + HDR + ALIGN : CHUNK;
        // Reuse a freed arena chunk if one is big enough (bounds RSS by the
        // peak arena instead of churning malloc/free every run).
        for (Chunk* prev = null, s = spares; s; prev = s, s = s.next)
        {
            if (s.cap >= cap)
            {
                if (prev) prev.next = s.next; else spares = s.next;
                s.top = 0;
                s.next = null;
                return s;
            }
        }
        auto mem = cast(ubyte*) c_malloc(cap);
        if (!mem)
            return null;
        auto c = cast(Chunk*) c_malloc(Chunk.sizeof);
        if (!c)
        {
            c_free(mem);
            return null;
        }
        c.base = mem;
        c.top = 0;
        c.cap = cap;
        c.next = null;
        return c;
    }

    private Chunk* listOf(bool arena) nothrow @nogc
    {
        return arena ? achunks : pchunks;
    }

    private Block* headerOf(void* p) nothrow @nogc
    {
        if (!p)
            return null;
        auto h = cast(Block*)(cast(ubyte*)p - HDR);
        if (h.magic != MAGIC)
            return null;
        auto addr = cast(size_t) p;
        for (auto c = pchunks; c; c = c.next)
        {
            auto lo = cast(size_t) c.base;
            if (addr > lo && addr < lo + c.top)
                return h;
        }
        for (auto c = achunks; c; c = c.next)
        {
            auto lo = cast(size_t) c.base;
            if (addr > lo && addr < lo + c.top)
                return h;
        }
        return null;
    }

    void* allocArena(size_t size) nothrow
    {
        return alloc(size, 0, null, true);
    }

    private void* alloc(size_t size, uint bits, const TypeInfo ti, bool forceArena = false) nothrow
    {
        if (size < ALIGN)
            size = ALIGN;
        size_t cap = alignUp(size);
        size_t need = HDR + cap;
        // dmd's internal allocations go through `dmd.root.rmem.mem`, which
        // calls `GC.malloc(size)` with a null TypeInfo. Route those (and the
        // dmd-package classes) to the arena; everything typed from the
        // runtime stays persistent.
        bool arena = forceArena || allToArena || isDmdTypeInfo(ti) || ((bits & 0x80000000) != 0);
        Chunk* c = arena ? achunks : pchunks;
        if (!c || c.top + need > c.cap)
        {
            auto nc = newChunk(need);
            if (!nc)
                return null;
            nc.next = c;
            c = nc;
            if (arena) achunks = c; else pchunks = c;
        }
        auto b = cast(Block*)(c.base + c.top);
        b.cap = cap;
        b.used = (bits & BlkAttr.APPENDABLE) ? size : 0;
        b.attr = bits & 0xFF;
        b.magic = MAGIC;
        auto payload = c.base + c.top + HDR;
        c.top += need;
        allocated += cap;
        if (arena)
        {
            arenaUsed += cap;
            if (ti is null) arenNullTi++;
            bumpArena(cast(void*) ti, cap);
            if (traceArenaCaller && ti is null)
                bumpCaller(cap);
            if (traceArenaNull && ti is null && cap >= 2048 && arenaTraceShown < 40)
            {
                import core.sys.posix.dlfcn : dladdr, Dl_info;
                import core.stdc.stdio : fprintf, stderr;
                arenaTraceShown++;
                void*[16] fr;
                int nn = backtrace(fr.ptr, 16);
                fprintf(stderr, "ANULL size=%zu:\n", cap);
                foreach (k; 0 .. nn)
                {
                    Dl_info di;
                    if (dladdr(fr[k], &di) != 0 && di.dli_sname)
                        fprintf(stderr, "   %s\n", di.dli_sname);
                }
            }
        }
        else
        {
            persistentUsed += cap;
            if (ti is null && bits == 0)
            {
                import core.sys.posix.dlfcn : dladdr, Dl_info;
                import core.stdc.stdio : fprintf, stderr;
                static __gshared uint btShown;
                if (btShown < 8)
                {
                    btShown++;
                    void*[16] fr;
                    int n = backtrace(fr.ptr, 16);
                    fprintf(stderr, "NULLCALL size=%zu:\n", size);
                    foreach (i; 0 .. n)
                    {
                        Dl_info di;
                        if (dladdr(fr[i], &di) != 0 && di.dli_sname)
                            fprintf(stderr, "   %s\n", di.dli_sname);
                    }
                }
            }
            if (ti is null)
            {
                persNullTi++;
                if (bits == 0) pnBits0++;
                else if (bits & BlkAttr.FINALIZE) pnFinal++;
                else if (bits & BlkAttr.APPENDABLE) pnAppend++;
                else if (bits & BlkAttr.NO_SCAN) pnNoscan++;

            }
            bumpPers(cast(void*) ti, cap);
        }
        return payload;
    }

public:
    __gshared bool allToArena;

    override void enable() {}
    override void disable() {}
    override void collect() nothrow {}
    override void minimize() nothrow {}

    override uint getAttr(void* p) nothrow
    {
        auto b = headerOf(p);
        return b ? b.attr : 0;
    }

    override uint setAttr(void* p, uint mask) nothrow
    {
        auto b = headerOf(p);
        if (!b) return 0;
        auto old = b.attr; b.attr |= mask; return old;
    }

    override uint clrAttr(void* p, uint mask) nothrow
    {
        auto b = headerOf(p);
        if (!b) return 0;
        auto old = b.attr; b.attr &= ~mask; return old;
    }

    override void* malloc(size_t size, uint bits, const TypeInfo ti) nothrow
    {
        return alloc(size, bits, ti);
    }

    override BlkInfo qalloc(size_t size, uint bits, const scope TypeInfo ti) nothrow
    {
        auto p = alloc(size, bits, ti);
        return p ? BlkInfo(p, headerOf(p).cap, bits) : BlkInfo(null, 0, 0);
    }

    override void* calloc(size_t size, uint bits, const TypeInfo ti) nothrow
    {
        auto p = alloc(size, bits, ti);
        if (p) memset(p, 0, size);
        return p;
    }

    override void* realloc(void* p, size_t size, uint bits, const TypeInfo ti) nothrow
    {
        if (!p)
            return alloc(size, bits, ti);
        auto b = headerOf(p);
        if (!b)
            return alloc(size, bits, ti);
        size_t cap = alignUp(size == 0 ? ALIGN : size);
        if (cap <= b.cap)
            return p;
        size_t oldUsed = b.used ? b.used : b.cap;
        auto np = alloc(size, bits, ti);
        if (!np)
            return null;
        size_t copy = oldUsed < size ? oldUsed : size;
        memcpy(np, p, copy);
        auto nb = headerOf(np);
        nb.attr = b.attr;
        return np;
    }

    override size_t extend(void* p, size_t minsize, size_t maxsize, const TypeInfo ti) nothrow
    {
        auto b = headerOf(p);
        if (!b)
            return 0;
        auto addr = cast(size_t) p;
        for (int pass = 0; pass < 2; ++pass)
        {
            for (auto c = pass == 0 ? pchunks : achunks; c; c = c.next)
            {
                auto lo = cast(size_t) c.base;
                if (addr < lo || addr >= lo + c.top)
                    continue;
                size_t off = cast(size_t)(cast(ubyte*) p - c.base) - HDR;
                if (off + HDR + b.cap != c.top)
                    return 0;
                size_t freeBytes = c.cap - c.top;
                size_t grow = (freeBytes > maxsize ? maxsize : freeBytes) & ~(ALIGN - 1);
                if (grow < minsize)
                    return 0;
                b.cap += grow;
                c.top += grow;
                if (pass == 1)
                    arenaUsed += grow;
                return b.cap;
            }
        }
        return 0;
    }

    override size_t reserve(size_t size) nothrow { return 0; }
    override void free(void* p) nothrow @nogc {}

    override void* addrOf(void* p) nothrow @nogc { return headerOf(p) ? p : null; }
    override size_t sizeOf(void* p) nothrow @nogc { auto b = headerOf(p); return b ? b.cap : 0; }

    override BlkInfo query(void* p) nothrow
    {
        auto b = headerOf(p);
        return b ? BlkInfo(p, b.cap, b.attr) : BlkInfo(null, 0, 0);
    }

    override core.memory.GC.Stats stats() @safe nothrow @nogc
    {
        core.memory.GC.Stats s;
        s.usedSize = arenaUsed;
        s.allocatedInCurrentThread = allocated;
        return s;
    }

    override core.memory.GC.ProfileStats profileStats() @safe nothrow @nogc
    {
        return core.memory.GC.ProfileStats.init;
    }

    override void addRoot(void* p) nothrow @nogc {}
    override void removeRoot(void* p) nothrow @nogc {}
    override @property RootIterator rootIter() @nogc
    {
        return (scope int delegate(ref Root) nothrow dg) nothrow { return 0; };
    }
    override void addRange(void* p, size_t sz, const TypeInfo ti) nothrow @nogc {}
    override void removeRange(void* p) nothrow @nogc {}
    override @property RangeIterator rangeIter() @nogc
    {
        return (scope int delegate(ref Range) nothrow dg) nothrow { return 0; };
    }
    override void runFinalizers(const scope void[] segment) nothrow {}
    override bool inFinalizer() nothrow @nogc @safe { return false; }
    override ulong allocatedInCurrentThread() nothrow { return allocated; }

    override void[] getArrayUsed(void* ptr, bool atomic = false) nothrow
    {
        auto b = headerOf(ptr);
        if (!b || !(b.attr & BlkAttr.APPENDABLE))
            return null;
        return cast(void[]) (cast(ubyte*) ptr)[0 .. b.used];
    }
    override bool expandArrayUsed(void[] slice, size_t newUsed, bool atomic = false) nothrow @trusted
    {
        auto b = headerOf(slice.ptr);
        if (!b || newUsed > b.cap) return false;
        b.used = newUsed; return true;
    }
    override size_t reserveArrayCapacity(void[] slice, size_t request, bool atomic = false) nothrow @trusted
    {
        auto b = headerOf(slice.ptr);
        return (b && request <= b.cap) ? b.cap : 0;
    }
    override bool shrinkArrayUsed(void[] slice, size_t existingUsed, bool atomic = false) nothrow
    {
        auto b = headerOf(slice.ptr);
        if (!b || b.used != existingUsed) return false;
        b.used = slice.length; return true;
    }

    override void initThread(ThreadBase thread) nothrow @nogc {}
    override void cleanupThread(ThreadBase thread) nothrow @nogc {}
}

extern (C) int backtrace(void**, int) nothrow;
public __gshared bool traceArenaNull;
public __gshared uint arenaTraceShown;

private __gshared RegionGC theGC;

// Census of persistent allocations by TypeInfo (diagnostic).
struct TiStat { void* ti; size_t bytes; size_t count; }
private __gshared TiStat* tiStats;
private __gshared size_t tiCount;

private void bumpPers(void* ti, size_t n) nothrow @nogc
{
    if (!tiStats)
        return;
    for (size_t i = 0; i < tiCount; ++i)
        if (tiStats[i].ti is ti)
        {
            tiStats[i].bytes += n;
            tiStats[i].count += 1;
            return;
        }
    if (tiCount < 512)
    {
        tiStats[tiCount].ti = ti;
        tiStats[tiCount].bytes = n;
        tiStats[tiCount].count = 1;
        tiCount++;
    }
}

// Census of arena allocations by TypeInfo, reset each run (diagnostic).
private __gshared TiStat* arenaStats;
private __gshared size_t arenaCount;

// Per-run census of null-ti arena allocations keyed by caller (diagnostic).
struct CallerStat { void* pc; size_t bytes; size_t count; }
private __gshared CallerStat* callerStats;
private __gshared size_t callerCount;
public __gshared bool traceArenaCaller;

private void bumpCaller(size_t bytes) nothrow
{
    if (!callerStats)
        return;
    void*[8] fr;
    int nn = backtrace(fr.ptr, 8);
    void* pc = nn > 5 ? fr[5] : (nn > 4 ? fr[4] : (nn ? fr[nn - 1] : null));
    for (size_t i = 0; i < callerCount; ++i)
        if (callerStats[i].pc is pc)
        {
            callerStats[i].bytes += bytes;
            callerStats[i].count += 1;
            return;
        }
    if (callerCount < 256)
    {
        callerStats[callerCount].pc = pc;
        callerStats[callerCount].bytes = bytes;
        callerStats[callerCount].count = 1;
        callerCount++;
    }
}

private void bumpArena(void* ti, size_t n) nothrow @nogc
{
    if (!arenaStats)
        return;
    for (size_t i = 0; i < arenaCount; ++i)
        if (arenaStats[i].ti is ti)
        {
            arenaStats[i].bytes += n;
            arenaStats[i].count += 1;
            return;
        }
    if (arenaCount < 512)
    {
        arenaStats[arenaCount].ti = ti;
        arenaStats[arenaCount].bytes = n;
        arenaStats[arenaCount].count = 1;
        arenaCount++;
    }
}

public:
__gshared ulong arenNullTi, persNullTi;
__gshared ulong pnBits0, pnFinal, pnNoscan, pnAppend, pnScan;
void regionDumpArenaCaller() nothrow
{
    import core.sys.posix.dlfcn : dladdr, Dl_info;
    import core.stdc.stdio : fprintf, stderr;
    fprintf(stderr, "CALLERCENSUS n=%zu\n", callerCount);
    for (size_t i = 0; i < callerCount && i < 16; ++i)
    {
        size_t m = i;
        foreach (j; i .. callerCount)
            if (callerStats[j].bytes > callerStats[m].bytes)
                m = j;
        auto t = callerStats[i]; callerStats[i] = callerStats[m]; callerStats[m] = t;
        Dl_info di;
        const(char)[] nm = "(?)";
        if (dladdr(callerStats[i].pc, &di) != 0 && di.dli_sname)
            nm = cast(const(char)[]) di.dli_sname[0 .. strlen(di.dli_sname)];
        fprintf(stderr, "CALLER %8zuKB x%-8zu %.*s\n",
            callerStats[i].bytes / 1024, callerStats[i].count, cast(int)nm.length, nm.ptr);
    }
}

void regionDumpArena() nothrow
{
    import core.stdc.stdio : fprintf, stderr;
    fprintf(stderr, "ARENACENSUS n=%zu\n", arenaCount);
    for (size_t i = 0; i < arenaCount && i < 16; ++i)
    {
        size_t m = i;
        foreach (j; i .. arenaCount)
            if (arenaStats[j].bytes > arenaStats[m].bytes)
                m = j;
        auto t = arenaStats[i]; arenaStats[i] = arenaStats[m]; arenaStats[m] = t;
        auto ti = cast(const TypeInfo) arenaStats[i].ti;
        const(char)[] nm = "(null)";
        if (ti)
        {
            if (auto ci = cast(const TypeInfo_Class) ti) nm = ci.name;
            else if (auto si = cast(const TypeInfo_Struct) ti) nm = si.mangledName;
            else nm = (cast(Object) ti).classinfo.name;
        }
        fprintf(stderr, "ARENA %8zuKB x%-8zu %.*s\n",
            arenaStats[i].bytes / 1024, arenaStats[i].count, cast(int)nm.length, nm.ptr);
    }
}

void regionDumpPersistent() nothrow
{
    import core.stdc.stdio : fprintf, stderr;
    fprintf(stderr, "NULLTI arena=%llu persistent=%llu (bits0=%llu final=%llu append=%llu noscan=%llu)\n",
        arenNullTi, persNullTi, pnBits0, pnFinal, pnAppend, pnNoscan);
    for (size_t i = 0; i < tiCount && i < 20; ++i)
    {
        size_t m = i;
        foreach (j; i .. tiCount)
            if (tiStats[j].bytes > tiStats[m].bytes)
                m = j;
        auto t = tiStats[i]; tiStats[i] = tiStats[m]; tiStats[m] = t;
        auto ti = cast(const TypeInfo) tiStats[i].ti;
        const(char)[] nm = "(noname)";
        if (auto ci = cast(const TypeInfo_Class) ti)
            nm = ci.name;
        else if (auto si = cast(const TypeInfo_Struct) ti)
            nm = si.mangledName;
        else
        {
            auto klass = (cast(Object) ti).classinfo;
            nm = klass.name;
        }
        fprintf(stderr, "PERS %6zuMB x%-8zu %.*s\n",
            tiStats[i].bytes / 1024 / 1024, tiStats[i].count,
            cast(int)nm.length, nm.ptr);
    }
}

public void regionSetAllToArena(bool v) nothrow @nogc { RegionGC.allToArena = v; }

private GC initialize()
{
    import core.lifetime : emplace;
    if (!tiStats)
        tiStats = cast(TiStat*) c_malloc(512 * TiStat.sizeof);
    if (!arenaStats)
        arenaStats = cast(TiStat*) c_malloc(512 * TiStat.sizeof);
    if (!callerStats)
        callerStats = cast(CallerStat*) c_malloc(256 * CallerStat.sizeof);
    auto gc = cast(RegionGC) c_malloc(__traits(classInstanceSize, RegionGC));
    if (!gc)
        assert(0, "regiongc: out of memory");
    theGC = emplace(gc);
    return cast(GC) theGC;
}

shared static this()
{
    registerGCFactory("region", &initialize);
}

private:

struct FreedRange
{
    size_t lo;
    size_t hi;
    FreedRange* next;
}

__gshared FreedRange* freedHead;

private void recordFreed(size_t lo, size_t hi) nothrow
{
    auto fr = cast(FreedRange*) c_malloc(FreedRange.sizeof);
    if (!fr)
        return;
    fr.lo = lo;
    fr.hi = hi;
    fr.next = freedHead;
    freedHead = fr;
}

private void clearFreed() nothrow
{
    auto f = freedHead;
    while (f)
    {
        auto n = f.next;
        c_free(f);
        f = n;
    }
    freedHead = null;
}

public:

/// True if `p` points into an arena chunk freed by `regionResetTo` since the
/// last checkpoint (used to find surviving references).
bool regionIsFreed(const void* p) nothrow @nogc
{
    auto a = cast(size_t) p;
    for (auto f = freedHead; f; f = f.next)
        if (a >= f.lo && a < f.hi)
            return true;
    return false;
}

struct RegionMark
{
    Chunk* chunk;
    size_t top;
    size_t used;
}

void* regionCheckpoint() nothrow
{
    if (!theGC)
        return null;
    clearFreed();
    auto m = cast(RegionMark*) c_malloc(RegionMark.sizeof);
    if (!m)
        return null;
    m.chunk = theGC.achunks;
    m.top = m.chunk ? m.chunk.top : 0;
    m.used = theGC.arenaUsed;
    return m;
}

/// Free every dmd (arena) allocation made after the checkpoint. Runtime
/// (persistent) allocations are untouched. The caller MUST clear dmd globals
/// referencing the arena first.
void regionResetTo(void* p) nothrow
{
    if (!theGC || !p)
        return;
    auto m = cast(RegionMark*) p;
    while (theGC.achunks !is m.chunk)
    {
        auto c = theGC.achunks;
        theGC.achunks = c.next;
        recordFreed(cast(size_t) c.base, cast(size_t) c.base + c.cap);
        c.next = theGC.spares;
        theGC.spares = c;
    }
    if (m.chunk)
        m.chunk.top = m.top;
    theGC.arenaUsed = m.used;
    arenaCount = 0; // per-run arena census
    callerCount = 0;
}

void regionFreeAll() nothrow
{
    if (!theGC)
        return;
    foreach (list; [theGC.achunks, theGC.pchunks])
    {
        auto c = list;
        while (c)
        {
            auto next = c.next;
            c_free(c.base);
            c_free(c);
            c = next;
        }
    }
    for (auto c = theGC.spares; c; )
    {
        auto next = c.next;
        c_free(c.base);
        c_free(c);
        c = next;
    }
    theGC.spares = null;
    theGC.achunks = null;
    theGC.pchunks = null;
    theGC.arenaUsed = 0;
}

size_t regionUsed() nothrow
{
    return theGC ? theGC.arenaUsed : 0;
}

size_t regionSpareBytes() nothrow
{
    size_t t = 0;
    for (auto c = theGC ? theGC.spares : null; c; c = c.next)
        t += c.cap;
    return t;
}

size_t regionPersistentUsed() nothrow
{
    return theGC ? theGC.persistentUsed : 0;
}

// --- arena allocation for dmd's `mem` (rmem) hooks ------------------------
void* regionArenaAlloc(size_t size) nothrow
{
    return theGC ? theGC.allocArena(size) : null;
}

void* regionArenaRealloc(void* p, size_t size) nothrow
{
    if (!theGC)
        return null;
    if (!p)
        return theGC.allocArena(size);
    auto b = theGC.headerOf(p);
    if (!b)
        return theGC.allocArena(size);
    if (size <= b.cap)
        return p;
    auto np = theGC.allocArena(size);
    if (!np)
        return null;
    auto nb = theGC.headerOf(np);
    memcpy(np, p, b.cap < size ? b.cap : size);
    return np;
}

void regionArenaFree(void* p) nothrow
{
    // no-op: freed wholesale on reset
}

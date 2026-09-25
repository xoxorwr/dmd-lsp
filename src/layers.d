// Memory levels: an in-process replacement for fork().
//
// dmd is a singleton compiler. A universe is a fully connected graph (parent
// links, scopes, interned types, template instances), and analysing one module
// mutates objects that belong to others: instances are cached on the imported
// template, types are interned in a global table, lazily analysed functions of
// imported modules are finished in place. That is why nothing short of process
// teardown could reclaim a superseded analysis (docs/findings.md).
//
// This module gives the same guarantee inside one process, scoped to dmd:
//
//   * Each level owns a private druntime `ConservativeGC` instance. It
//     collects its own garbage normally, and popping the level unmaps all of
//     its pools at once, whatever still points into them.
//   * Level 0 is the runtime and the server. It is never protected or popped.
//   * While level k is the top, the heaps of levels 1..k-1 are write-protected.
//     The first write to one of their pages saves a copy of the page and makes
//     it writable. The page is also registered as a root of level k, because
//     only a written page can hold a pointer into level k.
//   * Popping level k copies the saved pages back and restores the dmd globals
//     from the snapshot taken at push, so the levels below are byte for byte
//     what they were. Then it destroys level k's heap.
//
// Nothing here knows about dmd, and nothing depends on finding every place
// where dmd caches state: every write to lower-level memory is captured by the
// MMU. The one input the caller supplies is the list of static variables to
// snapshot (dmdglobals.d), which is finite and checked at build time.
//
// Single-threaded by design (the server is): levels are pushed, popped and
// allocated from on one thread. druntime's parallel mark threads only read.
module layers;

import core.gc.gcinterface : GC, Root, Range, RootIterator, RangeIterator;
import core.gc.registry : registerGCFactory;
import core.internal.gc.impl.conservative.gc : ConservativeGC, Gcx;
static import core.memory;
import core.stdc.stdlib : c_malloc = malloc, c_free = free, c_realloc = realloc;
import core.stdc.string : memcpy, memset;

alias BlkInfo = core.memory.GC.BlkInfo;

version (Posix)
{
    import core.sys.posix.sys.mman : mmap, mprotect, PROT_READ, PROT_WRITE,
        MAP_PRIVATE, MAP_ANON, MAP_FAILED;
    import core.sys.posix.signal : sigaction, sigaction_t, siginfo_t, SIGSEGV, SIGBUS,
        SA_SIGINFO, SA_RESTART, sigemptyset, SIG_DFL;
}
else version (Windows)
{
    import core.sys.windows.winbase : VirtualAlloc, VirtualFree, VirtualProtect;
    import core.sys.windows.winnt : MEM_RESERVE, MEM_COMMIT, PAGE_READWRITE,
        PAGE_READONLY, EXCEPTION_POINTERS, LONG;
    enum uint EXCEPTION_ACCESS_VIOLATION = 0xC0000005;
    extern (Windows) nothrow @nogc
    {
        void* AddVectoredExceptionHandler(uint first, LONG function(EXCEPTION_POINTERS*) nothrow handler);
    }
    enum LONG EXCEPTION_CONTINUE_EXECUTION = -1;
    enum LONG EXCEPTION_CONTINUE_SEARCH = 0;
}

enum size_t PAGE = 4096;
enum MAX_LEVELS = 8;

// ---- public API -------------------------------------------------------------

// Select this GC. Must run before rt_init (see main.d).
void layersSelect() nothrow @nogc
{
    import core.gc.config : config;

    config.gc = "layers";
}

// Number of dmd levels (0 = only the runtime heap exists).
uint levelDepth() nothrow @nogc
{
    return gInst is null ? 0 : gInst.depth;
}

// Push a new dmd level on top. `globals` are the static byte ranges that must
// be restored when this level is popped (dmd's module-level and class-static
// variables). Allocation moves to the new level while `levelEnter` is active.
void levelPush(const(void[])[] globals) nothrow
{
    gInst.push(globals);
}

// Pop the top dmd level: restore every lower page it wrote and the globals,
// then unmap its heap.
void levelPop() nothrow
{
    gInst.pop();
}

// Allocation target. The server allocates on level 0 (never reclaimed with a
// dmd level); calls into dmd run between `levelEnter` and `levelLeave` so what
// dmd allocates belongs to the top level. Nests.
void levelEnter() nothrow @nogc
{
    gInst.dmdDepth++;
}

void levelLeave() nothrow @nogc
{
    // Zero after `levelAbandonAll` (error recovery) while the scopes that
    // entered are still unwinding: nothing left to leave.
    if (gInst.dmdDepth > 0)
        gInst.dmdDepth--;
}

// Error recovery: whatever state an exception left the stack in (levels pushed
// mid-build, dmd mode on), drop every dmd level. Level 0 is untouched.
void levelAbandonAll() nothrow
{
    gInst.dmdDepth = 0;
    while (gInst.depth > 0)
        gInst.pop();
}

// Allocate on level 0 from inside dmd code (e.g. a diagnostic callback whose
// output must outlive the level): `auto t = levelSuspend(); ...; levelResume(t);`
uint levelSuspend() nothrow @nogc
{
    auto d = gInst.dmdDepth;
    gInst.dmdDepth = 0;
    return d;
}

void levelResume(uint token) nothrow @nogc
{
    gInst.dmdDepth = token;
}

// Pages of lower levels written (and saved) while the top level was active.
size_t levelDirtyPages() nothrow @nogc
{
    return gInst is null || gInst.depth == 0 ? 0 : gInst.saved.count - gInst.levels[gInst.depth].savedFrom;
}

// Bytes mapped by the heap of one level (0 = runtime).
size_t levelMappedBytes(uint level) nothrow @nogc
{
    if (gInst is null || level > gInst.depth)
        return 0;
    size_t n = 0;
    foreach (p; gInst.levels[level].gc.gcx.pooltable[])
        n += p.npages * PAGE;
    return n;
}

// Level owning `p` (0 = runtime or not GC memory).
uint levelOf(const void* p) nothrow @nogc
{
    return gInst is null ? 0 : gInst.owner(p);
}

// ---- implementation ---------------------------------------------------------

private:

__gshared LayeredGC gInst;

extern (C) pragma(crt_constructor) void layers_register()
{
    registerGCFactory("layers", &create);
}

GC create()
{
    import core.lifetime : emplace;

    auto mem = c_malloc(__traits(classInstanceSize, LayeredGC));
    auto gc = emplace(cast(LayeredGC) mem);
    gInst = gc;
    installFaultHandler();
    return gc;
}

// A fresh druntime collector, as its own factory makes one. The ctor reads
// the (already initialised) config and maps nothing yet.
ConservativeGC newConservative() nothrow
{
    import core.lifetime : emplace;

    auto mem = c_malloc(__traits(classInstanceSize, ConservativeGC));
    if (mem is null)
        fatal("layers: out of memory\n");
    try
        return emplace(cast(ConservativeGC) mem);
    catch (Exception)
        assert(0);
}

void destroyConservative(ConservativeGC gc) nothrow
{
    // `~this` runs Gcx.Dtor: stops the scan threads and unmaps every pool.
    // Finalizers are not run (dmd's AST classes have none).
    if (gc.gcx)
    {
        // Gcx.Dtor forgets the parallel-mark root stack (it is only ever
        // cleared), which would leak its mapping with every popped level.
        gc.gcx.toscanRoots.reset();
        try
            gc.gcx.Dtor();
        catch (Exception)
        {
        }
        c_free(gc.gcx);
        gc.gcx = null;
    }
    c_free(cast(void*) gc);
}

// A saved page: its address and the copy of its bytes at the time the level
// above it was pushed.
struct SavedPage
{
    void* addr;
    void* copy;
}

// Grow-only storage usable from the fault handler: the page copies and their
// index live in reserved address space that is committed on first touch, so
// the handler never calls malloc.
struct SaveArea
{
    SavedPage* index;
    ubyte* copies;
    size_t count;
    size_t cap;

    void initialize() nothrow @nogc
    {
        cap = 1 << 20; // 4 GiB of copies at most; reserved, not committed
        index = cast(SavedPage*) reserve(cap * SavedPage.sizeof);
        copies = cast(ubyte*) reserve(cap * PAGE);
    }

    // Drop entries >= from and give the copies back to the OS.
    void truncate(size_t from) nothrow @nogc
    {
        if (from >= count)
            return;
        release(copies + from * PAGE, (count - from) * PAGE);
        count = from;
    }
}

struct Level
{
    ConservativeGC gc;
    size_t savedFrom;       // first SaveArea entry owned by this level
    size_t rootsFlushed;    // SaveArea entries already registered as roots
    ubyte* globals;         // snapshot taken at push
    const(void[])[] globalRanges;
}

// Pool ranges of the protected levels, for the fault handler. Rebuilt on
// push/pop; never touched while dmd runs, so the handler reads it lock-free.
struct Span
{
    size_t lo;
    size_t hi;
}

__gshared Span[] gProtected;
__gshared SaveArea gSaved;

final class LayeredGC : GC
{
    Level[MAX_LEVELS] levels;
    uint depth;             // index of the top dmd level (0 = none)
    uint dmdDepth;          // >0 while dmd code runs (levelEnter)
    Range[] ranges;         // ranges added through the GC interface
    Root[] roots;
    Span[] level0Spans;     // pools of level 0 registered as roots of the top

    ref SaveArea saved() nothrow @nogc
    {
        return gSaved;
    }

    this()
    {
        levels[0].gc = newConservative();
        gSaved.initialize();
    }

    // -- level bookkeeping --

    ConservativeGC cur() nothrow @nogc
    {
        return levels[dmdDepth > 0 ? depth : 0].gc;
    }

    uint owner(const void* p) nothrow @nogc
    {
        foreach_reverse (i; 0 .. depth + 1)
        {
            auto pt = &levels[i].gc.gcx.pooltable;
            if (p >= pt.minAddr && p < pt.maxAddr && pt.findPool(cast(void*) p) !is null)
                return i;
        }
        return 0;
    }

    ConservativeGC ownerGC(const void* p, out bool writable) nothrow @nogc
    {
        auto i = owner(p);
        // Level 0 and the top level can be modified; the levels in between are
        // frozen: their blocks are never freed, grown or re-tagged, only
        // copied into the top level.
        writable = i == 0 || i == depth;
        return levels[i].gc;
    }

    void push(const(void[])[] globals) nothrow
    {
        assert(depth + 1 < MAX_LEVELS, "too many dmd levels");
        flushRoots();
        auto lv = &levels[depth + 1];
        lv.gc = newConservative();
        lv.savedFrom = gSaved.count;
        lv.rootsFlushed = gSaved.count;
        lv.globalRanges = globals;
        size_t total = 0;
        foreach (r; globals)
            total += r.length;
        lv.globals = cast(ubyte*) c_malloc(total ? total : 1);
        size_t off = 0;
        foreach (r; globals)
        {
            memcpy(lv.globals + off, r.ptr, r.length);
            off += r.length;
        }
        // Every static variable (and every lower root) is a root of the new
        // level too.
        foreach (ref r; ranges)
            lv.gc.addRange(r.pbot, r.ptop - r.pbot, r.ti);
        foreach (ref r; roots)
            lv.gc.addRoot(r.proot);
        // The new top registers level 0 afresh; the old top keeps its ranges.
        c_free(level0Spans.ptr);
        level0Spans = null;
        depth++;
        clearBlkCache();
        reprotect();
    }

    void pop() nothrow
    {
        assert(depth > 0, "no dmd level to pop");
        assert(dmdDepth == 0, "levelPop while dmd code is running");
        auto lv = &levels[depth];

        // 1. Make the saved pages writable and copy them back.
        foreach (i; lv.savedFrom .. gSaved.count)
        {
            auto sp = gSaved.index[i];
            protect(sp.addr, PAGE, true);
            memcpy(sp.addr, sp.copy, PAGE);
        }
        gSaved.truncate(lv.savedFrom);

        // 2. Restore the static variables.
        size_t off = 0;
        foreach (r; lv.globalRanges)
        {
            memcpy(cast(void*) r.ptr, lv.globals + off, r.length);
            off += r.length;
        }
        c_free(lv.globals);
        lv.globals = null;

        // 3. Drop the level-0 roots that pointed at this heap, then unmap it.
        forgetDmdInLevel0();
        clearBlkCache();
        destroyConservative(lv.gc);
        *lv = Level.init;
        depth--;
        c_free(level0Spans.ptr); // registered on the heap just destroyed
        level0Spans = null;
        version (Posix)
        {
            // Gcx.Dtor clears the fork-handler instance; point it at a live heap.
            Gcx.instance = levels[depth].gc.gcx;
        }
        reprotect();
    }

    // Protect every pool of levels 1..depth-1, except the pages the top level
    // has already saved (those stay writable; their copies are the pre-image).
    void reprotect() nothrow
    {
        size_t n = 0;
        foreach (i; 1 .. depth)
            n += levels[i].gc.gcx.pooltable.length;
        c_free(gProtected.ptr);
        gProtected = n ? (cast(Span*) c_malloc(n * Span.sizeof))[0 .. n] : null;
        size_t k = 0;
        foreach (i; 1 .. depth + 1)
        {
            foreach (p; levels[i].gc.gcx.pooltable[])
            {
                bool frozen = i < depth;
                protect(p.baseAddr, p.topAddr - p.baseAddr, !frozen);
                if (frozen)
                    gProtected[k++] = Span(cast(size_t) p.baseAddr, cast(size_t) p.topAddr);
            }
        }
        if (depth > 0)
            foreach (i; levels[depth].savedFrom .. gSaved.count)
                protect(gSaved.index[i].addr, PAGE, true);
    }

    // Register the pages saved since the last call as roots of the top level,
    // and keep level 0's view of the dmd heaps current. Runs before anything
    // that can collect.
    void flushRoots() nothrow
    {
        if (depth == 0)
            return;
        auto lv = &levels[depth];
        foreach (i; lv.rootsFlushed .. gSaved.count)
            lv.gc.addRange(gSaved.index[i].addr, PAGE, null);
        lv.rootsFlushed = gSaved.count;
        syncLevel0Roots();
    }

    // Level 0 (runtime, server) may point into dmd heaps and dmd heaps may
    // point into level 0; each collection must see the other side as roots.
    // The pool sets only change inside an allocation, so compare and re-sync.
    Span[] dmdSpansInLevel0;
    void syncLevel0Roots() nothrow
    {
        // dmd pools as roots of level 0.
        size_t n = 0;
        foreach (i; 1 .. depth + 1)
            n += levels[i].gc.gcx.pooltable.length;
        bool same = n == dmdSpansInLevel0.length;
        if (same)
        {
            size_t k = 0;
            outer: foreach (i; 1 .. depth + 1)
                foreach (p; levels[i].gc.gcx.pooltable[])
                {
                    auto s = dmdSpansInLevel0[k++];
                    if (s.lo != cast(size_t) p.baseAddr || s.hi != cast(size_t) p.topAddr)
                    {
                        same = false;
                        break outer;
                    }
                }
        }
        if (!same)
        {
            auto g0 = levels[0].gc;
            foreach (s; dmdSpansInLevel0)
                g0.removeRange(cast(void*) s.lo);
            c_free(dmdSpansInLevel0.ptr);
            dmdSpansInLevel0 = n ? (cast(Span*) c_malloc(n * Span.sizeof))[0 .. n] : null;
            size_t k = 0;
            foreach (i; 1 .. depth + 1)
                foreach (p; levels[i].gc.gcx.pooltable[])
                {
                    dmdSpansInLevel0[k++] = Span(cast(size_t) p.baseAddr, cast(size_t) p.topAddr);
                    g0.addRange(p.baseAddr, p.topAddr - p.baseAddr, null);
                }
        }

        // Level-0 pools as roots of the top level.
        auto top = levels[depth].gc;
        auto pt = &levels[0].gc.gcx.pooltable;
        bool same0 = pt.length == level0Spans.length;
        if (same0)
            foreach (j, p; (*pt)[])
                if (level0Spans[j].lo != cast(size_t) p.baseAddr || level0Spans[j].hi != cast(size_t) p.topAddr)
                {
                    same0 = false;
                    break;
                }
        if (!same0)
        {
            foreach (s; level0Spans)
                top.removeRange(cast(void*) s.lo);
            c_free(level0Spans.ptr);
            level0Spans = pt.length ? (cast(Span*) c_malloc(pt.length * Span.sizeof))[0 .. pt.length] : null;
            foreach (j, p; (*pt)[])
            {
                level0Spans[j] = Span(cast(size_t) p.baseAddr, cast(size_t) p.topAddr);
                top.addRange(p.baseAddr, p.topAddr - p.baseAddr, null);
            }
        }
    }

    void forgetDmdInLevel0() nothrow
    {
        auto g0 = levels[0].gc;
        foreach (s; dmdSpansInLevel0)
            g0.removeRange(cast(void*) s.lo);
        c_free(dmdSpansInLevel0.ptr);
        dmdSpansInLevel0 = null;
    }

    // -- GC interface --

    void enable()
    {
        foreach (i; 0 .. depth + 1)
            levels[i].gc.enable();
    }

    void disable()
    {
        foreach (i; 0 .. depth + 1)
            levels[i].gc.disable();
    }

    void collect() nothrow
    {
        flushRoots();
        levels[0].gc.collect();
        if (depth > 0)
            levels[depth].gc.collect();
        flushRoots();
    }

    void minimize() nothrow
    {
        flushRoots();
        levels[0].gc.minimize();
        if (depth > 0)
            levels[depth].gc.minimize();
        flushRoots();
    }

    uint getAttr(void* p) nothrow
    {
        bool w;
        return ownerGC(p, w).getAttr(p);
    }

    uint setAttr(void* p, uint mask) nothrow
    {
        bool w;
        auto g = ownerGC(p, w);
        return w ? g.setAttr(p, mask) : g.getAttr(p);
    }

    uint clrAttr(void* p, uint mask) nothrow
    {
        bool w;
        auto g = ownerGC(p, w);
        return w ? g.clrAttr(p, mask) : g.getAttr(p);
    }

    void* malloc(size_t size, uint bits, const TypeInfo ti) nothrow
    {
        flushRoots();
        auto r = cur().malloc(size, bits, ti);
        return r;
    }

    BlkInfo qalloc(size_t size, uint bits, const scope TypeInfo ti) nothrow
    {
        flushRoots();
        return cur().qalloc(size, bits, ti);
    }

    void* calloc(size_t size, uint bits, const TypeInfo ti) nothrow
    {
        flushRoots();
        return cur().calloc(size, bits, ti);
    }

    void* realloc(void* p, size_t size, uint bits, const TypeInfo ti) nothrow
    {
        flushRoots();
        if (p is null)
            return cur().malloc(size, bits, ti);
        bool w;
        auto g = ownerGC(p, w);
        if (w && g is cur())
            return g.realloc(p, size, bits, ti);
        // A block of another level: copy into the current one. A frozen
        // block is never freed; a level-0 block is, as realloc would.
        auto old = g.query(p);
        if (old.base is null)
            return cur().realloc(p, size, bits, ti); // not GC memory: let it decide
        if (size == 0)
        {
            if (w)
                g.free(p);
            return null;
        }
        auto np = cur().malloc(size, bits ? bits : old.attr, ti);
        size_t keep = old.size - (p - old.base);
        memcpy(np, p, keep < size ? keep : size);
        if (w)
            g.free(p);
        return np;
    }

    size_t extend(void* p, size_t minsize, size_t maxsize, const TypeInfo ti) nothrow
    {
        flushRoots();
        bool w;
        auto g = ownerGC(p, w);
        return w && g is cur() ? g.extend(p, minsize, maxsize, ti) : 0;
    }

    size_t reserve(size_t size) nothrow
    {
        return cur().reserve(size);
    }

    void free(void* p) nothrow @nogc
    {
        if (p is null)
            return;
        bool w;
        auto g = ownerGC(p, w);
        if (w)
            g.free(p);
    }

    void* addrOf(void* p) nothrow @nogc
    {
        bool w;
        return ownerGC(p, w).addrOf(p);
    }

    size_t sizeOf(void* p) nothrow @nogc
    {
        bool w;
        return ownerGC(p, w).sizeOf(p);
    }

    BlkInfo query(void* p) nothrow
    {
        bool w;
        return ownerGC(p, w).query(p);
    }

    core.memory.GC.Stats stats() @safe nothrow @nogc
    {
        core.memory.GC.Stats s;
        foreach (i; 0 .. depth + 1)
        {
            auto t = (() @trusted => levels[i].gc)().stats();
            s.usedSize += t.usedSize;
            s.freeSize += t.freeSize;
            s.allocatedInCurrentThread += t.allocatedInCurrentThread;
        }
        return s;
    }

    core.memory.GC.ProfileStats profileStats() @safe nothrow @nogc
    {
        return (() @trusted => levels[0].gc)().profileStats();
    }

    void addRoot(void* p) nothrow @nogc
    {
        roots = appendNoGC(roots, Root(p));
        foreach (i; 0 .. depth + 1)
            levels[i].gc.addRoot(p);
    }

    void removeRoot(void* p) nothrow @nogc
    {
        foreach (i, r; roots)
            if (r.proot is p)
            {
                roots[i] = roots[$ - 1];
                roots = roots[0 .. $ - 1];
                break;
            }
        foreach (i; 0 .. depth + 1)
            levels[i].gc.removeRoot(p);
    }

    @property RootIterator rootIter() @nogc
    {
        return levels[0].gc.rootIter;
    }

    void addRange(void* p, size_t sz, const TypeInfo ti) nothrow @nogc
    {
        ranges = appendNoGC(ranges, Range(p, p + sz, cast() ti));
        foreach (i; 0 .. depth + 1)
            levels[i].gc.addRange(p, sz, ti);
    }

    void removeRange(void* p) nothrow @nogc
    {
        foreach (i, r; ranges)
            if (r.pbot is p)
            {
                ranges[i] = ranges[$ - 1];
                ranges = ranges[0 .. $ - 1];
                break;
            }
        foreach (i; 0 .. depth + 1)
            levels[i].gc.removeRange(p);
    }

    @property RangeIterator rangeIter() @nogc
    {
        return levels[0].gc.rangeIter;
    }

    void runFinalizers(const scope void[] segment) nothrow
    {
        foreach (i; 0 .. depth + 1)
            levels[i].gc.runFinalizers(segment);
    }

    bool inFinalizer() nothrow @nogc @safe
    {
        return (() @trusted => levels[0].gc)().inFinalizer();
    }

    ulong allocatedInCurrentThread() nothrow
    {
        ulong n = 0;
        foreach (i; 0 .. depth + 1)
            n += levels[i].gc.allocatedInCurrentThread();
        return n;
    }

    void[] getArrayUsed(void* ptr, bool atomic = false) nothrow
    {
        bool w;
        return ownerGC(ptr, w).getArrayUsed(ptr, atomic);
    }

    bool expandArrayUsed(void[] slice, size_t newUsed, bool atomic = false) nothrow @safe
    {
        return (() @trusted {
            flushRoots();
            bool w;
            auto g = ownerGC(slice.ptr, w);
            return w && g is cur() ? g.expandArrayUsed(slice, newUsed, atomic) : false;
        })();
    }

    size_t reserveArrayCapacity(void[] slice, size_t request, bool atomic = false) nothrow @safe
    {
        return (() @trusted {
            flushRoots();
            bool w;
            auto g = ownerGC(slice.ptr, w);
            return w && g is cur() ? g.reserveArrayCapacity(slice, request, atomic) : 0;
        })();
    }

    bool shrinkArrayUsed(void[] slice, size_t existingUsed, bool atomic = false) nothrow
    {
        bool w;
        auto g = ownerGC(slice.ptr, w);
        return w && g is cur() ? g.shrinkArrayUsed(slice, existingUsed, atomic) : false;
    }

    void initThread(ThreadBase thread) nothrow @nogc
    {
        levels[0].gc.initThread(thread);
    }

    // Frees the thread's block cache: must run exactly once, not per level.
    void cleanupThread(ThreadBase thread) nothrow @nogc
    {
        levels[0].gc.cleanupThread(thread);
    }
}

import core.thread.threadbase : ThreadBase;

T[] appendNoGC(T)(T[] a, T v) nothrow @nogc
{
    auto p = cast(T*) c_realloc(a.ptr, (a.length + 1) * T.sizeof);
    p[a.length] = v;
    return p[0 .. a.length + 1];
}

// The array-append block cache is thread-local and shared by every heap; a
// popped heap's entries would describe unmapped (and later reused) blocks.
void clearBlkCache() nothrow @nogc
{
    import core.internal.gc.blkcache : __blkcache_storage;

    if (__blkcache_storage !is null)
        memset(__blkcache_storage, 0, BlkInfo.sizeof * 8);
}

// ---- OS memory --------------------------------------------------------------

void* reserve(size_t n) nothrow @nogc
{
    version (Posix)
    {
        int flags = MAP_PRIVATE | MAP_ANON;
        version (linux)
        {
            import core.sys.linux.sys.mman : MAP_NORESERVE;

            flags |= MAP_NORESERVE;
        }
        auto p = mmap(null, n, PROT_READ | PROT_WRITE, flags, -1, 0);
        if (p == MAP_FAILED)
            fatal("layers: cannot reserve the page save area\n");
        return p;
    }
    else version (Windows)
    {
        // Reserve only; commit page by page in the handler.
        return VirtualAlloc(null, n, MEM_RESERVE, PAGE_READWRITE);
    }
}

void release(void* p, size_t n) nothrow @nogc
{
    version (Posix)
    {
        // Mapping fresh anonymous memory over the range drops its pages on
        // every POSIX system (MADV_DONTNEED only means that on Linux).
        import core.sys.posix.sys.mman : MAP_FIXED;

        mmap(p, n, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
    }
    else version (Windows)
    {
        import core.sys.windows.winnt : MEM_DECOMMIT;

        VirtualFree(p, n, MEM_DECOMMIT);
    }
}

void commit(void* p, size_t n) nothrow @nogc
{
    version (Windows)
        VirtualAlloc(p, n, MEM_COMMIT, PAGE_READWRITE);
}

void protect(void* p, size_t n, bool writable) nothrow @nogc
{
    version (Posix)
    {
        if (mprotect(p, n, writable ? PROT_READ | PROT_WRITE : PROT_READ) != 0)
            fatal("layers: mprotect failed (vm.max_map_count?)\n");
    }
    else version (Windows)
    {
        uint old;
        if (!VirtualProtect(p, n, writable ? PAGE_READWRITE : PAGE_READONLY, &old))
            fatal("layers: VirtualProtect failed\n");
    }
}

void fatal(const(char)* msg) nothrow @nogc
{
    import core.stdc.stdio : fputs, stderr;
    import core.stdc.stdlib : abort;

    fputs(msg, stderr);
    abort();
}

// ---- write fault --------------------------------------------------------------

// First write to a protected page: save its bytes, make it writable, retry.
// Returns false when the address is not ours.
bool onWriteFault(void* addr) nothrow @nogc
{
    auto a = cast(size_t) addr;
    bool ours = false;
    foreach (s; gProtected)
        if (a >= s.lo && a < s.hi)
        {
            ours = true;
            break;
        }
    if (!ours)
        return false;
    auto page = cast(void*) (a & ~(PAGE - 1));
    if (gSaved.count == gSaved.cap)
        fatal("layers: save area exhausted\n");
    auto copy = gSaved.copies + gSaved.count * PAGE;
    commit(copy, PAGE);
    commit(&gSaved.index[gSaved.count], SavedPage.sizeof);
    memcpy(copy, page, PAGE);
    gSaved.index[gSaved.count] = SavedPage(page, copy);
    gSaved.count++;
    protect(page, PAGE, true);
    return true;
}

version (Posix)
{
    __gshared sigaction_t gOldSegv;
    __gshared sigaction_t gOldBus;

    extern (C) void faultHandler(int sig, siginfo_t* info, void* ctx)
    {
        if (onWriteFault(info.si_addr))
            return;
        // Not a layer page: hand it to whoever was there before.
        auto old = sig == SIGSEGV ? &gOldSegv : &gOldBus;
        if (old.sa_flags & SA_SIGINFO)
        {
            if (old.sa_sigaction !is null)
                return old.sa_sigaction(sig, info, ctx);
        }
        else if (old.sa_handler !is SIG_DFL && old.sa_handler !is null)
            return old.sa_handler(sig);
        // Default action: restore it and return, so the faulting instruction
        // re-executes and the core dump/debugger sees the real site.
        import core.stdc.stdio : fprintf, stderr;

        fprintf(stderr, "dmd-lsp: fault at %p (dmd level %u of %u)\n", info.si_addr,
            levelOf(info.si_addr), levelDepth());
        sigaction(sig, old, null);
    }

    void installFaultHandler() nothrow @nogc
    {
        sigaction_t sa;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = SA_SIGINFO | SA_RESTART;
        sa.sa_sigaction = &faultHandler;
        sigaction(SIGSEGV, &sa, &gOldSegv);
        sigaction(SIGBUS, &sa, &gOldBus);
    }
}
else version (Windows)
{
    extern (Windows) LONG faultHandler(EXCEPTION_POINTERS* ep) nothrow
    {
        auto rec = ep.ExceptionRecord;
        if (rec.ExceptionCode == EXCEPTION_ACCESS_VIOLATION && rec.NumberParameters >= 2
            && rec.ExceptionInformation[0] == 1 // write
            && onWriteFault(cast(void*) rec.ExceptionInformation[1]))
            return EXCEPTION_CONTINUE_EXECUTION;
        return EXCEPTION_CONTINUE_SEARCH;
    }

    void installFaultHandler() nothrow @nogc
    {
        AddVectoredExceptionHandler(1, &faultHandler);
    }
}

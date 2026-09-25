// Memory-level probe: build dmd's level and a dependency level once, then
// analyse the root N times in a disposable overlay level (and rebuild the
// dependency level `--full` times). Prints analysis/pop time, dirty pages, heap
// sizes, RSS and C-heap use per iteration: all but the times must stay flat.
// Linux (reads /proc and glibc's mallinfo2). Not part of the server build.
//
//   make probe && ./layers-probe ROOT.d [-Ipath] [-Jpath] [-version=X] [-mMODULE]
//                                [--iters N] [--full N]
module layers_probe;

import core.stdc.stdio;
import core.stdc.stdlib : atoi, exit;
import core.stdc.string : strcmp, strncmp, strlen;
import layers;
import dmdglobals;

import dmd.frontend;
import dmd.globals : global;
import dmd.dmodule : Module;
import dmd.dsymbolsem : dsymbolSemantic, importAll, runDeferredSemantic, runDeferredSemantic2,
    runDeferredSemantic3;
import dmd.semantic2 : semantic2;
import dmd.semantic3 : semantic3;
import dmd.identifier : Identifier;
import dmd.tokens : Token;
import dmd.location : SourceLoc;
import dmd.console : Color;
import dmd.errors : DiagnosticHandler;
import core.stdc.stdarg : va_list;

__gshared const(char)[] rootPath;
__gshared const(char)[] rootText;
__gshared string[] importDirs;
__gshared string[] stringDirs;
__gshared string[] versions;
__gshared uint diagCount;

extern (C) int main(int argc, char** argv)
{
    layersSelect();
    import core.runtime : rt_init, rt_term;

    rt_init();
    setvbuf(stdout, null, _IONBF, 0);
    int iters = 20, full = 0;
    bool warm = false;
    string[] baseMods;
    foreach (i; 1 .. argc)
    {
        auto a = argv[i][0 .. strlen(argv[i])];
        if (a.length > 2 && a[0 .. 2] == "-I")
            importDirs ~= a[2 .. $].idup;
        else if (a.length > 2 && a[0 .. 2] == "-J")
            stringDirs ~= a[2 .. $].idup;
        else if (a.length > 9 && a[0 .. 9] == "-version=")
            versions ~= a[9 .. $].idup;
        else if (a == "--iters")
            iters = atoi(argv[i + 1]);
        else if (a == "--warm")
            warm = true;
        else if (a == "--full")
            full = atoi(argv[i + 1]);
        else if (a.length > 2 && a[0 .. 2] == "-m")
            baseMods ~= a[2 .. $].idup;
        else if (a[0] != '-' && (i == 1 || argv[i - 1][0 .. 2] != "--"))
            rootPath = a.idup;
    }
    importDirs ~= "/usr/include/dlang/dmd";
    rootText = readAll(rootPath);

    // Level 1: dmd itself.
    levelPush(dmdGlobalRanges());
    levelEnter();
    initLevel1();
    levelLeave();
    printf("L1 init: heap %zu KB, globals %zu bytes in %zu ranges\n",
        levelMappedBytes(1) / 1024, dmdGlobalBytes(), dmdGlobalRanges().length);

    auto t00 = now();
    auto imports = rootImports();
    printf("root imports: %zu (%.1f ms, scratch level)\n", imports.length, ms(t00));
    foreach (f; 0 .. full + 1)
    {
        // Level 2: dependencies of the root (its imports, analysed as dmd
        // analyses imported modules).
        auto t0 = now();
        levelPush(dmdGlobalRanges());
        levelEnter();
        auto nb = buildBase(baseMods ~ imports);
        auto reachDmd = importsReachingRoot(baseMods ~ imports);
        levelLeave();
        string[] reach; // copied to level 0: level 2 may be popped below
        foreach (r; reachDmd)
            reach ~= r.idup;
        if (reach.length)
        {
            // The root is in a cycle with some of its imports: they cannot be
            // in a level below it. Rebuild without them.
            levelPop();
            string[] keep;
            foreach (m; baseMods ~ imports)
            {
                bool drop = false;
                foreach (r; reach)
                    drop |= r == m;
                if (!drop)
                    keep ~= m;
            }
            printf("L2: %zu of %zu imports reach the root; rebuilding without them\n",
                reach.length, imports.length);
            levelPush(dmdGlobalRanges());
            levelEnter();
            nb = buildBase(keep);
            levelLeave();
        }
        printf("L2 base: %zu modules, %.1f ms, heap %zu MB, rss %zu MB\n", nb, ms(t0),
            levelMappedBytes(2) >> 20, rssKB() >> 10);

        if (warm)
        {
            auto tw = now();
            levelPush(dmdGlobalRanges());
            levelEnter();
            warmRoot();
            levelLeave();
            printf("L3 warm: %.1f ms, heap %zu MB\n", ms(tw), levelMappedBytes(3) >> 20);
        }
        immutable top = warm ? 4 : 3;
        foreach (it; 0 .. iters)
        {
            auto t1 = now();
            levelPush(dmdGlobalRanges());
            levelEnter();
            diagCount = 0;
            auto errs = analyseRoot();
            levelLeave();
            auto dirty = levelDirtyPages();
            auto heap3 = levelMappedBytes(top);
            auto ta = ms(t1);
            auto t2 = now();
            levelPop();
            printf("  it %2d: analyse %6.1f ms, pop %5.2f ms, errors %u, dirty %zu pages, L3 heap %zu MB, rss %zu MB, malloc %zu KB, L0 %zu KB\n",
                it, ta, ms(t2), errs, dirty, heap3 >> 20, rssKB() >> 10, mallocKB(), levelMappedBytes(0) >> 10);
        }
        if (warm)
            levelPop();
        if (f < full)
        {
            auto t3 = now();
            levelPop();
            printf("L2 pop %.2f ms, rss %zu MB\n", ms(t3), rssKB() >> 10);
        }
    }
    return 0;
}

void initLevel1()
{
    DiagnosticHandler h = (const ref SourceLoc loc, Color hc, const(char)* header,
        const(char)* fmt, va_list args, const(char)* p1, const(char)* p2) {
        diagCount++;
        if (diagCount <= 3)
        {
            fprintf(stderr, "    %.*s(%u): ", cast(int) loc.filename.length, loc.filename.ptr, loc.line);
            vfprintf(stderr, fmt, args);
            fprintf(stderr, "\n");
        }
        return true;
    };
    // The identifier table is built by a static constructor, i.e. on level 0;
    // rebuild it here so it belongs to this level.
    Identifier.initTable();
    foreach (kw; __traits(getMember, dmd.tokens, "keywords"))
        Identifier.idPool(__traits(getMember, Token, "tochars")[kw], kw);
    initDMD(h, null);
    global.errorSink.errorLimit = 0;
    import dmd.common.charactertables : IdentifierCharLookup, IdentifierTable;

    global.compileEnv.dCharLookupTable = IdentifierCharLookup.forTable(IdentifierTable.LR);
    global.compileEnv.cCharLookupTable = IdentifierCharLookup.forTable(IdentifierTable.LR);
    foreach (p; importDirs)
        addImport(p);
    foreach (p; stringDirs)
        addStringImport(p);
    import dmd.cond : VersionCondition;
    foreach (v; versions)
        VersionCondition.addGlobalIdent(v);
}

// Import every module the root imports (at module level), the way an import
// declaration does: load, importAll, semantic, semantic2.
size_t buildBase(string[] extra)
{
    import dmd.root.filename : FileName;

    // Parse the root once to learn its imports, on a scratch copy that is not
    // registered: this level must not contain the root.
    string src = "module __dmdlsp_base;\n";
    foreach (m; extra)
        src ~= "static import " ~ m ~ ";\n";

    auto r = parseModule("__dmdlsp_base.d", src);
    auto m = r.module_;
    m.importAll(null);
    m.dsymbolSemantic(null);
    runDeferredSemantic();
    m.semantic2(null);
    runDeferredSemantic2();
    return Module.amodules.length;
}

// The root's text under another module name, analysed like a root: template
// instances it creates with library-only arguments are cached in this level.
void warmRoot()
{
    import dmdwrap : dmdParseNoRegister;
    import dmd.identifier : Identifier;

    auto pr = dmdParseNoRegister("__dmdlsp_warm.d", rootText);
    auto m = cast(Module) pr.module_;
    m.md = null;
    m.ident = Identifier.idPool("__dmdlsp_warm");
    Module.modules.insert(m);
    Module.amodules.push(m);
    m.importedFrom = m;
    m.importAll(null);
    m.dsymbolSemantic(null);
    runDeferredSemantic();
    m.semantic2(null);
    runDeferredSemantic2();
    m.semantic3(null);
    runDeferredSemantic3();
}

uint analyseRoot()
{
    auto before = global.errors;
    auto r = parseModule(rootPath, rootText);
    auto m = r.module_;
    m.importAll(null);
    m.dsymbolSemantic(null);
    runDeferredSemantic();
    m.semantic2(null);
    runDeferredSemantic2();
    m.semantic3(null);
    runDeferredSemantic3();
    return global.errors - before;
}

// Names (from `names`) of loaded modules whose import closure contains the
// root's file. Empty when the root is not in this level.
string[] importsReachingRoot(string[] names)
{
    Module root;
    foreach (m; Module.amodules)
        if (m.srcfile.toString() == rootPath)
            root = m;
    if (root is null)
        return null;
    string[] res;
    foreach (m; Module.amodules)
    {
        auto fqn = m.toPrettyChars();
        import core.stdc.string : strlen;
        auto name = fqn[0 .. strlen(fqn)];
        bool listed = false;
        foreach (n; names)
            listed |= n == name;
        if (listed && reaches(m, root))
            res ~= cast(string) name;
    }
    return res;
}

bool reaches(Module from, Module target)
{
    bool[Module] seen;
    Module[] stack = [from];
    while (stack.length)
    {
        auto m = stack[$ - 1];
        stack = stack[0 .. $ - 1];
        if (m is target)
            return true;
        if (m in seen)
            continue;
        seen[m] = true;
        foreach (i; m.aimports)
            stack ~= i;
    }
    return false;
}

// The root's imports, from dmd's parser in a scratch level (so the parse
// leaves nothing behind). Collected with module-level and function-local
// imports alike; strings are copied to level 0 before the pop.
string[] rootImports()
{
    import dmd.dimport : Import;
    import dmd.visitor : SemanticTimeTransitiveVisitor;
    import dmd.astcodegen : ASTCodegen;

    string[] res;
    levelPush(dmdGlobalRanges());
    levelEnter();
    auto m = parseModule(rootPath, rootText).module_;
    extern (C++) final class V : SemanticTimeTransitiveVisitor
    {
        alias visit = typeof(super).visit;
        string[]* res;
        override void visit(Import imp)
        {
            string name;
            foreach (p; imp.packages)
                name ~= p.toString() ~ ".";
            name ~= imp.id.toString();
            *res ~= name;
        }
    }
    string[] tmp;
    scope v = new V();
    v.res = &tmp;
    m.accept(v);
    levelLeave();
    foreach (t; tmp)
        res ~= t.idup; // level 0 copy
    levelPop();
    return res;
}

const(char)[] readAll(const(char)[] path)
{
    import std.file : read;

    return cast(const(char)[]) read(path);
}

long now()
{
    import core.time : MonoTime;

    return MonoTime.currTime.ticks;
}

double ms(long t0)
{
    import core.time : MonoTime;

    return (now() - t0) * 1000.0 / MonoTime.ticksPerSecond;
}

size_t rssKB()
{
    auto f = fopen("/proc/self/status", "r");
    char[256] line;
    size_t kb = 0;
    while (fgets(line.ptr, line.length, f))
        if (strncmp(line.ptr, "VmRSS:", 6) == 0)
            kb = atoi(line.ptr + 6);
    fclose(f);
    return kb;
}

import dmd.tokens;

struct mallinfo2_t { size_t arena, ordblks, smblks, hblks, hblkhd, usmblks, fsmblks, uordblks, fordblks, keepcost; }
extern (C) mallinfo2_t mallinfo2() nothrow @nogc;
size_t mallocKB() { auto m = mallinfo2(); return (m.uordblks + m.hblkhd) >> 10; }

// The analysis engine: dmd in-process, on memory levels (layers.d).
//
//   L1  dmd itself, configured (import paths, flags). Rebuilt on config change.
//   L2  dependencies: modules the roots import, loaded and analysed the way
//       dmd analyses imports. Never contains a root, an edited document, or a
//       module that (transitively) imports one: those would have to change
//       underneath it. Rebuilt when that set or the disk changes.
//   L3  warm: a copy of each root (up to 8) under another module name,
//       analysed once. The template instances they create with library-only
//       arguments (`format!(char, int)`, `to!string`, ...) are cached here, so
//       each edit re-instantiates only what depends on the root's own code. A
//       copy is added when a new root rebuilds the overlay; the level is
//       rebuilt when an edited document it loaded changes.
//   L4  the overlay: the roots analysed since the last change, from their
//       editor buffers. Any document change pops it; the next request pushes a
//       fresh one and analyses on top of the untouched lower levels.
//
// Popping a level restores the levels below byte for byte and unmaps its heap,
// so nothing accumulates, whatever dmd cached along the way.
//
// Lifetime rule for callers: an `Analysis` (its module, snapshot, lint hits)
// lives in the overlay and is valid until the next call that pops it
// (`analyze` after a change, `analyzeVariant`, `engineReset`, `configure`).
// Whatever must survive longer is copied to level 0 (`levelSuspend`).
//
// The entry points below may be called with dmd mode on (`levelEnter`) or
// off: they keep their own bookkeeping on level 0 and copy their inputs
// before anything can be popped, since the caller's buffers may live in the
// overlay being replaced.
module engine;

import layers;
import dmdglobals : dmdGlobalRanges;
import arena : Arena;
import dmdwrap : DiagMsg, DiagSink, gSink, applyDmdFlags;
import lint : LintOut, lintUnusedImports, lintUnusedParams;
import complete : SynMod, snapshotModule;
import session : fnv1a64;
import log : log, logDebug, debugLogEnabled;
import timing : nowMs, traceMs;

import dmd.dmodule : Module;
import dmd.expression : VarExp;
import dmd.globals : global;

struct Analysis
{
    void* module_ = null; // opaque dmd Module* (post-semantic)
    bool ok = false;
    uint errors = 0;
    DiagMsg[] diags; // level 0
    LintOut lintImports;
    LintOut lintParams;
    SynMod syn; // pre-semantic structure snapshot (see complete.d)
    // The text did not parse cleanly: the parser may have lost the structure
    // after the error (a half-typed statement derails it into what follows).
    bool syntaxErrors;
    // Uses of constants dmd folded away during this analysis (dmd `VarExp`s,
    // only recorded during reference search: engineBeginUnfolded).
    void*[] folds;
}

struct EngineConfig
{
    string[] importPaths;
    string[] stringPaths;
    string[] flags;
}

// The source of document text. Open documents are served from the editor;
// everything else from disk.
struct DocProvider
{
    // Text of an open document, or null when `path` is not open.
    const(char)[] delegate(const(char)[] path) open;
    // Paths of all open documents.
    const(char)[][] delegate() openPaths;
}

struct Engine
{
    EngineConfig cfg;
    DocProvider docs;
    bool initialized;
    ulong configGen;

    // Documents the user has edited this session: from then on they are
    // served from the buffer and kept out of L2.
    string[] edited;
    // Bumped on every document or disk change; the overlay records the value
    // it was built at.
    ulong generation;
    // Hash of the text dmd reads for each document seen (buffer, else disk).
    ulong[string] docHash;

    // L2
    bool depsBuilt;
    string[] depsWanted;      // module names requested (level 0)
    string[] depsFiles;       // files loaded in L2 (level 0)
    ulong[] depsStamps;       // their fileStamp at load, to notice disk edits
    bool depsStale;           // disk changed under a loaded file
    string[] learned;         // modules the overlay loaded that L2 lacks
    string[] depsBanned;      // wanted names that import an edited document
    string[] rootFiles;       // files analysed as roots: never learned into L2
    DiagMsg[] depsDiags;      // L2's diagnostics (level 0), for roots found there

    // L3
    bool warmBuilt;
    bool warmStale;           // an edited document it loaded changed
    string[] warmPaths;       // the roots it holds copies of
    string[] warmFiles;       // files it loaded above L2 (level 0)
    DiagMsg[] warmDiags;      // their diagnostics, for roots found there
    string[] noWarm;          // roots whose copy pulls the root itself in (cycle)

    // Reference search (engineBeginUnfolded): overlay analyses record the uses
    // of constants that folding replaces, and these files stay out of L2/L3.
    bool recordFolds;
    string[] isolated;

    // L4
    bool overlay;
    bool overlayVariant;      // built from a non-document text (placeholder)
    ulong overlayGeneration;
    Root[] roots;
    DiagSink sink;            // messages of the overlay, level 0
    Arena lintArena;          // lint hits of the overlay's analyses
}

struct Root
{
    string path;
    ulong hash;
    Analysis a;
}

// ---- configuration / documents ----------------------------------------------

void engineConfigure(ref Engine e, EngineConfig cfg)
{
    auto t = levelSuspend();
    scope (exit)
        levelResume(t);
    e.cfg = cfg;
    e.configGen++;
    dropAll(e);
}

// A document's text changed (open, edit, close).
void engineDocChanged(ref Engine e, const(char)[] path, bool edited)
{
    auto t = levelSuspend();
    scope (exit)
        levelResume(t);
    // Only a change of the text dmd would read invalidates anything: opening
    // or closing a document that matches the disk, or saving (or re-sending)
    // an unchanged buffer, keeps every level and the overlay's analyses.
    {
        import session : sessionReadDisk;

        const(char)[] now = e.docs.open !is null ? e.docs.open(path) : null;
        if (now is null)
            now = sessionReadDisk(path);
        immutable h = fnv1a64(cast(const(ubyte)[]) now);
        auto known = path in e.docHash;
        ulong before;
        if (known)
            before = *known;
        else
        {
            auto disk = sessionReadDisk(path);
            before = fnv1a64(cast(const(ubyte)[]) disk);
        }
        e.docHash[path.idup] = h;
        if (h == before)
            return;
    }
    e.generation++;
    if (edited && !contains(e.edited, path))
    {
        e.edited ~= path.idup;
        // An L2 that loaded the disk copy of this file is now wrong.
        if (contains(e.depsFiles, path))
            e.depsStale = true;
    }
    if (contains(e.warmFiles, path))
        e.warmStale = true;
}

// A file changed on disk (save, watched-files notification, VCS).
void engineDiskChanged(ref Engine e, const(char)[] path)
{
    auto t = levelSuspend();
    scope (exit)
        levelResume(t);
    e.generation++;
    if (path !is null)
        e.docHash.remove(cast(string) path); // remove only hashes the key
    if (path is null || contains(e.warmFiles, path))
        e.warmStale = true;
    if (path is null || contains(e.depsFiles, path))
        e.depsStale = true;
}

// Analyses currently cached in the overlay (valid until it pops).
const(Root)[] engineRoots(ref Engine e)
{
    return e.roots;
}

// ---- analysis -----------------------------------------------------------------

// Analyse `path` from `text` (the document's current text). Served from the
// overlay when it already holds this exact text and nothing changed since.
Analysis engineAnalyze(ref Engine e, const(char)[] path, const(char)[] text)
{
    auto h = fnv1a64(cast(const(ubyte)[]) text);
    if (e.overlay && !e.overlayVariant && e.overlayGeneration == e.generation)
        foreach (ref r; e.roots)
            if (r.path == path && r.hash == h)
                return r.a;
    auto t = levelSuspend();
    scope (exit)
        levelResume(t);
    return analyzeFresh(e, path.idup, text.idup, h, false);
}

// Analyse a variant of the document (e.g. with a completion placeholder).
// It gets an overlay of its own, dropped by the next `engineAnalyze`.
Analysis engineAnalyzeVariant(ref Engine e, const(char)[] path, const(char)[] text)
{
    auto h = fnv1a64(cast(const(ubyte)[]) text);
    if (e.overlay && e.overlayVariant && e.overlayGeneration == e.generation)
        foreach (ref r; e.roots)
            if (r.path == path && r.hash == h)
                return r.a;
    auto t = levelSuspend();
    scope (exit)
        levelResume(t);
    return analyzeFresh(e, path.idup, text.idup, h, true);
}

// Run `fn` with dmd available on a scratch level above everything, then drop
// all it allocated. For work that must not leave anything behind (parse-only
// lint, workspace index). `fn` must copy what it keeps outside `levelEnter`.
void engineScratch(ref Engine e, scope void delegate() fn)
{
    auto t = levelSuspend();
    scope (exit)
        levelResume(t);
    ensureInit(e);
    levelPush(dmdGlobalRanges());
    levelEnter();
    scope (exit)
    {
        levelLeave();
        levelPop();
    }
    fn();
}

// Error recovery (a dmd assert, a fault converted to an Error): drop every
// level, whatever state the failure left them in, and start over from L1 on
// the next request. The documents and session state are kept.
void engineHardReset(ref Engine e)
{
    levelAbandonAll();
    gSink = null;
    e.initialized = false;
    e.overlay = false;
    e.overlayVariant = false;
    e.roots = null;
    e.sink.reset();
    e.lintArena.reset();
    e.depsBuilt = false;
    e.depsFiles = null;
    e.depsStamps = null;
    e.depsDiags = null;
    e.learned = null;
    e.warmBuilt = false;
    e.warmFiles = null;
    e.warmDiags = null;
}

// Reference search needs the uses constant folding erases: the frontend
// substitutes a manifest constant (`Test.A`) with its value, losing the use.
// Between these calls, overlay analyses record every such substitution (H1,
// docs/hacks.md) in `Analysis.folds`; folding itself is unchanged. `files`
// (the candidate modules) are kept out of the dependency and warm levels, like
// edited documents, so each is analysed as a root, module-level initialisers
// included (a module on those levels was analysed without recording).
void engineBeginUnfolded(ref Engine e, const(char)[][] files)
{
    auto t = levelSuspend();
    scope (exit)
        levelResume(t);
    e.isolated = null;
    foreach (f; files)
    {
        e.isolated ~= f.idup;
        if (contains(e.depsFiles, f))
            e.depsStale = true;
    }
    e.recordFolds = true;
    popWarm(e); // and the overlay: both may hold candidates, unrecorded
}

void engineEndUnfolded(ref Engine e)
{
    auto t = levelSuspend();
    scope (exit)
        levelResume(t);
    e.recordFolds = false;
    e.isolated = null;
    popOverlay(e); // its analyses were built for the search
}

// Drop the overlay (and the warm and dependency levels if `deps`). The next
// request rebuilds them.
void engineReset(ref Engine e, bool deps)
{
    auto t = levelSuspend();
    scope (exit)
        levelResume(t);
    popOverlay(e);
    if (deps)
        popDeps(e);
}

// ---- internals -----------------------------------------------------------------

private:

bool contains(const(string)[] list, const(char)[] s)
{
    foreach (x; list)
        if (x == s)
            return true;
    return false;
}

void dropAll(ref Engine e)
{
    popOverlay(e);
    popDeps(e);
    if (e.initialized)
    {
        levelPop();
        e.initialized = false;
    }
}

void popOverlay(ref Engine e)
{
    if (!e.overlay)
        return;
    auto t0 = nowMs();
    scope (exit)
        traceMs("overlay.pop", nowMs() - t0);
    levelPop();
    engineCheckIdentifiers("after overlay pop");
    e.overlay = false;
    e.overlayVariant = false;
    e.roots = null;
    e.sink.reset();
    e.lintArena.reset();
}

void popWarm(ref Engine e)
{
    popOverlay(e);
    if (!e.warmBuilt)
        return;
    levelPop();
    engineCheckIdentifiers("after warm pop");
    e.warmBuilt = false;
    e.warmStale = false;
    e.warmPaths = null;
    e.warmFiles = null;
    e.warmDiags = null;
}

void popDeps(ref Engine e)
{
    popWarm(e);
    if (!e.depsBuilt)
        return;
    levelPop();
    engineCheckIdentifiers("after deps pop");
    e.depsBuilt = false;
    e.depsFiles = null;
    e.depsStamps = null;
    e.depsDiags = null;
}

// L1: a configured frontend.
void ensureInit(ref Engine e)
{
    if (e.initialized)
        return;
    import dmd.frontend : initDMD, addImport, addStringImport;
    import dmd.errors : DiagnosticHandler, FatalErrorHandler;
    import dmd.identifier : Identifier;
    import dmd.tokens : Token;
    import dmd.common.charactertables : IdentifierCharLookup, IdentifierTable;
    import dmdwrap : diagHandler, fatalHandler;

    levelPush(dmdGlobalRanges());
    levelEnter();
    scope (exit)
        levelLeave();
    // The identifier table is built by a static constructor, on level 0 where
    // dmd's writes would never be undone. Rebuild it on this level.
    Identifier.initTable();
    static import dmd.tokens;
    foreach (kw; __traits(getMember, dmd.tokens, "keywords"))
        Identifier.idPool(__traits(getMember, Token, "tochars")[kw], kw);
    initDMD(diagHandler(), fatalHandler());
    // H5 (docs/hacks.md): keep a function body past one broken statement, so
    // the half-typed buffer still has its scopes.
    import dmd.statementsem : lspKeepErroredBodies;
    lspKeepErroredBodies = true;
    global.errorSink.errorLimit = 0; // unlimited: a daemon must survive error storms
    // Stock sets these from the command line; unset, the first non-ASCII
    // identifier segfaults.
    global.compileEnv.dCharLookupTable = IdentifierCharLookup.forTable(IdentifierTable.LR);
    global.compileEnv.cCharLookupTable = IdentifierCharLookup.forTable(IdentifierTable.LR);
    foreach (p; e.cfg.importPaths)
        addImport(p);
    // dmd looks for a module in the current directory after the import
    // paths, and names what it finds there relative. Editors start the
    // server in the workspace, so a project's own modules came in as
    // `pkg/mod.d`, never matching the open documents' absolute paths: an
    // edited document that the dependency level had loaded (any import cycle
    // through it) went unnoticed, and it was analysed from the disk. The
    // same directory as the last import path finds the same files, by
    // absolute name.
    {
        import fsutil : currentDir;

        if (auto cwd = currentDir())
            addImport(cwd);
    }
    foreach (p; e.cfg.stringPaths)
        addStringImport(p);
    applyDmdFlags(e.cfg.flags);
    e.initialized = true;
}

void ownLintStrings(ref Arena arena, ref LintOut o)
{
    static string copy(ref Arena arena, const(char)[] str)
    {
        if (!str.length)
            return null;
        auto p = cast(char*) arena.alloc(str.length);
        if (p is null)
            return null;
        p[0 .. str.length] = str[];
        return cast(string) p[0 .. str.length];
    }

    foreach (i; 0 .. o.nhits)
    {
        o.hits[i].path = copy(arena, o.hits[i].path);
        o.hits[i].name = copy(arena, o.hits[i].name);
    }
}

// Folds recorded by the H1 hook during the current root analysis.
__gshared void*[] g_folds;

void noteFold(VarExp ve) nothrow
{
    g_folds ~= cast(void*) ve;
}

Analysis analyzeFresh(ref Engine e, const(char)[] path, const(char)[] text, ulong h, bool variant)
{
    ensureInit(e);
    if (!contains(e.rootFiles, path))
        e.rootFiles ~= path.idup;
    // Why the overlay could not answer (DMD_LSP_TIMING): the cache audit.
    string why = variant ? "variant"
        : !e.overlay ? "no-overlay"
        : e.overlayVariant ? "after-variant"
        : e.overlayGeneration != e.generation ? "doc-changed"
        : "new-root";
    foreach (ref r; e.roots)
        if (why == "new-root" && r.path == path)
            why = "text-changed";
    // Anything changed since the overlay was built, or a variant on either
    // side: start a fresh overlay.
    if (e.overlay && (variant || e.overlayVariant || e.overlayGeneration != e.generation))
        popOverlay(e);
    // An overlay holding an older text of this root cannot take the new one
    // (same module name): drop it too.
    if (e.overlay)
        foreach (ref r; e.roots)
            if (r.path == path)
            {
                popOverlay(e);
                break;
            }
    if (!e.overlay)
        ensureDeps(e, path, text);
    if (!e.overlay)
        ensureWarm(e, path, text);
    if (!e.overlay)
        pushOverlay(e, variant);

    auto t0 = nowMs();
    Analysis a;
    levelEnter();
    size_t diagFrom = e.sink.msgs.length;
    {
        // H1: record what folding erases during this root's own analysis
        // (reference search only, see engineBeginUnfolded).
        import dmd.optimize : lspConstFolded;

        g_folds = null;
        lspConstFolded = e.recordFolds ? &noteFold : null;
        scope (exit)
            lspConstFolded = null;
        immutable loadedBefore = Module.amodules.length;
        auto m = findLoaded(path);
        if (m is null)
        {
            immutable errorsBefore = global.errors;
            m = parseRoot(path, text);
            a.syntaxErrors = global.errors != errorsBefore;
            if (m !is null)
                a.syn = snapshotModule(m, text);
            if (m !is null)
                semanticRoot(m);
        }
        else
        {
            // Loaded already, as an import of another root, or on L2/L3 (an
            // unedited file whose disk text is `text`, or an edited one loaded
            // from this same buffer): finish its bodies. Its declaration-level
            // errors were reported when it was loaded, into that level's sink.
            a.syn = snapshotModule(m, text);
            logDebug("analyse module bodies: '%.*s' (loaded on a lower level)",
                cast(int) path.length, path.ptr);
            finishImported(m);
        }
        logLoaded(loadedBefore, variant ? "overlay, variant" : "overlay", null);
        a.module_ = cast(void*) m;
        a.ok = m !is null;
        a.folds = g_folds; // overlay memory, like the rest of the analysis
    }
    // Messages for this file from the whole overlay, plus everything this
    // analysis reported (template errors point into other files).
    uint errs = 0;
    foreach (ref d; e.depsDiags ~ e.warmDiags)
        if (d.file == path)
        {
            a.diags ~= d;
            if (d.kind == 'E')
                errs++;
        }
    foreach (i, ref d; e.sink.msgs)
        if (i >= diagFrom || d.file == path)
        {
            a.diags ~= d;
            if (d.kind == 'E' && d.file == path)
                errs++;
        }
    a.errors = errs;
    if (a.ok)
    {
        auto m = cast(Module) a.module_;
        lintUnusedImports(&e.lintArena, m, path, text, errs != 0, a.lintImports);
        lintUnusedParams(&e.lintArena, m, path, text, errs != 0, a.lintParams);
        // The hits slice `path`/`text` and dmd's identifiers; the arena is C
        // memory the GC does not scan, so give them copies that live as long
        // as the arena (this overlay).
        ownLintStrings(e.lintArena, a.lintImports);
        ownLintStrings(e.lintArena, a.lintParams);
    }
    learnLoads(e);
    levelLeave();
    traceMs(variant ? "analyze.variant" : "analyze", nowMs() - t0, why ~ " " ~ path);
    engineCheckIdentifiers("after analyze");
    e.roots ~= Root(path.idup, h, a);
    return a;
}

void pushOverlay(ref Engine e, bool variant)
{
    auto t0 = nowMs();
    scope (exit)
        traceMs("overlay.push", nowMs() - t0);
    levelPush(dmdGlobalRanges());
    e.overlay = true;
    e.overlayVariant = variant;
    e.overlayGeneration = e.generation;
    e.sink.reset();
    gSink = &e.sink;
    addOpenDocuments(e);
}

// Serve open documents from their buffers on the level just pushed. L2 never
// loaded an edited one, so these are the copies dmd will find.
void addOpenDocuments(ref Engine e)
{
    import dmd.root.filename : FileName;

    if (e.docs.openPaths is null)
        return;
    levelEnter();
    scope (exit)
        levelLeave();
    foreach (p; e.docs.openPaths())
    {
        auto t = e.docs.open(p);
        if (t is null)
            continue;
        auto buf = cast(ubyte[]) (t ~ '\0');
        global.fileManager.add(FileName(p.idup), buf[0 .. $ - 1]);
    }
}

// ---- L3 -------------------------------------------------------------------------

// Make the warm level hold a copy of `path`: rebuilt on a root switch, or when
// an edited document it loaded changed. Best effort: a root whose copy pulls
// the root itself in (an import cycle) runs without one.
void ensureWarm(ref Engine e, const(char)[] path, const(char)[] text)
{
    enum maxCopies = 8;
    string why = !e.warmBuilt ? "none" : e.warmStale ? "stale" : "add";
    if (e.warmBuilt && (e.warmStale || e.warmPaths.length >= maxCopies))
    {
        why = e.warmStale ? "stale" : "full";
        popWarm(e);
    }
    if (contains(e.warmPaths, path) || contains(e.noWarm, path) || e.isolated.length)
        return;
    auto t0 = nowMs();
    // The overlay is gone (we only get here while rebuilding it), so the warm
    // level is the top and can take another copy.
    if (!e.warmBuilt)
    {
        levelPush(dmdGlobalRanges());
        e.warmBuilt = true;
        e.warmStale = false;
    }
    // The buffers as they are now, before each copy: a copy may load an open
    // document (an import of its root) that was opened or edited since the
    // level was pushed. What it loads is tracked in `warmFiles`, so a later
    // edit of that document invalidates the level.
    addOpenDocuments(e);
    DiagSink sink; // level 0 (see onDiag)
    gSink = &sink;
    const(char)[][] loaded;
    bool cyclic;
    {
        levelEnter();
        scope (exit)
            levelLeave();
        immutable before = Module.amodules.length;
        analyzeCopy(text, e.warmPaths.length);
        logLoaded(before, "warm", path);
        // What this copy loaded: the real root among it means the root is in
        // an import cycle, and its copy is no use (the overlay could not
        // load the root from the buffer).
        foreach (m; Module.amodules[before .. $])
        {
            auto f = m.srcfile.toString();
            if (f == path)
                cyclic = true;
            else if (!contains(e.depsFiles, f))
                loaded ~= f;
        }
    }
    gSink = null;
    if (cyclic)
    {
        // The level may now hold the real root: drop it, copies and all.
        popWarm(e);
        e.noWarm ~= path.idup;
        log("warm: skipped for %.*s (import cycle through the root)", cast(int) path.length, path.ptr);
        return;
    }
    e.warmPaths ~= path.idup;
    foreach (f; loaded)
        if (!contains(e.warmFiles, f))
            e.warmFiles ~= f.idup;
    e.warmDiags ~= sink.msgs;
    traceMs("warm", nowMs() - t0, why ~ " " ~ path);
}

// DMD_LSP_DEBUG: one line per module dmd loaded since `from` (parsed, then
// analysed as it is imported), with the level that holds it. The warm copy of
// a root is named after the root (`copyOf`).
void logLoaded(size_t from, const(char)* level, const(char)[] copyOf)
{
    if (!debugLogEnabled())
        return;
    foreach (m; Module.amodules[from .. $])
    {
        const(char)[] f = m.srcfile.toString();
        if (f == "__dmdlsp_deps.d")
            continue; // the synthetic module importing the dependencies
        if (copyOf !is null && isWarmCopy(m.ident.toString()))
            logDebug("parse & analyse module: '%.*s' (%s, renamed copy)",
                cast(int) copyOf.length, copyOf.ptr, level);
        else
            logDebug("parse & analyse module: '%.*s' (%s)", cast(int) f.length, f.ptr, level);
    }
}

// Module name of the n-th warm copy.
string warmCopyName(size_t n)
{
    import core.stdc.stdio : snprintf;

    char[32] b;
    auto k = snprintf(b.ptr, b.length, "__dmdlsp_warm%u", cast(uint) n);
    return b[0 .. k].idup;
}

bool isWarmCopy(const(char)[] name)
{
    return name.length >= 13 && name[0 .. 13] == "__dmdlsp_warm";
}

// `text` as a root module named `__dmdlsp_warm<n>` (its own module
// declaration is ignored, so it cannot collide with the real root).
void analyzeCopy(const(char)[] text, size_t n)
{
    import dmdwrap : dmdParseNoRegister;
    import dmd.identifier : Identifier;
    import dmd.dsymbolsem : dsymbolSemantic, importAll, runDeferredSemantic,
        runDeferredSemantic2, runDeferredSemantic3;
    import dmd.semantic2 : semantic2;
    import dmd.semantic3 : semantic3;

    auto name = warmCopyName(n);
    auto pr = dmdParseNoRegister(name ~ ".d", text, false);
    if (!pr.ok)
        return;
    auto m = cast(Module) pr.module_;
    m.md = null;
    m.ident = Identifier.idPool(name);
    if (!Module.modules.insert(m))
        return;
    Module.amodules.push(m);
    m.importAll(null);
    import dmdwrap : dmdHasUnloadedImport;

    if (dmdHasUnloadedImport(cast(void*) m))
        return;
    m.dsymbolSemantic(null);
    runDeferredSemantic();
    m.semantic2(null);
    runDeferredSemantic2();
    m.semantic3(null);
    runDeferredSemantic3();
}

// ---- L2 -------------------------------------------------------------------------

// Make sure L2 is usable for analysing `path`: built, not stale, and holding
// nothing that imports an edited document.
void ensureDeps(ref Engine e, const(char)[] path, const(char)[] text)
{
    // A file can change on disk without a notification (another tool, a
    // client without file watching): compare what L2 loaded with the disk.
    // Runs once per new overlay, i.e. after a change.
    if (e.depsBuilt && !e.depsStale)
    {
        import fsutil : fileStamp;

        foreach (i, f; e.depsFiles)
            if (fileStamp(f) != e.depsStamps[i])
            {
                e.depsStale = true;
                break;
            }
    }
    bool need = !e.depsBuilt || e.depsStale || e.learned.length;
    if (!need)
        return;
    string why = !e.depsBuilt ? "none" : e.depsStale ? "stale" : "learned";
    if (why == "learned")
        foreach (n; e.learned)
            why ~= " " ~ n;
    popDeps(e);
    // Wanted: what was wanted before, what the overlays had to load, and the
    // imports of this root.
    string[] want = e.depsWanted;
    foreach (n; e.learned)
        if (!contains(want, n))
            want ~= n;
    foreach (n; rootImports(e, path, text))
        if (!contains(want, n))
            want ~= n;
    // A name banned before stays banned only while its reason holds: retry
    // them, the check below bans them again if needed.
    e.depsBanned = null;
    e.learned = null;
    e.depsStale = false;

    auto t0 = nowMs();
    foreach (attempt; 0 .. 4)
    {
        levelPush(dmdGlobalRanges());
        levelEnter();
        DiagSink sink; // level 0 (see onDiag)
        gSink = &sink;
        {
            immutable before = Module.amodules.length;
            loadModules(want);
            logLoaded(before, "dependencies", null);
        }
        // Modules that must not be here, and the wanted names that pull them in.
        string[] bannedDmd;
        auto bad = excludedLoaded(e);
        const(char)[][] files;
        if (bad.length)
            bannedDmd = wantedReaching(want, bad);
        else
            files = loadedFiles();
        levelLeave();
        gSink = null;
        // Level-0 copies: these are read after this level may be popped.
        string[] banned;
        foreach (b; bannedDmd)
            banned ~= b.idup;
        if (!banned.length)
        {
            import fsutil : fileStamp;

            e.depsFiles = null;
            e.depsStamps = null;
            foreach (f; files)
            {
                e.depsFiles ~= f.idup;
                e.depsStamps ~= fileStamp(f);
            }
            e.depsDiags = sink.msgs;
            break;
        }
        foreach (b; banned)
            e.depsBanned ~= b;
        levelPop();
        string[] keep;
        foreach (w; want)
            if (!contains(banned, w))
                keep ~= w;
        want = keep;
        if (attempt == 3)
        {
            // Could not isolate (should not happen): run without L2.
            want = null;
            levelPush(dmdGlobalRanges());
        }
    }
    e.depsWanted = null;
    foreach (w; want)
        e.depsWanted ~= w.idup;
    e.depsBuilt = true;
    traceMs("deps", nowMs() - t0, why ~ " " ~ path);
    log("deps: %d modules requested, %d files loaded", cast(int) e.depsWanted.length,
        cast(int) e.depsFiles.length);
}

// Names of the modules `path` imports (module-level, function-local and
// conditional alike), from a parse on a scratch level.
string[] rootImports(ref Engine e, const(char)[] path, const(char)[] text)
{
    import dmd.dimport : Import;
    import dmd.visitor : SemanticTimeTransitiveVisitor;
    import dmdwrap : dmdParseNoRegister;

    string[] res;
    string[] tmp;
    engineScratch(e, () {
        logDebug("parse module: '%.*s' (imports scan)", cast(int) path.length, path.ptr);
        auto pr = dmdParseNoRegister(path, text);
        if (!pr.ok)
            return;
        extern (C++) final class V : SemanticTimeTransitiveVisitor
        {
            alias visit = typeof(super).visit;
            string[]* names;
            override void visit(Import imp)
            {
                string n;
                foreach (p; imp.packages)
                    n ~= p.toString() ~ ".";
                n ~= imp.id.toString();
                *names ~= n;
            }
        }
        scope v = new V();
        v.names = &tmp;
        (cast(Module) pr.module_).accept(v);
        auto t = levelSuspend();
        foreach (n; tmp)
            res ~= n.idup;
        levelResume(t);
    });
    return res;
}

// Load `names` as imports of a synthetic module and analyse them as dmd
// analyses imported modules (semantic 1 and 2; bodies on demand).
void loadModules(const(string)[] names)
{
    import dmd.frontend : parseModule;
    import dmd.dsymbolsem : dsymbolSemantic, importAll, runDeferredSemantic, runDeferredSemantic2;
    import dmd.semantic2 : semantic2;

    string src = "module __dmdlsp_deps;\n";
    foreach (n; names)
        src ~= "static import " ~ n ~ ";\n";
    auto m = parseModule("__dmdlsp_deps.d", src).module_;
    if (m is null)
        return;
    m.importAll(null);
    m.dsymbolSemantic(null);
    runDeferredSemantic();
    m.semantic2(null);
    runDeferredSemantic2();
}

// Loaded modules that may not be in L2: edited documents (their text is the
// buffer's, which changes).
Module[] excludedLoaded(ref Engine e)
{
    Module[] res;
    foreach (m; Module.amodules)
    {
        auto f = m.srcfile.toString();
        if (contains(e.edited, f) || contains(e.isolated, f))
            res ~= m;
    }
    return res;
}

string[] wantedReaching(const(string)[] want, Module[] targets)
{
    string[] res;
    foreach (m; Module.amodules)
    {
        auto name = moduleName(m);
        if (contains(want, name) && reachesAny(m, targets))
            res ~= name;
    }
    return res;
}

bool reachesAny(Module from, Module[] targets)
{
    bool[Module] seen;
    Module[] stack = [from];
    while (stack.length)
    {
        auto m = stack[$ - 1];
        stack = stack[0 .. $ - 1];
        foreach (t; targets)
            if (m is t)
                return true;
        if (m in seen)
            continue;
        seen[m] = true;
        foreach (i; m.aimports)
            stack ~= i;
    }
    return false;
}

const(char)[][] loadedFiles()
{
    const(char)[][] res;
    foreach (m; Module.amodules)
        res ~= m.srcfile.toString();
    return res;
}

string moduleName(Module m)
{
    import core.stdc.string : strlen;

    auto p = m.toPrettyChars();
    return cast(string) p[0 .. strlen(p)];
}

// After an overlay analysis: modules it loaded from disk that L2 could have
// held. They seed the next L2 build.
void learnLoads(ref Engine e)
{
    // Only what this overlay loaded: modules the warm level loaded are cached
    // there already, and moving them to L2 would cost a rebuild of both.
    immutable overlayLevel = levelDepth();
    foreach (m; Module.amodules)
    {
        if (levelOf(cast(void*) m) != overlayLevel)
            continue;
        auto f = m.srcfile.toString();
        if (contains(e.depsFiles, f) || contains(e.edited, f) || contains(e.rootFiles, f))
            continue;
        auto n = moduleName(m);
        if (n == "__dmdlsp_deps" || isWarmCopy(n) || contains(e.depsBanned, n))
            continue;
        auto t = levelSuspend();
        if (!contains(e.learned, n) && !contains(e.depsWanted, n))
            e.learned ~= n.idup;
        levelResume(t);
    }
}

// ---- dmd driving --------------------------------------------------------------

Module findLoaded(const(char)[] path)
{
    foreach (m; Module.amodules)
        if (m.srcfile.toString() == path)
            return m;
    return null;
}

Module parseRoot(const(char)[] path, const(char)[] text)
{
    import dmd.frontend : parseModule;

    return parseModule(path, text).module_;
}

void semanticRoot(Module m)
{
    import dmdwrap : dmdSemantic;

    dmdSemantic(cast(void*) m);
}

void finishImported(Module m)
{
    import dmd.semantic3 : semantic3;
    import dmd.dsymbolsem : runDeferredSemantic3;

    m.semantic3(null);
    runDeferredSemantic3();
}

// Debug (LAYERS_CHECK=1): every identifier dmd's table holds must be a live GC
// block of some level, and still be that identifier. A dangling one means a
// level was popped under something that kept pointing into it (see
// docs/reclamation.md). Logs `where` and aborts on the first.
public void engineCheckIdentifiers(const(char)* where)
{
    import core.stdc.stdlib : getenv, abort;
    import core.stdc.stdio : fprintf, stderr;
    import core.memory : GC;
    import dmd.identifier : Identifier;

    __gshared int enabled = -1;
    if (enabled < 0)
        enabled = getenv("LAYERS_CHECK") !is null;
    if (!enabled || levelDepth() == 0)
        return;
    auto st = &__traits(getMember, Identifier, "stringtable");
    size_t n = 0;
    foreach (sv; *st)
    {
        n++;
        auto p = cast(void*) sv.value;
        if (p is null)
            continue;
        bool bad = GC.addrOf(p) is null;
        if (!bad)
        {
            auto nm = (cast(Identifier) p).toString();
            auto want = sv.toString();
            bad = nm.length != want.length || (nm.length && nm[0] != want[0]);
        }
        if (bad)
        {
            fprintf(stderr, "IDCHECK %s: dangling identifier #%zu at %p (level %u of %u)\n",
                where, n, p, levelOf(p), levelDepth());
            abort();
        }
    }
}

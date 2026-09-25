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
import dmd.func : FuncDeclaration;
import dmd.globals : global;
import dmd.location : Loc;
import dmd.dsymbol : PASS;
import core.stdc.stdlib : c_realloc = realloc;
import core.stdc.string : memcpy;

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
    // Directories of library code (druntime, Phobos): never edited, so what
    // imports only library code is cached below the project and kept.
    string[] libraryPaths;
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

    // The import graph as far as dmd has loaded it, on any level: decides
    // what the dependency levels may hold (level 0).
    ModInfo[string] graph;

    // Dependencies, analysed as imports and kept across edits. Library code
    // (under cfg.libraryPaths, importing only library code) has its own level
    // below the project's: no edit can invalidate it.
    DepLevel libs;
    DepLevel deps;
    string[] rootFiles;       // files analysed as roots: not requested there
    // Modules the last overlay loaded from disk: each analysis loads them
    // again, so they are worth moving to the dependency level (level 0).
    string[] overlayLoads;

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

    // Body patches of the overlay (see "body patches" below).
    PatchState patch;
    // The text each open document was registered with dmd on the warm and
    // on the overlay level (level 0): what a module loaded there was read from.
    string[string] warmTexts;
    string[string] overlayTexts;
    uint warmDepth, overlayDepth;

    // L4
    bool overlay;
    bool overlayVariant;      // built from a non-document text (placeholder)
    ulong overlayGeneration;
    Root[] roots;
    DiagSink sink;            // messages of the overlay, level 0
    Arena lintArena;          // lint hits of the overlay's analyses
}

// A function body in a root's text: `{` .. just past `}` (byte offsets), and
// the function (the root level's, when recorded for the base).
struct BodySpan
{
    uint start, end;
    uint startLine, endLine; // 1-based lines of `{` and `}`
    uint newlines;
    void* fd;
}

// The overlay root's analysis that edits inside function bodies are patched
// onto: its text, its bodies, and, for each body that may be re-analysed in
// place, the function's bytes from before its body was analysed.
// An open document the overlay's universe loaded (on the warm or overlay
// level), as edits inside its function bodies are patched onto it.
struct DocBase
{
    string path;
    string text;               // the text dmd loaded it from
    BodySpan[] spans;          // its bodies (the loaded module's functions)
    void[][] pristine;         // per span: bytes from before semantic 3 (roots)
    bool root;                 // analysed as a root on the overlay
    Analysis base;             // its analysis at `text` (roots)
}

// Body patches of the overlay (see "body patches" below).
struct PatchState
{
    bool patched;              // a patch level is on top of the overlay
    bool diskChanged;          // a file changed on disk since the overlay
    size_t sinkMark;           // e.sink length when the patch level was pushed
    DocBase[] docs;
    DocPlan[] plans;           // the patch level's (valid while it is on top)
    string[] loadedFiles;      // files loaded on the overlay, and their
    ulong[] loadedStamps;      // fileStamp: patches keep them
}

// A module dmd loaded: its file and the modules it imports.
struct ModInfo
{
    string file;
    string[] imports;
}

// A dependency level: what it was asked for and what it holds (level 0).
struct DepLevel
{
    bool built;
    bool stale;               // a file it loaded changed on disk
    string[] modules;         // module names loaded on it
    string[] files;           // their files
    ulong[] stamps;           // their fileStamp at load
    DiagMsg[] diags;          // its diagnostics, for roots found there
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
    // An edited document is served from its buffer: the dependency levels
    // drop it, and what reaches it, when the next analysis plans them.
    if (edited && !contains(e.edited, path))
        e.edited ~= path.idup;
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
    e.patch.diskChanged = true;
    if (path !is null)
        e.docHash.remove(cast(string) path); // remove only hashes the key
    if (path is null || contains(e.warmFiles, path))
        e.warmStale = true;
    foreach (lv; [&e.libs, &e.deps])
        if (path is null || contains(lv.files, path))
            lv.stale = true;
    // Its imports may have changed: learn them again when it next loads.
    if (path is null)
        e.graph = null;
    else
        foreach (name, ref info; e.graph)
            if (info.file == path)
            {
                e.graph.remove(name);
                break;
            }
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
    e.patch = PatchState.init;
    g_ctfeCount = 0;
    e.warmTexts = null;
    e.overlayTexts = null;
    gSink = null;
    e.initialized = false;
    e.overlay = false;
    e.overlayVariant = false;
    e.roots = null;
    e.sink.reset();
    e.lintArena.reset();
    e.libs = DepLevel.init;
    e.deps = DepLevel.init;
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
        e.isolated ~= f.idup; // the next plan drops them from the dependencies
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
        popLibs(e);
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
    popLibs(e);
    e.graph = null;
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
    if (e.patch.patched)
        levelPop();
    e.patch = PatchState.init;
    e.overlayTexts = null;
    g_ctfeCount = 0; // the functions it names are gone with the overlay
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
    e.warmTexts = null;
}

void popDeps(ref Engine e)
{
    popWarm(e);
    if (!e.deps.built)
        return;
    levelPop();
    engineCheckIdentifiers("after deps pop");
    e.deps = DepLevel.init;
}

void popLibs(ref Engine e)
{
    popDeps(e);
    if (!e.libs.built)
        return;
    levelPop();
    engineCheckIdentifiers("after libs pop");
    e.libs = DepLevel.init;
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
    // What changed since the overlay was built, when it is only edits inside
    // function bodies (and new roots): patch them onto it, no rebuild.
    if (!variant)
    {
        Analysis pa;
        if (tryIncremental(e, path, text, h, pa))
            return pa;
    }
    // Anything else changed since the overlay was built, or a variant on
    // either side: start a fresh overlay.
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
    if (e.overlay && e.patch.patched)
        popOverlay(e); // a new root cannot go under a patch
    if (!e.overlay)
        ensureDeps(e, path, text);
    if (!e.overlay)
        ensureWarm(e, path, text);
    if (!e.overlay)
        pushOverlay(e, variant);
    return analyzeRoot(e, path, text, h, variant, why);
}

// Analyse `path` as a root on the overlay (the top level): parse it from
// `text`, or finish the bodies of the module an import already loaded from
// that text. Not a variant: record it as a patch base.
Analysis analyzeRoot(ref Engine e, const(char)[] path, const(char)[] text, ulong h,
    bool variant, string why)
{
    auto t0 = nowMs();
    Analysis a;
    BodySpan[] spans;
    void[][] pristine;
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
        immutable patchable = !variant && !e.recordFolds;
        immutable loadedBefore = Module.amodules.length;
        auto m = findLoaded(path);
        if (m is null)
        {
            immutable errorsBefore = global.errors;
            m = parseRoot(path, text);
            a.syntaxErrors = global.errors != errorsBefore;
            if (m !is null)
            {
                a.syn = snapshotModule(m, text);
                // The base for body patches: what the parse laid out (before
                // semantic can add or rewrite members).
                if (patchable && !a.syntaxErrors)
                    spans = bodySpans(m, text);
                semanticRoot(m, spans, pristine);
            }
        }
        else
        {
            // Loaded already, as an import of another root, or on a lower
            // level (an unedited file whose disk text is `text`, or an edited
            // one loaded from this same buffer): finish its bodies. Its
            // declaration-level errors were reported when it was loaded, into
            // that level's sink.
            a.syn = snapshotModule(m, text);
            logDebug("analyse module bodies: '%.*s' (loaded on a lower level)",
                cast(int) path.length, path.ptr);
            if (patchable)
                spans = bodySpans(m, text);
            finishBodies(m, spans, pristine);
        }
        logLoaded(loadedBefore, variant ? "overlay, variant" : "overlay", null);
        a.module_ = cast(void*) m;
        a.ok = m !is null;
        a.folds = g_folds; // overlay memory, like the rest of the analysis
    }
    // Messages for this file from the whole overlay, plus everything this
    // analysis reported (template errors point into other files).
    uint errs = 0;
    foreach (ref d; e.libs.diags ~ e.deps.diags ~ e.warmDiags)
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
        lint(e, a, path, text);
    recordGraph(e);
    noteOverlayLoads(e);
    levelLeave();
    traceMs(variant ? "analyze.variant" : "analyze", nowMs() - t0, why ~ " " ~ path);
    engineCheckIdentifiers("after analyze");
    replaceRoot(e, path, h, a);
    if (!variant)
    {
        if (spans.length)
            setDocBase(e, DocBase(path.idup, text.idup, spans, pristine, true, a));
        dropCtfed(e, 0);
        noteDocs(e);
        overlayFiles(e, e.patch.loadedFiles, e.patch.loadedStamps);
    }
    return a;
}

// Unused imports and parameters of a root's analysis. The hits slice
// `path`/`text` and dmd's identifiers; the arena is C memory the GC does not
// scan, so give them copies that live as long as the arena (this overlay).
void lint(ref Engine e, ref Analysis a, const(char)[] path, const(char)[] text)
{
    auto m = cast(Module) a.module_;
    lintUnusedImports(&e.lintArena, m, path, text, a.errors != 0, a.lintImports);
    lintUnusedParams(&e.lintArena, m, path, text, a.errors != 0, a.lintParams);
    ownLintStrings(e.lintArena, a.lintImports);
    ownLintStrings(e.lintArena, a.lintParams);
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
    e.overlayDepth = levelDepth();
    e.sink.reset();
    gSink = &e.sink;
    addOpenDocuments(e, e.overlayTexts);
}

// Serve open documents from their buffers on the top level: what dmd loads
// from here on reads them. The dependency levels never loaded an edited one.
// `texts` records what each was registered with (level 0).
void addOpenDocuments(ref Engine e, ref string[string] texts)
{
    if (e.docs.openPaths is null)
        return;
    foreach (p; e.docs.openPaths())
    {
        auto t = e.docs.open(p);
        if (t is null)
            continue;
        registerBuffer(p, t);
        auto s = levelSuspend();
        texts[p.idup] = t.idup;
        levelResume(s);
    }
}

// Make dmd read `path` from `text`. A registration made earlier (a lower
// level, or before an edit) is replaced: the file table keeps the first
// entry for a name, and a stale one would be read by the next load.
void registerBuffer(const(char)[] path, const(char)[] text)
{
    import dmd.root.filename : FileName;

    levelEnter();
    scope (exit)
        levelLeave();
    auto buf = cast(ubyte[]) (text ~ '\0');
    auto files = &__traits(getMember, global.fileManager, "files");
    if (auto v = files.lookup(path))
        v.value = buf[0 .. $ - 1];
    else
        global.fileManager.add(FileName(path.idup), buf[0 .. $ - 1]);
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
        e.warmDepth = levelDepth();
    }
    // The buffers as they are now, before each copy: a copy may load an open
    // document (an import of its root) that was opened or edited since the
    // level was pushed. What it loads is tracked in `warmFiles`, so a later
    // edit of that document invalidates the level.
    addOpenDocuments(e, e.warmTexts);
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
        recordGraph(e);
        // What this copy loaded: the real root among it means the root is in
        // an import cycle, and its copy is no use (the overlay could not
        // load the root from the buffer).
        foreach (m; Module.amodules[before .. $])
        {
            auto f = m.srcfile.toString();
            if (f == path)
                cyclic = true;
            else if (!inDeps(e, f))
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
        if (!isWarmCopy(m.ident.toString()) && isSynthetic(m.ident.toString()))
            continue; // a dependency level's loader
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

// ---- dependency levels ----------------------------------------------------------

// Make the dependency levels right for analysing `path`: they hold every
// module the engine knows (from the import graph, and the root's imports the
// first time) that reaches no edited document, library code on its own level.
// Each is rebuilt only when it lacks a module it should hold, holds one it may
// no longer (an edit made it reach an edited document), or a file it loaded
// changed on disk.
void ensureDeps(ref Engine e, const(char)[] path, const(char)[] text)
{
    // A file can change on disk without a notification (another tool, a
    // client without file watching): compare what each level loaded with the
    // disk. Runs once per new overlay, i.e. after a change.
    foreach (lv; [&e.libs, &e.deps])
        if (lv.built && !lv.stale)
        {
            import fsutil : fileStamp;

            foreach (i, f; lv.files)
                if (fileStamp(f) != lv.stamps[i])
                {
                    lv.stale = true;
                    break;
                }
        }

    // The root's own imports: known from the graph once it has been analysed.
    string[] extra;
    if (!knowsFile(e, path))
        extra = rootImports(e, path, text);

    auto tainted = taintedModules(e);
    bool[string] libClosure;
    string[] wantLibs, wantDeps;
    foreach (name, ref info; e.graph)
    {
        if (name in tainted || contains(e.rootFiles, info.file))
            continue;
        if (isLibraryClosure(e, name, libClosure))
            wantLibs ~= name;
        else
            wantDeps ~= name;
    }
    // Not known yet: by where it would load from (buildLevel checks what a
    // library actually pulls in).
    foreach (n; extra)
        if (n !in e.graph && !contains(wantLibs, n) && !contains(wantDeps, n))
        {
            if (isLibraryFile(e, resolveModule(e, n)))
                wantLibs ~= n;
            else
                wantDeps ~= n;
        }

    // The project level must hold what it wants and what the library level
    // lacks. Library modules loaded there (imported by project code) move to
    // their level only when the project level is rebuilt anyway: learning
    // them alone would rebuild both.
    // Learning alone rebuilds it only for what the overlay keeps reloading
    // (what the warm level loaded is cached there already).
    string[] learn;
    foreach (n; e.overlayLoads)
        if (n !in tainted && !contains(e.libs.modules, n) && !contains(e.deps.modules, n))
            learn ~= n;
    string why = !e.deps.built ? "none" : e.deps.stale ? "stale"
        : holdsAny(e.deps, tainted) ? "reaches-edited"
        : learn.length ? "learned" : null;
    string whyLibs = !e.libs.built ? "none" : e.libs.stale ? "stale"
        : holdsAny(e.libs, tainted) ? "reaches-edited"
        : why !is null && !holdsAll(e.libs, wantLibs, null) ? "learned" : null;
    if (whyLibs !is null)
    {
        popLibs(e);
        buildLevel(e, e.libs, wantLibs, "libraries", whyLibs ~ " " ~ path);
        if (why is null)
            why = "libraries";
    }
    if (why !is null)
    {
        popDeps(e);
        string[] want;
        foreach (n; wantDeps ~ wantLibs)
            if (!contains(e.libs.modules, n))
                want ~= n;
        buildLevel(e, e.deps, want, "dependencies", why ~ " " ~ path);
    }
}

// After an overlay analysis: the modules it loaded from disk (not roots, not
// edited documents; ensureDeps filters out what reaches one).
void noteOverlayLoads(ref Engine e)
{
    immutable top = levelDepth();
    string[] res;
    foreach (m; Module.amodules)
    {
        if (levelOf(cast(void*) m) != top)
            continue;
        auto n = moduleName(m);
        auto f = m.srcfile.toString();
        if (isSynthetic(n) || contains(e.edited, f) || contains(e.rootFiles, f))
            continue;
        res ~= n;
    }
    auto t = levelSuspend();
    e.overlayLoads = null;
    foreach (n; res)
        e.overlayLoads ~= n.idup;
    levelResume(t);
}

// The file dmd would load module `name` from: the first import path holding
// it (`a/b.d`, `a/b.di`, `a/b/package.d`), or null.
string resolveModule(ref Engine e, const(char)[] name)
{
    import fsutil : fileStamp;

    char[] rel;
    foreach (c; name)
        rel ~= c == '.' ? '/' : c;
    foreach (dir; e.cfg.importPaths)
    {
        auto base = (dir.length && (dir[$ - 1] == '/' || dir[$ - 1] == '\\')) ? dir : dir ~ "/";
        foreach (cand; [base ~ rel ~ ".di", base ~ rel ~ ".d", base ~ rel ~ "/package.d"])
            if (fileStamp(cand) != 0)
                return cand.idup;
    }
    return null;
}

// Push a dependency level holding `want`. A module the graph did not know
// may turn out to reach an edited document: then the level is rebuilt
// without the names that pull one in, now that the graph knows.
void buildLevel(ref Engine e, ref DepLevel lv, string[] want, string what,
    const(char)[] why)
{
    auto t0 = nowMs();
    foreach (attempt; 0 .. 3)
    {
        levelPush(dmdGlobalRanges());
        levelEnter();
        DiagSink sink; // level 0 (see onDiag)
        gSink = &sink;
        immutable before = Module.amodules.length;
        loadModules(what == "libraries" ? "__dmdlsp_libs" : "__dmdlsp_deps", want);
        logLoaded(before, what.ptr, null);
        recordGraph(e);
        // Nothing an edit can reach; on the library level, only library code
        // (a project `object.d` is imported by all of druntime).
        immutable libraries = what == "libraries";
        // The last try asks for nothing: keep what dmd loads regardless (its
        // own `object`, which may be the project's).
        bool clean = true;
        immutable last = want.length == 0;
        foreach (m; Module.amodules[before .. $])
        {
            auto f = m.srcfile.toString();
            if (contains(e.edited, f) || contains(e.isolated, f))
                clean = false;
            if (libraries && !isSynthetic(moduleName(m)) && !isLibraryFile(e, f))
                clean = false;
        }
        clean |= last;
        const(char)[][] names, files;
        if (clean)
            foreach (m; Module.amodules[before .. $])
            {
                auto n = moduleName(m);
                if (isSynthetic(n))
                    continue;
                names ~= n;
                files ~= m.srcfile.toString();
            }
        levelLeave();
        gSink = null;
        if (clean)
        {
            import fsutil : fileStamp;

            lv = DepLevel.init;
            lv.built = true;
            foreach (i, n; names)
            {
                lv.modules ~= n.idup;
                lv.files ~= files[i].idup;
                lv.stamps ~= fileStamp(files[i]);
            }
            lv.diags = sink.msgs;
            break;
        }
        levelPop();
        auto tainted = taintedModules(e);
        bool[string] libClosure;
        string[] keep;
        foreach (w; want)
            if (w !in tainted && (!libraries || isLibraryClosure(e, w, libClosure)))
                keep ~= w;
        want = attempt == 1 ? null : keep; // last try: an empty level
    }
    traceMs(what == "libraries" ? "libs" : "deps", nowMs() - t0, why);
    log("%.*s: %d modules loaded", cast(int) what.length, what.ptr, cast(int) lv.modules.length);
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

// Load `names` as imports of a synthetic module (named `synthetic`, one per
// level) and analyse them as dmd analyses imported modules (semantic 1 and 2;
// bodies on demand).
void loadModules(string synthetic, const(string)[] names)
{
    import dmd.frontend : parseModule;
    import dmd.dsymbolsem : dsymbolSemantic, importAll, runDeferredSemantic, runDeferredSemantic2;
    import dmd.semantic2 : semantic2;

    string src = "module " ~ synthetic ~ ";\n";
    foreach (n; names)
        src ~= "static import " ~ n ~ ";\n";
    auto m = parseModule(synthetic ~ ".d", src).module_;
    if (m is null)
        return;
    m.importAll(null);
    m.dsymbolSemantic(null);
    runDeferredSemantic();
    m.semantic2(null);
    runDeferredSemantic2();
}

// Record what dmd has loaded into the import graph: modules it did not know,
// and, for those on the top level (a root, its buffer's imports), afresh.
void recordGraph(ref Engine e)
{
    immutable top = levelDepth();
    foreach (m; Module.amodules)
    {
        auto n = moduleName(m);
        if (isSynthetic(n))
            continue;
        if (n in e.graph && levelOf(cast(void*) m) != top)
            continue;
        auto t = levelSuspend();
        ModInfo info;
        info.file = m.srcfile.toString().idup;
        foreach (imp; m.aimports)
            if (imp)
                info.imports ~= moduleName(imp).idup;
        e.graph[n.idup] = info;
        levelResume(t);
    }
}

// Modules the engine makes up (dependency loaders, warm copies).
bool isSynthetic(const(char)[] name)
{
    return name.length >= 8 && name[0 .. 8] == "__dmdlsp";
}

bool knowsFile(ref Engine e, const(char)[] path)
{
    foreach (ref info; e.graph)
        if (info.file == path)
            return true;
    return false;
}

// Modules that reach an edited (or isolated) document through the graph,
// the documents' own modules included.
bool[string] taintedModules(ref Engine e)
{
    string[][string] importers;
    string[] stack;
    foreach (name, ref info; e.graph)
    {
        foreach (i; info.imports)
            importers[i] ~= name;
        if (contains(e.edited, info.file) || contains(e.isolated, info.file))
            stack ~= name;
    }
    bool[string] res;
    while (stack.length)
    {
        auto n = stack[$ - 1];
        stack = stack[0 .. $ - 1];
        if (n in res)
            continue;
        res[n] = true;
        if (auto p = n in importers)
            stack ~= *p;
    }
    return res;
}

// `name` is library code importing only library code (memoised in `memo`).
bool isLibraryClosure(ref Engine e, string name, ref bool[string] memo)
{
    if (auto p = name in memo)
        return *p;
    auto info = name in e.graph;
    if (info is null || !isLibraryFile(e, info.file))
        return memo[name] = false;
    memo[name] = true; // an import cycle among library modules stays library
    foreach (i; info.imports)
        if (!isLibraryClosure(e, i, memo))
            return memo[name] = false;
    return true;
}

bool isLibraryFile(ref Engine e, const(char)[] file)
{
    foreach (d; e.cfg.libraryPaths)
        if (file.length > d.length && file[0 .. d.length] == d &&
            (file[d.length] == '/' || file[d.length] == '\\' ||
             d[$ - 1] == '/' || d[$ - 1] == '\\'))
            return true;
    return false;
}

bool holdsAny(ref DepLevel lv, bool[string] names)
{
    foreach (m; lv.modules)
        if (m in names)
            return true;
    return false;
}

// `lv` (or `below`) holds every module of `want`.
bool holdsAll(ref DepLevel lv, const(string)[] want, DepLevel* below)
{
    foreach (w; want)
        if (!contains(lv.modules, w) && (below is null || !contains(below.modules, w)))
            return false;
    return true;
}

// The file is on a dependency level.
bool inDeps(ref Engine e, const(char)[] file)
{
    return contains(e.libs.files, file) || contains(e.deps.files, file);
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

// ---- body patches -------------------------------------------------------------
//
// An edit inside function bodies of the overlay's root changes nothing another
// module can see, when the bodies are those of plain functions with declared
// attributes and return type that nothing evaluated at compile time. Then only
// those bodies are analysed again: on a level above the root's analysis, each
// function is restored to its bytes from before its body was analysed, takes
// the new body and is analysed again; the root's positions after each body
// shift by the lines it gained (the location table's `#line` substitutions).
// Anything else (an edit outside bodies, another document changed, a body not
// swappable) analyses the root in full. docs/design.md, "Body patches".

__gshared void** g_ctfeFns; // functions CTFE ran (C memory: noted from dmd code)
__gshared size_t g_ctfeCount, g_ctfeCap;

void noteCtfe(FuncDeclaration fd) nothrow
{
    if (g_ctfeCount == g_ctfeCap)
    {
        auto cap = g_ctfeCap ? g_ctfeCap * 2 : 64;
        auto p = cast(void**) c_realloc(g_ctfeFns, cap * (void*).sizeof);
        if (p is null)
            return;
        g_ctfeFns = p;
        g_ctfeCap = cap;
    }
    g_ctfeFns[g_ctfeCount++] = cast(void*) fd;
}

// Functions CTFE ran since record `from` are no longer swappable, whichever
// document they are in: their bodies are part of what the caller saw.
void dropCtfed(ref Engine e, size_t from)
{
    foreach (k; from .. g_ctfeCount)
        foreach (ref d; e.patch.docs)
            foreach (i, ref sp; d.spans)
                if (sp.fd is g_ctfeFns[k] && i < d.pristine.length)
                    d.pristine[i] = null;
}

bool ctfeCalled(void* fd) nothrow @nogc
{
    foreach (i; 0 .. g_ctfeCount)
        if (g_ctfeFns[i] is fd)
            return true;
    return false;
}

// Function bodies of `m` as parsed from `text`, in source order: functions at
// module level, in aggregates and attribute blocks (both branches of a
// condition). Not inside templates, mixins or `static foreach`: those are
// part of what others see.
BodySpan[] bodySpans(Module m, const(char)[] text)
{
    import dmd.attrib : AttribDeclaration, ConditionalDeclaration;
    import dmd.dsymbol : Dsymbol, DSYM;
    import dmd.arraytypes : Dsymbols;

    uint[] lineStart = [0];
    foreach (i, c; text)
        if (c == '\n')
            lineStart ~= cast(uint)(i + 1);
    uint offsetOf(Loc loc)
    {
        uint l = loc.linnum(), c = loc.charnum();
        if (l < 1 || l > lineStart.length || c < 1)
            return uint.max;
        return lineStart[l - 1] + c - 1;
    }
    BodySpan[] res;
    void walk(Dsymbols* members)
    {
        if (!members)
            return;
        foreach (s; *members)
        {
            if (!s)
                continue;
            if (auto fd = s.isFuncDeclaration())
            {
                if (!fd.fbody)
                    continue;
                immutable st = offsetOf(fd.fbody.loc), en = offsetOf(fd.endloc);
                if (st >= text.length || en >= text.length || st >= en ||
                    text[st] != '{' || text[en] != '}')
                    continue; // not a plain `{ }` body: counts as interface
                uint nl = 0;
                foreach (c; text[st .. en + 1])
                    nl += c == '\n';
                res ~= BodySpan(st, en + 1, fd.fbody.loc.linnum(), fd.endloc.linnum(), nl,
                    cast(void*) fd);
                continue;
            }
            if (s.isTemplateDeclaration() || s.isTemplateMixin())
                continue;
            if (auto ad = s.isAttribDeclaration())
            {
                if (ad.dsym == DSYM.staticForeachDeclaration ||
                    ad.dsym == DSYM.mixinDeclaration)
                    continue;
                walk(ad.decl);
                if (ad.dsym == DSYM.conditionalDeclaration || ad.dsym == DSYM.staticIfDeclaration)
                    walk((cast(ConditionalDeclaration) ad).elsedecl);
                continue;
            }
            if (auto ag = s.isAggregateDeclaration())
                walk(ag.members);
        }
    }
    walk(m.members);
    return res;
}

// The bytes of `fd` if its body may be re-analysed in place later: a plain
// function (no constructor, destructor, ... whose analysis touches its
// aggregate), analysed up to semantic 2, with declared return type and
// attributes and no contracts. Null otherwise.
void[] snapshotFunction(FuncDeclaration fd)
{
    if (fd is null || fd.isFuncLiteralDeclaration() || fd.isFuncAliasDeclaration() ||
        fd.isCtorDeclaration() || fd.isPostBlitDeclaration() || fd.isDtorDeclaration() ||
        fd.isStaticCtorDeclaration() || fd.isStaticDtorDeclaration() ||
        fd.isInvariantDeclaration() || fd.isUnitTestDeclaration() || fd.isNewDeclaration())
        return null;
    if (fd._scope is null || fd.errors || fd.semanticRun >= PASS.semantic3 ||
        fd.inferRetType || fd.purityInprocess || fd.safetyInprocess ||
        fd.nothrowInprocess || fd.nogcInprocess || fd.frequires || fd.fensures ||
        fd.isNested())
        return null;
    enum size = __traits(classInstanceSize, FuncDeclaration);
    // Scanned memory: the bytes point into the level's objects.
    auto copy = new void*[(size + (void*).sizeof - 1) / (void*).sizeof];
    memcpy(copy.ptr, cast(void*) fd, size);
    return (cast(void*) copy.ptr)[0 .. size];
}

// Patch what changed since the overlay was built onto it, and answer `path`
// from it: pop the previous patch (back to the base), make `path` a root of
// the overlay if it is not one (its bodies finished, or parsed and analysed),
// then, on a patch level, swap in the edited bodies of every document that
// changed. False when something changed that patches cannot take: rebuild.
bool tryIncremental(ref Engine e, const(char)[] path, const(char)[] text, ulong h,
    ref Analysis out_)
{
    if (!e.overlay || e.overlayVariant || e.recordFolds || e.isolated.length ||
        e.patch.diskChanged)
        return false;
    // Patches keep every level and what the overlay loaded: none of it may
    // have changed on disk (a change without a notification; see ensureDeps).
    if (changedOnDisk(e))
        return false;
    // Nothing changed since the patch: a root it patched is answered from it
    // (its analysis is built when first asked for).
    if (e.patch.patched && e.overlayGeneration == e.generation)
        foreach (ref pl; e.patch.plans)
            if (e.patch.docs[pl.doc].path == path && e.patch.docs[pl.doc].root)
            {
                auto a = patchedAnalysis(e, e.patch.docs[pl.doc], pl);
                replaceRoot(e, path, fnv1a64(cast(const(ubyte)[]) pl.text), a);
                out_ = a;
                return true;
            }
    unpatch(e);

    // `path` as a root of the overlay, at the text dmd loaded it from.
    auto d = findDoc(e, path);
    if (d is null || !d.root)
    {
        auto m = findLoaded(path);
        string baseText;
        if (m is null)
            baseText = text.idup; // new: parsed from the buffer
        else if (d !is null)
            baseText = d.text; // an open document another root imported
        else
        {
            // Loaded from disk on a dependency level: fine while unedited.
            import session : sessionReadDisk;

            baseText = sessionReadDisk(path);
            if (baseText is null || (text != baseText && contains(e.edited, path)))
                return false;
        }
        analyzeRoot(e, path, baseText, fnv1a64(cast(const(ubyte)[]) baseText), false,
            m is null ? "new-root" : "finish-bodies");
        d = findDoc(e, path);
        if (d is null || !d.root)
        {
            // Not patchable (e.g. it does not parse): answer from the root's
            // analysis only if that is the current text.
            if (baseText != text)
                return false;
            out_ = rootAnalysis(e, path);
            e.overlayGeneration = e.generation;
            return true;
        }
    }

    // What changed since the overlay loaded it.
    auto t0 = nowMs();
    DocPlan[] plans;
    foreach (i, ref doc; e.patch.docs)
    {
        auto cur = doc.path == path ? text : currentText(e, doc.path);
        if (cur !is null && cur != doc.text)
            plans ~= DocPlan(i, cur);
    }
    // Open documents the overlay did not load, changed since it registered
    // them: a later load must read the buffer.
    const(char)[][] stale;
    if (e.docs.openPaths !is null)
        foreach (p; e.docs.openPaths())
            if (findDoc(e, p) is null)
                if (auto r = p in e.overlayTexts)
                {
                    auto cur = e.docs.open(p);
                    if (cur !is null && cur != *r)
                        stale ~= p;
                }
    if (!plans.length && !stale.length)
    {
        restoreRoots(e);
        e.overlayGeneration = e.generation;
        out_ = rootAnalysis(e, path);
        return true;
    }

    levelPush(dmdGlobalRanges());
    e.patch.patched = true;
    e.patch.sinkMark = e.sink.msgs.length;
    string why;
    bool ok;
    {
        levelEnter();
        scope (exit)
            levelLeave();
        foreach (p; stale)
            registerBuffer(p, e.docs.open(p));
        ok = true;
        foreach (ref pl; plans)
            if (!planDoc(e, pl, why))
            {
                ok = false;
                break;
            }
        if (ok)
            why = applyPlans(e, plans);
    }
    if (!ok)
    {
        unpatch(e);
        traceMs("patch.declined", nowMs() - t0, why ~ " " ~ path);
        return false;
    }
    // The roots' analyses: the base's for those unchanged; for `path` its
    // patched one; the other patched roots' when asked for (see above).
    restoreRoots(e);
    e.patch.plans = plans;
    foreach (ref pl; plans)
        if (e.patch.docs[pl.doc].root)
        {
            auto pd = &e.patch.docs[pl.doc];
            if (pd.path == path)
                replaceRoot(e, path, fnv1a64(cast(const(ubyte)[]) pl.text),
                    patchedAnalysis(e, *pd, pl));
            else
                dropRoot(e, pd.path);
        }
    e.overlayGeneration = e.generation;
    traceMs("analyze.patch", nowMs() - t0, why ~ " " ~ path);
    engineCheckIdentifiers("after patch");
    out_ = rootAnalysis(e, path);
    return true;
}

// A document's edit, as a patch: its new text parsed, its bodies, and which
// of them changed.
struct DocPlan
{
    size_t doc; // index in e.patch.docs
    const(char)[] text;
    Module parsed;
    BodySpan[] spans;
    size_t[] changed;
}

// Drop the patch level: every document is back at the text the overlay
// loaded, and the roots at their base analyses.
void unpatch(ref Engine e)
{
    if (!e.patch.patched)
        return;
    levelPop();
    e.patch.patched = false;
    e.patch.plans = null;
    e.sink.msgs.length = e.patch.sinkMark;
    restoreRoots(e);
}

void dropRoot(ref Engine e, const(char)[] path)
{
    foreach (i, ref r; e.roots)
        if (r.path == path)
        {
            e.roots[i] = e.roots[$ - 1];
            e.roots.length--;
            return;
        }
}

void restoreRoots(ref Engine e)
{
    foreach (ref d; e.patch.docs)
        if (d.root)
            replaceRoot(e, d.path, fnv1a64(cast(const(ubyte)[]) d.text), d.base);
}

Analysis rootAnalysis(ref Engine e, const(char)[] path)
{
    foreach (ref r; e.roots)
        if (r.path == path)
            return r.a;
    return Analysis.init;
}

DocBase* findDoc(ref Engine e, const(char)[] path)
{
    foreach (ref d; e.patch.docs)
        if (d.path == path)
            return &d;
    return null;
}

void setDocBase(ref Engine e, DocBase d)
{
    if (auto p = findDoc(e, d.path))
        *p = d;
    else
        e.patch.docs ~= d;
}

// The document's text now: its buffer, else the disk (closed since).
const(char)[] currentText(ref Engine e, const(char)[] path)
{
    import session : sessionReadDisk;

    if (e.docs.open !is null)
        if (auto t = e.docs.open(path))
            return t;
    return sessionReadDisk(path);
}

// Record the open documents the overlay's universe loaded on the warm or the
// overlay level (imports of the roots): edits of their bodies are patched.
void noteDocs(ref Engine e)
{
    if (e.docs.open is null)
        return;
    immutable lowest = e.warmBuilt ? e.warmDepth : e.overlayDepth;
    foreach (m; Module.amodules)
    {
        immutable lv = levelOf(cast(void*) m);
        if (lv < lowest || isSynthetic(moduleName(m)))
            continue;
        auto f = m.srcfile.toString();
        if (findDoc(e, f) !is null || e.docs.open(f) is null)
            continue;
        const(char)[] text;
        if (lv >= e.overlayDepth)
            if (auto t = f in e.overlayTexts)
                text = *t;
        if (text is null)
            if (auto t = f in e.warmTexts)
                text = *t;
        if (text is null)
            continue; // not read from a buffer we know
        levelEnter();
        auto spans = bodySpans(m, text);
        levelLeave();
        auto t = levelSuspend();
        setDocBase(e, DocBase(f.idup, text.idup, spans, new void[][](spans.length), false));
        levelResume(t);
    }
}

// Parse `pl.text` and check it only differs from the document's base text
// inside function bodies that can be swapped. Parse errors are fine inside
// the edited bodies (a statement being typed): the parser recovers there.
bool planDoc(ref Engine e, ref DocPlan pl, ref string why)
{
    import dmdwrap : dmdParseNoRegister;

    auto d = &e.patch.docs[pl.doc];
    if (!d.spans.length)
        return decline(why, "no-bodies");
    size_t diagFrom = e.sink.msgs.length;
    auto pr = dmdParseNoRegister(d.path, pl.text, false);
    if (!pr.ok)
        return decline(why, "syntax-errors");
    pl.parsed = cast(Module) pr.module_;
    pl.spans = bodySpans(pl.parsed, pl.text);
    if (pl.spans.length != d.spans.length)
        return decline(why, "declarations-changed");
    // Outside the bodies, the text must be the same.
    size_t po = 0, pn = 0;
    foreach (i; 0 .. pl.spans.length + 1)
    {
        immutable oe = i < pl.spans.length ? d.spans[i].start : d.text.length;
        immutable ne = i < pl.spans.length ? pl.spans[i].start : pl.text.length;
        if (d.text[po .. oe] != pl.text[pn .. ne])
            return decline(why, "declarations-changed");
        if (i == pl.spans.length)
            break;
        po = d.spans[i].end;
        pn = pl.spans[i].end;
        if (d.text[d.spans[i].start .. po] != pl.text[pl.spans[i].start .. pn])
            pl.changed ~= i;
    }
    if (pl.changed.length > 32)
        return decline(why, "too-many-bodies");
    // Swappable: a root's function with its pre-semantic3 bytes, or one
    // nothing analysed (an import's; CTFE analyses what it runs).
    foreach (i; pl.changed)
    {
        auto fd = cast(FuncDeclaration) d.spans[i].fd;
        if (d.pristine[i] is null && fd.semanticRun >= PASS.semantic3)
            return decline(why, "body-not-swappable");
    }
    foreach (k; diagFrom .. e.sink.msgs.length)
    {
        auto m = &e.sink.msgs[k];
        bool inChanged;
        foreach (i; pl.changed)
            inChanged |= m.file == d.path && m.line >= pl.spans[i].startLine &&
                m.line <= pl.spans[i].endLine;
        if (!inChanged)
            return decline(why, "syntax-errors");
    }
    return true;
}

// Swap the planned bodies in and analyse those whose old ones were analysed.
string applyPlans(ref Engine e, DocPlan[] plans)
{
    import dmd.funcsem : functionSemantic3;
    import dmd.dsymbolsem : runDeferredSemantic3;
    import dmd.dinterpret : lspCtfeCalled;

    FuncDeclaration[] analyse;
    size_t bodies;
    foreach (ref pl; plans)
    {
        auto d = &e.patch.docs[pl.doc];
        shiftLines(*d, pl.spans);
        foreach (i; pl.changed)
        {
            auto fd = cast(FuncDeclaration) d.spans[i].fd;
            auto nfd = cast(FuncDeclaration) pl.spans[i].fd;
            if (d.pristine[i] !is null)
            {
                memcpy(cast(void*) fd, d.pristine[i].ptr, d.pristine[i].length);
                analyse ~= fd;
            }
            fd.fbody = nfd.fbody;
            fd.endloc = nfd.endloc;
            bodies++;
        }
    }
    lspCtfeCalled = &noteCtfe;
    immutable ctfeBefore = g_ctfeCount;
    foreach (fd; analyse)
        functionSemantic3(fd);
    runDeferredSemantic3();
    lspCtfeCalled = null;
    dropCtfed(e, ctfeBefore);
    recordGraph(e);
    char[40] b;
    import core.stdc.stdio : snprintf;

    auto n = snprintf(b.ptr, b.length, "%d docs, %d bodies", cast(int) plans.length,
        cast(int) bodies);
    return b[0 .. n].idup;
}

// A root's analysis after a patch of its document: the base's, its messages
// moved like the text (but those inside the bodies analysed again), the
// patch's messages for the file, lint of the patched module.
Analysis patchedAnalysis(ref Engine e, ref DocBase d, ref DocPlan pl)
{
    Analysis a;
    a.module_ = d.base.module_;
    a.ok = true;
    levelEnter();
    scope (exit)
        levelLeave();
    a.syn = snapshotModule(pl.parsed, pl.text);
    uint errs = 0;
    foreach (ref m; d.base.diags)
    {
        if (m.file != d.path)
        {
            a.diags ~= m;
            continue;
        }
        int shift = 0;
        bool inside = false;
        foreach (k, ref sp; d.spans)
        {
            if (m.line > sp.endLine)
                shift += cast(int) pl.spans[k].newlines - cast(int) sp.newlines;
            else
            {
                if (m.line >= sp.startLine)
                    foreach (c; pl.changed)
                        inside |= c == k;
                break;
            }
        }
        if (inside)
            continue;
        auto nm = m;
        nm.line = m.line + shift;
        a.diags ~= nm;
        if (nm.kind == 'E')
            errs++;
    }
    foreach (i, ref m; e.sink.msgs)
        if (i >= e.patch.sinkMark && m.file == d.path)
        {
            a.diags ~= m;
            if (m.kind == 'E')
                errs++;
        }
    a.errors = errs;
    lint(e, a, d.path, pl.text);
    return a;
}

// Files on the overlay level (not the roots), with their stamps.
void overlayFiles(ref Engine e, ref string[] files, ref ulong[] stamps)
{
    import fsutil : fileStamp;

    immutable top = levelDepth();
    files = null;
    stamps = null;
    foreach (m; Module.amodules)
    {
        if (levelOf(cast(void*) m) != top)
            continue;
        auto f = m.srcfile.toString();
        if (isSynthetic(moduleName(m)) || contains(e.rootFiles, f) || contains(e.edited, f))
            continue;
        auto t = levelSuspend();
        files ~= f.idup;
        levelResume(t);
        stamps ~= fileStamp(f);
    }
}

// Something the overlay rests on changed on disk: a dependency level's file
// (the level is marked stale) or one the patch base loaded.
bool changedOnDisk(ref Engine e)
{
    import fsutil : fileStamp;

    bool any;
    foreach (lv; [&e.libs, &e.deps])
        foreach (i, f; lv.files)
            if (fileStamp(f) != lv.stamps[i])
            {
                lv.stale = true;
                any = true;
                break;
            }
    foreach (i, f; e.patch.loadedFiles)
        if (fileStamp(f) != e.patch.loadedStamps[i])
            any = true;
    return any;
}

bool decline(ref string why, string reason)
{
    why = reason;
    return false;
}

void replaceRoot(ref Engine e, const(char)[] path, ulong h, Analysis a)
{
    foreach (ref r; e.roots)
        if (r.path == path)
        {
            r.hash = h;
            r.a = a;
            return;
        }
    e.roots ~= Root(path.idup, h, a);
}

// Make a document's positions follow its new text: from the end of each body
// on, lines move by what the bodies up to it gained (`#line`-style
// substitutions on its location table entry; the patch level undoes them).
void shiftLines(ref DocBase d, BodySpan[] spans)
{
    import dmd.location : BaseLoc;
    static import dmd.location;

    auto first = cast(FuncDeclaration) d.spans[0].fd;
    immutable idx = __traits(getMember, first.loc, "index");
    auto table = __traits(getMember, dmd.location, "locFileTable");
    BaseLoc* bl;
    foreach (entry; table)
        if (entry.startIndex <= idx)
            bl = entry;
    if (bl is null)
        return;
    BaseLoc[] subs = [BaseLoc(bl.filename, null, 0, 0)];
    int delta = 0;
    foreach (k, ref sp; d.spans)
    {
        immutable dl = cast(int) spans[k].newlines - cast(int) sp.newlines;
        if (dl == 0)
            continue;
        delta += dl;
        subs ~= BaseLoc(bl.filename, null, sp.end, delta);
    }
    bl.substitutions = subs.length > 1 ? subs : null;
    __traits(getMember, *bl, "lastSubstIndex") = 0;
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

// Analyse a root module. Between semantic 2 and 3, keep the bytes of each
// function in `spans` whose body may later be re-analysed in place.
void semanticRoot(Module m, BodySpan[] spans, ref void[][] pristine)
{
    import dmd.dsymbolsem : dsymbolSemantic, importAll, runDeferredSemantic,
        runDeferredSemantic2, runDeferredSemantic3;
    import dmd.semantic2 : semantic2;
    import dmd.semantic3 : semantic3;
    import dmd.dinterpret : lspCtfeCalled;
    import dmdwrap : dmdHasUnloadedImport;

    lspCtfeCalled = &noteCtfe;
    scope (exit)
        lspCtfeCalled = null;
    m.importAll(null);
    if (dmdHasUnloadedImport(cast(void*) m))
        return;
    m.dsymbolSemantic(null);
    runDeferredSemantic();
    m.semantic2(null);
    runDeferredSemantic2();
    pristine = new void[][](spans.length);
    foreach (i, ref sp; spans)
        pristine[i] = snapshotFunction(cast(FuncDeclaration) sp.fd);
    m.semantic3(null);
    runDeferredSemantic3();
    // Bodies something evaluated at compile time are part of what others see.
    foreach (i, ref sp; spans)
        if (pristine[i] !is null && ctfeCalled(sp.fd))
            pristine[i] = null;
}

// Analyse the bodies of a module an import loaded (semantic 3), keeping the
// bytes of each function in `spans` that may later be re-analysed in place.
void finishBodies(Module m, BodySpan[] spans, ref void[][] pristine)
{
    import dmd.semantic3 : semantic3;
    import dmd.dsymbolsem : runDeferredSemantic3;
    import dmd.dinterpret : lspCtfeCalled;

    pristine = new void[][](spans.length);
    foreach (i, ref sp; spans)
        pristine[i] = snapshotFunction(cast(FuncDeclaration) sp.fd);
    lspCtfeCalled = &noteCtfe;
    scope (exit)
        lspCtfeCalled = null;
    m.semantic3(null);
    runDeferredSemantic3();
    foreach (i, ref sp; spans)
        if (pristine[i] !is null && ctfeCalled(sp.fd))
            pristine[i] = null;
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

module server;

version (Windows)
{
    // CRT low-level I/O (module scope, so they get C linkage).
    extern (C) int _dup(int) nothrow;
    extern (C) int _dup2(int, int) nothrow;
    extern (C) int _close(int) nothrow;
}

// Daemon state + analysis pipeline. Struct-only, no classes.

import arena;
import session;
import dmdwrap;
import lint;
import complete;

import dmd.dmodule : Module;
import core.memory : GC;

struct ServerState
{
    Arena scratch;   // per-request (diagnostics, lint hits, completions)
    Session session; // perm arena inside
    DmdState dmd;
    DiagSink sink;
    Universe uni; // live-universe cache (see below)
}

// dmd's message-kind diagnostics bypass DiagnosticHandler and write to
// stdout directly (errors.d emit). During analysis, reroute fd 1 to
// stderr so LSP framing / --check stdout stay machine-clean.
struct StdoutGuard
{
    int saved = -1;
    bool active = false;
}

private void stdoutToStderr(ref StdoutGuard g)
{
    version (Posix)
    {
        import core.stdc.stdio : fflush, stdout;
        import core.sys.posix.unistd : dup, dup2;

        fflush(stdout);
        g.saved = dup(1);
        if (g.saved >= 0)
        {
            dup2(2, 1);
            g.active = true;
        }
    }
    else version (Windows)
    {
        import core.stdc.stdio : fflush, stdout;

        fflush(stdout);
        g.saved = _dup(1);
        if (g.saved >= 0)
        {
            _dup2(2, 1);
            g.active = true;
        }
    }
}

private void stdoutRestore(ref StdoutGuard g)
{
    version (Windows)
    {
        import core.stdc.stdio : fflush, stdout;

        if (!g.active)
            return;
        fflush(stdout);
        _dup2(g.saved, 1);
        _close(g.saved);
        g.active = false;
        return;
    }
    version (Posix)
    {
        import core.stdc.stdio : fflush, stdout;
        import core.sys.posix.unistd : dup2, close;

        if (!g.active)
            return;
        fflush(stdout);
        dup2(g.saved, 1);
        close(g.saved);
        g.saved = -1;
        g.active = false;
    }
}

void serverInit(ref ServerState s, string[] imports, string[] stringImports = null,
    string[] flags = null)
{
    s.dmd.importPaths = imports;
    s.dmd.stringPaths = stringImports;
    s.dmd.flags = flags;
    dmdInit(s.dmd);
}

void serverShutdown(ref ServerState s)
{
    dmdDeinit(s.dmd);
    s.scratch.freeAll();
    s.session.perm.freeAll();
}

struct Analysis
{
    void* module_ = null; // opaque dmd Module* (post-semantic)
    bool ok = false;
    uint errors = 0;
    DiagMsg[] diags;
    LintOut lintImports;
    LintOut lintParams;
    SynMod syn; // pre-semantic structure snapshot (see dmdwrap)
}

// Pin lint hits into the long-lived perm arena: scratch is reset per
// request and dmd-owned strings die with their universe + GC.collect().
private void pinLint(ref Session session, ref LintOut o)
{
    if (!o.nhits)
        return;
    UnusedHit* p = cast(UnusedHit*)session.perm.alloc(o.nhits * UnusedHit.sizeof);
    if (!p)
    {
        o.nhits = 0;
        return;
    }
    for (size_t i = 0; i < o.nhits; i++)
    {
        p[i] = o.hits[i];
        p[i].path = permDup(session, o.hits[i].path);
        p[i].name = permDup(session, o.hits[i].name);
    }
    o.hits = p;
    o.capHits = o.nhits;
}

private string permDup(ref Session session, const(char)[] s)
{
    char* p = cast(char*)session.perm.alloc(s.length + 1);
    if (!p)
        return null;
    p[0 .. s.length] = s[];
    p[s.length] = 0;
    return cast(string)(p[0 .. s.length]);
}

// Live-universe cache: the last analysis whose dmd state is still alive.
// A hit (same root text, same dep bytes, same config) returns the cached
// analysis with zero dmd work — completions/codeActions after a change
// analysis are ~free. Anything else rebuilds via dmdResetRequest.
// The "re-parse only the changed root" path (serverAnalyzeIncremental)
// re-parses the *same* Module object in place (dmdReparseModule): it evicts
// the module's interned types and resets the per-generation frontend caches,
// which avoids the "module specified twice" / "already exists" collisions a
// plain re-parse would hit and keeps memory flat across edits, so it runs in
// the long-lived process. A dependency/config/root change still takes the
// full-reset path.
struct Universe
{
    bool valid = false;
    string rootPath;
    ulong rootHash; // fnv1a64 of the document (identity) text
    // The text actually parsed. Equals rootHash's text normally; differs
    // when a completion built the universe from a trailing-dot placeholder
    // while still keying on the real document text (so the debounced
    // analyze for that same text is a hit, not a second build).
    ulong analysisHash;
    ulong tokenHash; // significant-token fingerprint of the parsed text
    DepRec[] deps; // disk fingerprints of loaded deps (root excluded)
    ulong configGen; // DmdState.configGen at record time
    Arena.Mark mark; // scratch high-water after analysis
    Analysis analysis; // module_/syn live while no reset happened since
    // Location-table checkpoint: dmd appends a BaseLoc (holding the whole
    // file content) on every parse. Incremental re-parses roll back to this
    // so the table does not grow one file copy per edit.
    size_t locTableLen;
    uint locIndex;
}

// True when serverAnalyze would serve `path`/`text` from the live universe
// without any dmd work. Used to decide whether a request can be served from
// the warm universe or requires a rebuild.
bool serverWouldHit(ref ServerState s, const(char)[] path, const(char)[] text)
{
    import session : fnv1a64;

    ulong h = fnv1a64(cast(const(ubyte)[])text);
    return s.uni.valid && s.uni.configGen == s.dmd.configGen &&
        s.uni.rootPath == path && s.uni.rootHash == h &&
        !universeDepsChanged(s.uni.deps);
}

// Hit check keyed on the *analysis* text (what was actually parsed), not the
// document identity. Completion neutralises the partial member
// (`s.ab` -> `s.__dmd_lsp_ph()`), so growing a name keeps the analysis text
// the same and reuses the universe; the cursor/prefix still come from the
// real text. Semantic tokens use it to require a universe built from the real
// text (never a completion placeholder). The root path must match, or the
// universe is another file's.
bool serverWouldHitAnalysis(ref ServerState s, const(char)[] path,
    const(char)[] analysis)
{
    import session : fnv1a64;

    return s.uni.valid && s.uni.configGen == s.dmd.configGen &&
        s.uni.rootPath == path &&
        s.uni.analysisHash == fnv1a64(cast(const(ubyte)[])analysis) &&
        !universeDepsChanged(s.uni.deps);
}

enum UniState : ubyte
{
    miss,        // different root/config/deps: needs a fresh universe
    reuse,       // identical inputs: serve the warm analysis
    incremental, // same root/config/deps, root text moved: re-parse in place
}

// Classify a request against the live universe. `identity` is the document
// text the universe must be rooted on (matches rootHash); `analysis` is the
// exact buffer that must have been parsed (matches analysisHash), or null to
// ignore it. Passing null for identity (completion) avoids a false reuse when
// only the neutralised text, not the document, is unchanged. The dependency
// fingerprint is checked at most once per request.
UniState serverUniState(ref ServerState s, const(char)[] path,
    const(char)[] identity, const(char)[] analysis)
{
    import session : fnv1a64;

    if (!s.uni.valid || s.uni.configGen != s.dmd.configGen ||
        s.uni.rootPath != path)
        return UniState.miss;
    // A dependency change on disk invalidates the closure even when the root
    // text is identical, so it must be checked before declaring reuse.
    if (universeDepsChanged(s.uni.deps))
        return UniState.miss;
    if (analysis !is null &&
        s.uni.analysisHash == fnv1a64(cast(const(ubyte)[])analysis))
        return UniState.reuse;
    if (identity !is null &&
        s.uni.rootHash == fnv1a64(cast(const(ubyte)[])identity))
        return UniState.reuse;
    // Same root, config and deps: only the root's text moved, which the worker
    // can re-analyze on the warm closure.
    return UniState.incremental;
}

// Re-analyse only the root on top of the live dependency closure: re-parse
// the *same* Module object in place (dmdReparseModule) so importers keep
// pointing at it, which is what makes the mutation flat and safe to run in the
// long-lived process. This is ~10x cheaper than a full
// build and advances the live universe to the new text.
// Parse-only diagnostics path (open/save use the full semantic one). It never
// touches the live universe: throwaway parse + AST lints only (syntax errors
// and unused imports/params), no semantic analysis. So a half-typed statement
// cannot cascade and a stale warm closure cannot leak into diagnostics.
// Runs on a fresh dmd state, so the caller must isolate it (fork child on
// POSIX); on Windows the caller marks the universe invalid afterwards.
Analysis serverLint(ref ServerState s, const(char)[] path, const(char)[] text)
{
    Analysis a;
    s.scratch.reset();
    dmdResetRequest(s.dmd, &s.sink);
    StdoutGuard og;
    stdoutToStderr(og);
    auto pr = dmdParseOnly(path, text);
    a.ok = pr.ok;
    a.errors = pr.errors;
    a.diags = s.sink.msgs;
    if (pr.ok && pr.module_)
    {
        auto mod = cast(Module)pr.module_;
        lintUnusedImports(&s.scratch, mod, path, text, pr.errors != 0, a.lintImports);
        lintUnusedParams(&s.scratch, mod, path, text, pr.errors != 0, a.lintParams);
        pinLint(s.session, a.lintImports);
        pinLint(s.session, a.lintParams);
    }
    stdoutRestore(og);
    return a;
}

Analysis serverAnalyzeIncremental(ref ServerState s, const(char)[] path,
    const(char)[] text, const(char)[] identity)
{
    import session : fnv1a64;

    auto id = identity is null ? text : identity;
    s.scratch.reset();
    s.sink.reset();
    dmdResetCounters();
    Analysis a;
    StdoutGuard og;
    stdoutToStderr(og);
    // Drop BaseLocs appended by the previous incremental parse (they belong to
    // the root being replaced) before this parse appends its own.
    dmdLocRollback(s.uni.locTableLen, s.uni.locIndex);
    auto modp = dmdReparseModule(s.uni.analysis.module_, text);
    if (!modp)
    {
        // The in-place parse failed (e.g. the buffer did not convert); fall
        // back to a full universe reset so the request still gets an answer.
        stdoutRestore(og);
        return serverAnalyze(s, path, text, identity);
    }
    a.syn = snapshotModule(cast(Module)modp);
    auto errs = dmdSemantic(modp);
    stdoutRestore(og);
    a.module_ = modp;
    a.ok = true;
    a.errors = errs;
    a.diags = s.sink.msgs;
    {
        auto mod = cast(Module)a.module_;
        lintUnusedImports(&s.scratch, mod, path, text, errs != 0, a.lintImports);
        lintUnusedParams(&s.scratch, mod, path, text, errs != 0, a.lintParams);
        pinLint(s.session, a.lintImports);
        pinLint(s.session, a.lintParams);
    }
    if (id !is text)
        mapFixDiags(a.diags, id, text);
    s.uni.valid = true;
    s.uni.rootPath = path.idup;
    s.uni.rootHash = fnv1a64(cast(const(ubyte)[])id);
    s.uni.analysisHash = fnv1a64(cast(const(ubyte)[])text);
    s.uni.tokenHash = dmdTokenHash(text);
    universeRecord(s.uni.deps, path);
    s.uni.configGen = s.dmd.configGen;
    s.uni.mark = s.scratch.mark();
    s.uni.analysis = a;
    return a;
}

// Full pipeline for one root file. Two levels:
//   hit:  inputs identical to the live universe — return cached analysis.
//   full: anything else — fresh universe via dmdResetRequest.
// Structure is snapshotted between parse and semantic because semantic
// rewrites bodies in place (failed statements propagate ErrorStatement
// up to fbody).
// `identity` is the document text the universe is keyed on; `text` is what
// is actually parsed. They differ only for a trailing-dot completion, where
// `text` is the placeholder variant. Defaults to identity == text.
Analysis serverAnalyze(ref ServerState s, const(char)[] path, const(char)[] text,
    const(char)[] identity = null)
{
    import session : fnv1a64;

    auto id = identity is null ? text : identity;
    ulong h = fnv1a64(cast(const(ubyte)[])id);
    if (s.uni.valid && s.uni.configGen == s.dmd.configGen &&
        s.uni.rootPath == path && s.uni.rootHash == h &&
        !universeDepsChanged(s.uni.deps))
    {
        s.scratch.rewind(s.uni.mark);
        return s.uni.analysis;
    }
    Analysis a;
    s.scratch.reset();
    dmdResetRequest(s.dmd, &s.sink);
    StdoutGuard og;
    stdoutToStderr(og);
    auto pr = dmdParseOnly(path, text);
    if (pr.ok && pr.module_)
        a.syn = snapshotModule(cast(Module)pr.module_);
    auto errs = pr.ok ? dmdSemantic(pr.module_) : pr.errors;
    stdoutRestore(og);
    a.module_ = pr.module_;
    a.ok = pr.ok;
    a.errors = errs;
    a.diags = s.sink.msgs;
    if (pr.ok && pr.module_)
    {
        auto mod = cast(Module)pr.module_;
        lintUnusedImports(&s.scratch, mod, path, text, errs != 0, a.lintImports);
        lintUnusedParams(&s.scratch, mod, path, text, errs != 0, a.lintParams);
        pinLint(s.session, a.lintImports);
        pinLint(s.session, a.lintParams);
    }
    if (id !is text)
        mapFixDiags(a.diags, id, text);
    // Record the live universe for hit requests.
    s.uni.valid = true;
    s.uni.rootPath = path.idup;
    s.uni.rootHash = h;
    s.uni.analysisHash = fnv1a64(cast(const(ubyte)[])text);
    s.uni.tokenHash = dmdTokenHash(text);
    universeRecord(s.uni.deps, path);
    s.uni.configGen = s.dmd.configGen;
    s.uni.mark = s.scratch.mark();
    s.uni.analysis = a;
    dmdLocCheckpoint(s.uni.locTableLen, s.uni.locIndex);
    // Reclaim dmd GC garbage so the daemon stays flat.
    GC.collect();
    return a;
}

// The placeholder is a pure insertion at the cursor. Diagnostics it
// produces beyond that point carry shifted columns on the fix line (the
// inserted text has no newline, so line numbers are unaffected). Rewrite
// the diagnostics in place to document coordinates.
private void mapFixDiags(ref DiagMsg[] diags, const(char)[] doc, const(char)[] parsed)
{
    if (parsed.length <= doc.length)
        return; // only a pure insertion is expected here
    size_t p = 0;
    while (p < doc.length && doc[p] == parsed[p])
        p++;
    if (p == doc.length)
        return; // insertion is at the very end: no positions shift
    size_t insLen = parsed.length - doc.length;
    uint fixLine = 1;
    uint fixCol = 1;
    for (size_t i = 0; i < p; i++)
    {
        if (doc[i] == '\n')
        {
            fixLine++;
            fixCol = 1;
        }
        else
            fixCol++;
    }
    size_t w = 0;
    foreach (ref d; diags)
    {
        if (d.line == fixLine && d.col >= fixCol)
        {
            if (d.col < fixCol + insLen)
                continue; // diagnostic inside the inserted placeholder
            d.col -= cast(uint)insLen;
        }
        diags[w++] = d;
    }
    diags.length = w;
}

void serverOnOpen(ref ServerState s, const(char)[] path, const(char)[] text)
{
    sessionOpen(s.session, path, text);
}

void serverOnChange(ref ServerState s, const(char)[] path, const(char)[] text)
{
    sessionUpdate(s.session, path, text);
}

void serverOnClose(ref ServerState s, const(char)[] path)
{
    sessionClose(s.session, path);
}

module server;

// Analysis entry points for the LSP handlers: the engine (engine.d) plus the
// per-request scratch they share. Struct-only, no classes.

import arena;
import session;
import dmdwrap;
import lint;
import complete;
import lexutil : LexCache;
public import engine : Analysis, Engine, EngineConfig, DocProvider, engineDocChanged, engineRoots,
    engineDiskChanged, engineReset, engineHardReset, engineScratch, engineCheckIdentifiers;
import engine;

import dmd.dmodule : Module;

struct ServerState
{
    Arena scratch;   // per-request (completions, hover text, ...)
    Session session; // perm arena: parse-only lint hits (serverLint)
    Engine engine;
    LexCache lex; // reusable NUL-terminated text copy for lexing
}

void serverInit(ref ServerState s, string[] imports, string[] stringImports = null,
    string[] flags = null)
{
    EngineConfig cfg;
    cfg.importPaths = imports;
    cfg.stringPaths = stringImports;
    cfg.flags = flags;
    engineConfigure(s.engine, cfg);
}

void serverShutdown(ref ServerState s)
{
    engineConfigure(s.engine, s.engine.cfg); // drops every level
    s.scratch.freeAll();
    s.session.perm.freeAll();
}

// Analyse `path`. `text` is what dmd parses; `identity` is the document text
// when `text` is a variant of it (a completion/signature placeholder), whose
// diagnostics are mapped back to document coordinates. The result is valid
// until the next analysis that changes the overlay (see engine.d).
Analysis serverAnalyze(ref ServerState s, const(char)[] path, const(char)[] text,
    const(char)[] identity = null)
{
    if (identity is null || identity == text)
        return engineAnalyze(s.engine, path, text);
    auto a = engineAnalyzeVariant(s.engine, path, text);
    mapFixDiags(a.diags, identity, text);
    return a;
}

// Parse-only diagnostics and lint for `text` (no semantic): the fast pass
// while typing. Leaves no dmd state behind.
Analysis serverLint(ref ServerState s, const(char)[] path, const(char)[] text)
{
    import layers : levelSuspend, levelResume;

    Analysis a;
    DiagSink sink;
    auto saved = gSink;
    gSink = &sink;
    scope (exit)
        gSink = saved;
    s.session.perm.reset();
    engineScratch(s.engine, () {
        auto pr = dmdParseNoRegister(path, text, false); // false: emit diagnostics
        a.ok = pr.ok;
        a.errors = pr.errors;
        if (pr.ok && pr.module_)
        {
            auto m = cast(Module) pr.module_;
            lintUnusedImports(&s.scratch, m, path, text, pr.errors != 0, a.lintImports);
            lintUnusedParams(&s.scratch, m, path, text, pr.errors != 0, a.lintParams);
            // The hits may point into this scratch level: copy them out.
            auto t = levelSuspend();
            pinLint(s.session, a.lintImports);
            pinLint(s.session, a.lintParams);
            levelResume(t);
        }
    });
    a.diags = sink.msgs; // level 0 (see onDiag)
    return a;
}

private void pinLint(ref Session session, ref LintOut o)
{
    if (!o.nhits)
        return;
    UnusedHit* p = cast(UnusedHit*) session.perm.alloc(o.nhits * UnusedHit.sizeof);
    if (!p)
    {
        o.nhits = 0;
        return;
    }
    foreach (i; 0 .. o.nhits)
    {
        p[i] = o.hits[i];
        p[i].path = permDup(session, o.hits[i].path);
        p[i].name = permDup(session, o.hits[i].name);
    }
    o.hits = p;
    o.capHits = o.nhits;
    o.skipReason = o.skipReason.idup;
}

private string permDup(ref Session session, const(char)[] s)
{
    char* p = cast(char*) session.perm.alloc(s.length + 1);
    if (!p)
        return null;
    p[0 .. s.length] = s[];
    p[s.length] = 0;
    return cast(string)(p[0 .. s.length]);
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

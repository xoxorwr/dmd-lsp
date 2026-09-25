module server;

// Analysis entry points for the LSP handlers: the engine (engine.d) plus the
// per-request scratch they share. Struct-only, no classes.

import arena;
import session;
import dmdwrap;
import lexutil : LexCache;
public import engine : Analysis, Engine, EngineConfig, DocProvider, engineDocChanged, engineRoots,
    engineDiskChanged, engineReset, engineHardReset, engineScratch, engineCheckIdentifiers,
    engineBeginUnfolded, engineEndUnfolded;
import engine;

struct ServerState
{
    Arena scratch;   // per-request (completions, hover text, ...)
    Session session;
    Engine engine;
    LexCache lex; // reusable NUL-terminated text copy for lexing
}

void serverInit(ref ServerState s, string[] imports, string[] stringImports = null,
    string[] flags = null, string[] libraries = null)
{
    EngineConfig cfg;
    cfg.importPaths = imports;
    cfg.stringPaths = stringImports;
    cfg.flags = flags;
    cfg.libraryPaths = libraries;
    engineConfigure(s.engine, cfg);
}

void serverShutdown(ref ServerState s)
{
    engineConfigure(s.engine, s.engine.cfg); // drops every level
    s.scratch.freeAll();
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

// dmd-lsp: LSP front end (struct-only). All dmd work happens in the
// worker (see worker.d); this module holds only session/config
// state and formats results.
module main;

version (Windows)
{
    extern (C) int _setmode(int fd, int mode) nothrow;
    extern (C) int _fileno(void*) nothrow;
}

import core.stdc.stdio : printf, fprintf, stderr;
import core.stdc.stdlib : getenv;
import core.stdc.signal : signal, SIG_IGN;
version (Posix)
    import core.sys.posix.signal : SIGPIPE;
import core.memory : GC;
import json;

import lsp;
import server;
import session;
import worker;
import pathutil : dirOf, isDlsJson, resolveCfgPath, sameDir;
import complete : extractPrefix;
import semantic : tokenTypes, tokenModifiers;

struct HitCache
{
    worker.WAnalysis analysis; // last analysis (lint, for codeAction)
}

struct App
{
    Session session; // open document texts (perm arena inside)
    HitCache[string] cache; // GC map, cold path only
    bool shutdownRequested = false;
    bool labelDetails = false; // client supports CompletionItem.labelDetails
    string[] pending; // paths with unanalyzed changes (debounced analysis)
    ulong lastMsgMs = 0; // last stdin activity, monotonic ms
    ulong debounceMs = 500; // idle delay before analyzing pending changes
    bool debounceSet = false; // true when --debounce-ms= was given (beats file)
    // Explicit paths: CLI flags, replaced wholesale by editor settings.
    // Effective lists (explicit ++ file ++ builtin defaults) recomputed by
    // refreshImports; applied at worker init.
    string[] baseImports;
    string[] baseStringImports;
    string[] baseFlags; // dmd flags from CLI (--flag=...)
    string[] importPaths; // effective
    string[] stringPaths; // effective
    string[] flags; // effective dmd flags (CLI ++ dls.json)
    ulong configGen = 0; // bumped on import-path change; invalidates worker
    FileConfig fileCfg; // project dls.json (see below)
    worker.Worker wk; // analysis worker (lazy)
    // Semantic tokens: last result per path and the text hash it was computed
    // from, so a pull that arrives mid-edit is served from cache instead of
    // forcing a synchronous rebuild per keystroke.
    worker.WToken[][string] tokCache;
    ulong[string] tokHash;
    bool wantSemantic = false; // client supports textDocument/semanticTokens
    bool semanticRefresh = false; // client supports workspace/semanticTokens/refresh
    bool watchFiles = false; // client supports workspace/didChangeWatchedFiles
    string root; // workspace root from initialize (scopes the config watcher)
    ulong nextReqId = 0; // ids for our own server->client requests
}

// Project config file (`dls.json` at the workspace root): checked-in
// project truth used as the defaults layer — explicit CLI/editor paths
// stay in front, builtin defaults last.
struct FileConfig
{
    bool loaded = false;
    string root; // workspace root the file was read from
    string configPath; // <root>/dls.json (reloaded on didSave)
    string[] imports; // resolved absolute
    string[] stringImports; // resolved absolute
    string[] flags; // raw dmd flags from the project file
    ulong debounceMs;
    bool hasDebounce = false;
}

// Monotonic milliseconds (debounce clock; no phobos).
private ulong nowMs()
{
    // core.time.MonoTime is portable (clock_gettime on Linux, which
    // core.sys.posix.time does not expose on macOS, mach_absolute_time on
    // Darwin, QPC on Windows). Duration ticks are hectonanoseconds.
    import core.time : MonoTime;

    return cast(ulong)(MonoTime.currTime.ticks / 10_000);
}

private bool hasPending(App* app, const(char)[] path)
{
    foreach (p; app.pending)
        if (p == path)
            return true;
    return false;
}

private void markPending(App* app, const(char)[] path)
{
    if (!hasPending(app, path))
        app.pending ~= path.idup;
}

private void clearPending(App* app, const(char)[] path)
{
    foreach (i, p; app.pending)
    {
        if (p == path)
        {
            app.pending[i] = app.pending[$ - 1];
            app.pending.length--;
            return;
        }
    }
}

private JsonNode* jpos(Json js, uint l, uint c)
{
    auto o = js.create_object();
    js.add_number_to_object(o, "line", cast(double)l);
    js.add_number_to_object(o, "character", cast(double)c);

    return o;
}

// Optional string field: JSON null when empty (matches old output).
private void jaddStrOpt(Json js, JsonNode* o, const(char)* k, const(char)[] v)
{
    if (v.length)
        js.add_string_to_object(o, k, zstr(v));
    else
        js.add_null_to_object(o, k);
}

private JsonNode* jrange(Json js, uint sl, uint sc, uint el, uint ec)
{
    auto o = js.create_object();
    js.add_item_to_object(o, "start", jpos(js, sl, sc));
    js.add_item_to_object(o, "end", jpos(js, el, ec));
    return o;
}

private JsonNode* buildDiagnostics(Json js, const ref worker.WAnalysis a)
{
    auto arr = js.create_array();
    foreach (ref d; a.diags)
    {
        if (d.kind != 'E' && d.kind != 'W' && d.kind != 'D')
            continue;
        uint sev = d.kind == 'E' ? 1 : 2;
        uint l = d.line > 0 ? d.line - 1 : 0;
        uint c = d.col > 0 ? d.col - 1 : 0;
        auto r = js.create_object();
        js.add_item_to_object(r, "range", jrange(js, l, c, l, c + 1));
        js.add_number_to_object(r, "severity", sev);
        js.add_string_to_object(r, "source", "dmd");
        js.add_string_to_object(r, "message", zstr(d.text));
        js.add_item_to_array(arr, r);
    }
    void addHint(uint line1, uint col1, string msg, string code)
    {
        uint l = line1 > 0 ? line1 - 1 : 0;
        uint c = col1 > 0 ? col1 - 1 : 0;
        auto r = js.create_object();
        js.add_item_to_object(r, "range", jrange(js, l, c, l, c + 1));
        js.add_number_to_object(r, "severity", 4);
        js.add_string_to_object(r, "source", "dmd-lsp");
        js.add_string_to_object(r, "code", zstr(code));
        js.add_string_to_object(r, "message", zstr(msg));
        js.add_item_to_array(arr, r);
    }
    foreach (ref h; a.lintImports.hits)
        addHint(h.line, h.col, "unused import `" ~ h.name ~ "`", "unused-import");
    foreach (ref h; a.lintParams.hits)
        addHint(h.line, h.col, "unused parameter `" ~ h.name ~ "`", "unused-param");
    return arr;
}

// Run an analyze request against the worker, respawning once if needed.
// already served its single universe. `realOnly` forces the universe to have
// parsed the real text (open/save, where diagnostics must be exact); false
// lets the analyze reuse a live completion placeholder by identity, which is
// the cheap path while typing.
private bool workerAnalyzeRetry(App* app, const(char)[] path, const(char)[] text,
    ref worker.WAnalysis out_, bool realOnly = false)
{
    for (int attempt = 0; attempt < 2; attempt++)
    {
        if (!app.wk.alive)
        {
            if (!workerSpawn(app.wk, app.importPaths, app.stringPaths, app.flags))
                return false;
        }
        auto r = workerAnalyze(app.wk, path, text, out_, realOnly);
        if (r == worker.ExchangeResult.ok)
            return true;
        if (r == worker.ExchangeResult.failed || r == worker.ExchangeResult.respawn)
        {
            workerKill(app.wk);
            continue;
        }
        return false;
    }
    return false;
}

// Run a completion request against the worker, respawning once if needed.
private bool workerCompleteRetry(App* app, const(char)[] path, const(char)[] atext,
    const(char)[] origText, uint line, uint col, const(char)[] prefix,
    ref worker.WItem[] items)
{
    for (int attempt = 0; attempt < 2; attempt++)
    {
        if (!app.wk.alive)
        {
            if (!workerSpawn(app.wk, app.importPaths, app.stringPaths, app.flags))
                return false;
        }
        auto r = workerComplete(app.wk, path, atext, origText, line, col, prefix, items);
        if (r == worker.ExchangeResult.ok)
            return true;
        if (r == worker.ExchangeResult.respawn || r == worker.ExchangeResult.failed)
        {
            // Respawn the worker.
            workerKill(app.wk);
            continue;
        }
        if (!app.wk.alive)
            continue;
        return false;
    }
    return false;
}

// Run a signature-help request against the worker, respawning once if needed.
private bool workerSignatureRetry(App* app, const(char)[] path, const(char)[] atext,
    const(char)[] origText, uint line, uint col, ref worker.WSig sig)
{
    for (int attempt = 0; attempt < 2; attempt++)
    {
        if (!app.wk.alive)
        {
            if (!workerSpawn(app.wk, app.importPaths, app.stringPaths, app.flags))
                return false;
        }
        auto r = workerSignature(app.wk, path, atext, origText, line, col, sig);
        if (r == worker.ExchangeResult.ok)
            return true;
        if (r == worker.ExchangeResult.respawn || r == worker.ExchangeResult.failed)
        {
            // Respawn the worker.
            workerKill(app.wk);
            continue;
        }
        if (!app.wk.alive)
            continue;
        return false;
    }
    return false;
}

// Run a goto-definition request against the worker, respawning once if needed.
private bool workerDefinitionRetry(App* app, const(char)[] path, const(char)[] atext,
    const(char)[] origText, uint line, uint col, ref worker.WDef def)
{
    for (int attempt = 0; attempt < 2; attempt++)
    {
        if (!app.wk.alive)
        {
            if (!workerSpawn(app.wk, app.importPaths, app.stringPaths, app.flags))
                return false;
        }
        auto r = workerDefinition(app.wk, path, atext, origText, line, col, def);
        if (r == worker.ExchangeResult.ok)
            return true;
        if (r == worker.ExchangeResult.respawn || r == worker.ExchangeResult.failed)
        {
            // Respawn the worker.
            workerKill(app.wk);
            continue;
        }
        if (!app.wk.alive)
            continue;
        return false;
    }
    return false;
}

// Run a hover request against the worker, respawning once if needed.
private bool workerHoverRetry(App* app, const(char)[] path, const(char)[] atext,
    const(char)[] origText, uint line, uint col, ref worker.WHover hov)
{
    for (int attempt = 0; attempt < 2; attempt++)
    {
        if (!app.wk.alive)
        {
            if (!workerSpawn(app.wk, app.importPaths, app.stringPaths, app.flags))
                return false;
        }
        auto r = workerHover(app.wk, path, atext, origText, line, col, hov);
        if (r == worker.ExchangeResult.ok)
            return true;
        if (r == worker.ExchangeResult.respawn || r == worker.ExchangeResult.failed)
        {
            // Respawn the worker.
            workerKill(app.wk);
            continue;
        }
        if (!app.wk.alive)
            continue;
        return false;
    }
    return false;
}

// Run a documentSymbol request against the worker, respawning once if needed.
private bool workerDocumentSymbolRetry(App* app, const(char)[] path,
    const(char)[] text, ref string resultJson)
{
    for (int attempt = 0; attempt < 2; attempt++)
    {
        if (!app.wk.alive)
        {
            if (!workerSpawn(app.wk, app.importPaths, app.stringPaths, app.flags))
                return false;
        }
        auto r = workerDocumentSymbol(app.wk, path, text, resultJson);
        if (r == worker.ExchangeResult.ok)
            return true;
        if (r == worker.ExchangeResult.respawn || r == worker.ExchangeResult.failed)
        {
            workerKill(app.wk);
            continue;
        }
        if (!app.wk.alive)
            continue;
        return false;
    }
    return false;
}

// Run a semantic-tokens request against the worker, respawning once if needed.
private bool workerSemanticRetry(App* app, const(char)[] path, const(char)[] text,
    ref worker.WToken[] toks){
    for (int attempt = 0; attempt < 2; attempt++)
    {
        if (!app.wk.alive)
        {
            if (!workerSpawn(app.wk, app.importPaths, app.stringPaths, app.flags))
                return false;
        }
        auto r = workerSemantic(app.wk, path, text, toks);
        if (r == worker.ExchangeResult.ok)
            return true;
        if (r == worker.ExchangeResult.respawn || r == worker.ExchangeResult.failed)
        {
            workerKill(app.wk);
            continue;
        }
        if (!app.wk.alive)
            continue;
        return false;
    }
    return false;
}

// Semantic tokens for `text`, cached by text hash. Called after every build
// (so the client's post-refresh pull is an instant hit) and by the token
// request itself. Returns null only when the text is empty.
private worker.WToken[] refreshTokens(App* app, const(char)[] path,
    const(char)[] text)
{
    if (!text.length)
        return null;
    ulong h = fnv1a64(cast(const(ubyte)[])text);
    if (auto hp = path.idup in app.tokHash)
        if (*hp == h)
            return app.tokCache[path.idup];
    worker.WToken[] toks;
    if (workerSemanticRetry(app, path, text, toks))
    {
        app.tokCache[path.idup] = toks;
        app.tokHash[path.idup] = h;
    }
    return toks;
}

// Ask the client to re-pull semantic tokens once a build has landed
// (LSP workspace/semanticTokens/refresh). Gated on the client capability;
// the client's response (id, no method) is ignored in handleMessage.
private void sendSemanticRefresh(App* app)
{
    if (!app.semanticRefresh)
        return;
    app.nextReqId++;
    lspWrite(`{"jsonrpc":"2.0","id":` ~ ulongStr(app.nextReqId) ~
        `,"method":"workspace/semanticTokens/refresh","params":null}`);
}

// Ask the client to watch the project config file (LSP
// workspace/didChangeWatchedFiles, dynamically registered). The watching is
// done by the client, so this is portable and needs no native file watcher.
// The glob is recursive (`**`) because some clients only report nested
// patterns reliably; the handler filters to the workspace-root `dls.json`
// (the server is single-root, initRoot takes the first folder) and ignores
// nested configs. The client's response (id, no method) is ignored in
// handleMessage.
private void sendWatchRegistration(App* app)
{
    if (!app.watchFiles || !app.root.length)
        return;
    app.nextReqId++;
    lspWrite(`{"jsonrpc":"2.0","id":` ~ ulongStr(app.nextReqId) ~
        `,"method":"client/registerCapability","params":{"registrations":[{` ~
        `"id":"dmd-lsp-watch-dls-json",` ~
        `"method":"workspace/didChangeWatchedFiles",` ~
        `"registerOptions":{"watchers":[{"globPattern":"**/dls.json"}]}}]}}`);
}

// LSP SemanticTokens result (delta-encoded data) for a token list.
private string tokensResultJson(worker.WToken[] toks)
{
    auto js = jmake();
    auto res = js.create_object();
    if (toks.length)
    {
        int[] data;
        data.reserve(toks.length * 5);
        uint prevLine = 0;
        uint prevCol = 0;
        foreach (ref t; toks)
        {
            uint dl = t.line - prevLine;
            uint dc = dl == 0 ? t.col - prevCol : t.col;
            data ~= cast(int)dl;
            data ~= cast(int)dc;
            data ~= cast(int)t.len;
            data ~= cast(int)t.type;
            data ~= cast(int)t.mods;
            prevLine = t.line;
            prevCol = t.col;
        }
        js.add_item_to_object(res, "data",
            js.create_int_array(data.ptr, cast(int)data.length));
    }
    else
        js.add_item_to_object(res, "data", js.create_array());
    return printJsonStr(res);
}

// Analyze + publish diagnostics + precompute tokens for one document.
// `realOnly` is true for open/save (diagnostics must be exact) and false for
// the debounced keypress analyze (reuse a live universe when possible).
private void publishFor(App* app, const(char)[] path, const(char)[] text,
    bool realOnly = false)
{
    worker.WAnalysis a;
    if (!workerAnalyzeRetry(app, path, text, a, realOnly))
        return;
    clearPending(app, path);
    // Trivia-only save: the program is unchanged, so keep the previously
    // published diagnostics instead of re-analysing. The worker invalidated
    // its universe (positions moved); drop position-keyed caches so the next
    // semantic pull rebuilds.
    if (a.unchanged)
    {
        app.cache.remove(path.idup);
        app.tokCache.remove(path.idup);
        app.tokHash.remove(path.idup);
        return;
    }
    app.cache[path.idup] = HitCache(a);
    auto js = jmake();
    auto diags = buildDiagnostics(js, a);
    auto params = js.create_object();
    js.add_string_to_object(params, "uri", zstr("file://" ~ path.idup));
    js.add_item_to_object(params, "diagnostics", diags);
    lspNotify(`"textDocument/publishDiagnostics"`, printJsonStr(params));
    // Precompute tokens from the fresh build *before* the refresh, so the
    // client's re-pull is an instant cache hit (no scan/resolve gap).
    if (app.wantSemantic)
    {
        refreshTokens(app, path, text);
        sendSemanticRefresh(app);
    }
}

// Analyze every document with unanalyzed changes (idle debounce). Reuses a
// live universe when possible; always unmarks each path, even on failure, so
// a failed build can't make the idle loop retry it in a hot loop.
private void flushPending(App* app)
{
    auto paths = app.pending.dup;
    foreach (p; paths)
    {
        if (!hasPending(app, p))
            continue;
        const(char)[] text;
        auto d = sessionFind(app.session, p);
        if (d)
            text = d.text;
        else
            text = sessionReadDisk(p);
        if (text)
            publishFor(app, p, text, false);
        clearPending(app, p);
    }
}

// Apply editor config: {"importPaths": [...]} either bare or nested under
// "dmd-lsp" / "d" / "D" keys. Future universes pick the paths up via reset.
private string[] jstrArray(JsonNode* n)
{
    string[] r;
    if (n && (n.type & 0xFF) == JsonArray)
        for (auto v = n.child; v; v = v.next)
        {
            auto s = jstr(v);
            if (s.length)
                r ~= s.idup;
        }
    return r;
}

private void applyConfig(App* app, JsonNode* node)
{
    if (!node || (node.type & 0xFF) != JsonObject)
        return;
    JsonNode* obj = node;
    foreach (key; ["dmd-lsp", "d", "D"])
    {
        if (auto sub = jget(obj, key.ptr))
        {
            if ((sub.type & 0xFF) == JsonObject)
            {
                obj = sub;
                break;
            }
        }
    }
    if (auto ip = jget(obj, "importPaths"))
    {
        if ((ip.type & 0xFF) == JsonArray)
        {
            string[] paths;
            for (auto v = ip.child; v; v = v.next)
            {
                auto s = jstr(v);
                if (s.length)
                    paths ~= s.idup;
            }
            if (paths.length)
            {
                app.baseImports = paths;
                refreshImports(app);
            }
        }
    }
    if (auto sp = jget(obj, "stringImportPaths"))
    {
        if ((sp.type & 0xFF) == JsonArray)
        {
            string[] paths;
            for (auto v = sp.child; v; v = v.next)
            {
                auto s = jstr(v);
                if (s.length)
                    paths ~= s.idup;
            }
            if (paths.length)
            {
                app.baseStringImports = paths;
                refreshImports(app);
            }
        }
    }
    if (auto fl = jget(obj, "flags"))
    {
        auto flags = jstrArray(fl);
        if (flags.length)
        {
            app.baseFlags = flags;
            refreshImports(app);
        }
    }
}

// Workspace root from initialize params: first workspace folder, else
// rootUri, else legacy rootPath. Null when the client gives none.
private string initRoot(JsonNode* p)
{
    if (!p || (p.type & 0xFF) != JsonObject)
        return null;
    if (auto wf = jget(p, "workspaceFolders"))
    {
        if ((wf.type & 0xFF) == JsonArray && wf.child)
        {
            auto s = jstr(jget(wf.child, "uri"));
            if (s.length)
                return uriToPath(s);
        }
    }
    if (auto ru = jget(p, "rootUri"))
    {
        auto s = jstr(ru);
        if (s.length)
            return uriToPath(s);
    }
    if (auto rp = jget(p, "rootPath"))
    {
        auto s = jstr(rp);
        if (s.length)
            return s.idup;
    }
    return null;
}

struct Notice
{
    bool have = false;
    int type = 4; // 1 Error, 4 Log
    string text;
}

// ulong -> decimal without phobos (config log lines).
private string ulongStr(ulong v)
{
    if (v == 0)
        return "0";
    char[24] buf = void;
    size_t i = buf.length;
    while (v > 0)
    {
        buf[--i] = cast(char)('0' + v % 10);
        v /= 10;
    }
    return buf[i .. $].idup;
}

private void notifyNotice(Notice n)
{
    if (!n.have)
        return;
    auto js = jmake();
    auto params = js.create_object();
    js.add_number_to_object(params, "type", cast(double)n.type);
    js.add_string_to_object(params, "message", zstr(n.text));
    lspNotify(`"window/showMessage"`, printJsonStr(params));
}

// Load <root>/dls.json into app.fileCfg (flat schema: "importPaths",
// "stringImportPaths", "flags"). Silent when absent; Log on success, Error
// when present but broken.
private Notice loadFileConfig(App* app, const(char)[] root)
{
    Notice n;
    if (!root.length)
        return n;
    string r = root.idup;
    while (r.length && r[$ - 1] == '/')
        r = r[0 .. $ - 1];
    string cfg = r ~ "/dls.json";
    if (!fileExists(cfg))
        return n; // no project file: stay quiet
    string text = sessionReadDisk(cfg);
    auto doc = text ? jparse(text) : null;
    if (!doc || (doc.type & 0xFF) != JsonObject)
    {
        n.have = true;
        n.type = 1;
        n.text = "dls.json: invalid JSON, ignored";
        return n;
    }
    FileConfig fc;
    fc.loaded = true;
    fc.root = r;
    fc.configPath = cfg;
    if (auto ip = jget(doc, "importPaths"))
    {
        if ((ip.type & 0xFF) == JsonArray)
        {
            for (auto v = ip.child; v; v = v.next)
            {
                auto s = jstr(v);
                if (auto rp = resolveCfgPath(r, s))
                    fc.imports ~= rp;
            }
        }
    }
    if (auto sp = jget(doc, "stringImportPaths"))
    {
        if ((sp.type & 0xFF) == JsonArray)
        {
            for (auto v = sp.child; v; v = v.next)
            {
                auto s = jstr(v);
                if (auto rp = resolveCfgPath(r, s))
                    fc.stringImports ~= rp;
            }
        }
    }
    if (auto dn = jget(doc, "debounceMs"))
    {
        if ((dn.type & 0xFF) == JsonNumber)
        {
            long v = jint(dn);
            fc.hasDebounce = true;
            fc.debounceMs = v < 0 ? 0 : cast(ulong)v;
        }
    }
    // Raw dmd flags (e.g. -preview=rvaluerefparam, -betterC, -version=Foo).
    fc.flags = jstrArray(jget(doc, "flags"));
    app.fileCfg = fc;
    if (!app.debounceSet && fc.hasDebounce)
        app.debounceMs = fc.debounceMs;
    refreshImports(app);
    n.have = true;
    n.type = 4;
    n.text = "dls.json: " ~ ulongStr(fc.imports.length) ~ " import paths from " ~ r;
    return n;
}

// The project config vanished from disk (watched-file delete): drop it and
// invalidate the worker so analysis falls back to the defaults layer.
private void clearFileConfig(App* app)
{
    if (!app.fileCfg.loaded)
        return;
    app.fileCfg = FileConfig.init;
    refreshImports(app);
    Notice n;
    n.have = true;
    n.type = 4;
    n.text = "dls.json: removed, using defaults";
    notifyNotice(n);
}

// After a dot, replace the partial member ending at the cursor (empty for a
// bare `s.`) with a placeholder call (for completion analysis only). The
// call resolves via an appended unconstrained UFCS template, so the
// statement survives semantic cleanly — dmd collapses a whole function body
// to a lone ErrorStatement on ANY statement error, wiping every local's
// inferred type (notably `auto`) and leaving dotted completion on locals
// with nothing to resolve.
//
// Replacing the whole partial segment (not just inserting at the cursor)
// also makes the analysis text *identical* for `s.a`, `s.ab`, `s.abc`, so
// completion reuses one universe while the user grows the name instead of
// rebuilding per keystroke (see serverWouldHitAnalysis).
private string dotPlaceholder(const(char)[] text, uint line, uint col)
{
    size_t off = 0;
    uint l = 1;
    while (off < text.length && l < line)
    {
        if (text[off] == '\n')
            l++;
        off++;
    }
    // walk col-1 chars on the line
    for (uint c = 1; c < col && off < text.length && text[off] != '\n'; c++)
        off++;
    if (off == 0 || off > text.length)
        return null;
    // Identifier segment ending at the cursor (empty when right after the dot).
    size_t segStart = off;
    while (segStart > 0 && isIdentChar(text[segStart - 1]))
        segStart--;
    if (segStart == 0 || text[segStart - 1] != '.')
        return null;
    // Cursor mid-identifier: not a segment end, leave it to other passes.
    if (off < text.length && isIdentChar(text[off]))
        return null;
    // Appended at end: existing lines/positions are untouched. The call
    // resolves through UFCS for value dots (any type via IFTI); static
    // dots keep today's behavior (no UFCS on types). Close any expression
    // delimiters still open before the insertion (e.g. a call argument
    // list, `f(w, c.`) so the placeholder statement itself parses.
    auto closers = closerFor(text, segStart);
    if (closers.length)
    {
        // Inside an argument/element list the inserted expression would
        // have to type-check against an unknown parameter type; blank the
        // whole expression statement instead (the LHS type still resolves
        // from earlier declarations).
        if (auto sp = statementPlaceholder(text, line, col))
            return sp;
    }
    return (text[0 .. segStart] ~ "__dmd_lsp_ph()" ~ closers ~ ";" ~
        text[off .. $] ~ "\nvoid __dmd_lsp_ph(T)(T _t) {}\n").idup;
}

private size_t lineColToOffset(const(char)[] text, uint line, uint col)
{
    size_t i = 0;
    uint l = 1;
    while (i < text.length && l < line)
    {
        if (text[i] == '\n')
            l++;
        i++;
    }
    for (uint c = 1; c < col && i < text.length && text[i] != '\n'; c++)
        i++;
    return i;
}

// Replace the statement containing the cursor (through the end of its
// line) with an empty `;`, so an incomplete call argument list can't
// collapse the enclosing function body during semantic.
private string statementPlaceholder(const(char)[] text, uint line, uint col)
{
    size_t cursor = lineColToOffset(text, line, col);
    if (cursor > text.length)
        cursor = text.length;
    size_t start = 0;
    int depth = 0;
    size_t i = 0;
    while (i < cursor)
    {
        char c = text[i];
        if (c == '/' && i + 1 < cursor && text[i + 1] == '/')
        {
            while (i < cursor && text[i] != '\n')
                i++;
            continue;
        }
        if (c == '/' && i + 1 < cursor && text[i + 1] == '*')
        {
            i += 2;
            while (i + 1 < cursor && !(text[i] == '*' && text[i + 1] == '/'))
                i++;
            i += 2;
            continue;
        }
        if (c == '"' || c == '\'' || c == '`')
        {
            char q = c;
            i++;
            while (i < cursor && text[i] != q)
            {
                if (text[i] == '\\' && q != '`')
                    i++;
                i++;
            }
            i++;
            continue;
        }
        if (c == '(' || c == '[')
            depth++;
        else if (c == ')' || c == ']')
        {
            if (depth > 0)
                depth--;
        }
        else if (depth == 0 && (c == ';' || c == '{' || c == '}'))
            start = i + 1;
        i++;
    }
    size_t end = cursor;
    while (end < text.length && text[end] != '\n')
        end++;
    if (start >= end)
        return null;
    bool content = false;
    foreach (ch; text[start .. end])
        if (ch != ' ' && ch != '\t' && ch != '\r')
        {
            content = true;
            break;
        }
    if (!content)
        return null;
    return (text[0 .. start] ~ ";" ~ text[end .. $]).idup;
}

// Pick the analysis text for a completion/signature request: make the
// buffer valid enough that semantic does not collapse the enclosing body
// (which would drop resolved `auto` types). Originates from `text`.
private string analysisText(string text, uint line, uint col)
{
    if (auto v = dotPlaceholder(text, line, col))
        return v;
    if (auto v2 = tokenPlaceholder(text, line, col))
        return v2;
    // A partial identifier after other code (`auto x = st`), or a plain
    // prefix inside an unclosed call/array: blank the whole statement. That
    // removes the growing token, so the analysis text is identical for every
    // prefix length and completion reuses one universe for the whole word
    // (otherwise each keystroke rebuilds). The scope the completion needs is
    // declared in earlier statements and survives.
    size_t off = lineColToOffset(text, line, col);
    bool partialIdent = off > 0 && isIdentChar(text[off - 1]) &&
        (off >= text.length || !isIdentChar(text[off]));
    // Import/module declarations drive completion from their own AST node
    // (module paths, selective symbol lists), so never blank them.
    if ((partialIdent && !lineHasImportModule(text, off)) ||
        closerFor(text, off).length)
        if (auto v3 = statementPlaceholder(text, line, col))
            return v3;
    return text;
}

// Closing brackets for unclosed `(`/`[` before offset `off`, innermost
// first (strings/comments skipped). `{` is a block, left alone.
private string closerFor(const(char)[] text, size_t off)
{
    char[64] stack;
    size_t sp = 0;
    size_t i = 0;
    while (i < off)
    {
        char c = text[i];
        if (c == '/' && i + 1 < off && text[i + 1] == '/')
        {
            while (i < off && text[i] != '\n')
                i++;
            continue;
        }
        if (c == '/' && i + 1 < off && text[i + 1] == '*')
        {
            i += 2;
            while (i + 1 < off && !(text[i] == '*' && text[i + 1] == '/'))
                i++;
            i += 2;
            continue;
        }
        if (c == '"' || c == '\'' || c == '`')
        {
            char q = c;
            i++;
            while (i < off && text[i] != q)
            {
                if (text[i] == '\\' && q != '`')
                    i++;
                i++;
            }
            i++;
            continue;
        }
        if (c == '(' || c == '[')
        {
            if (sp < stack.length)
                stack[sp++] = c;
        }
        else if (c == ')')
        {
            if (sp && stack[sp - 1] == '(')
                sp--;
        }
        else if (c == ']')
        {
            if (sp && stack[sp - 1] == '[')
                sp--;
        }
        i++;
    }
    char[] closers;
    while (sp > 0)
    {
        sp--;
        closers ~= (stack[sp] == '(' ? ')' : ']');
    }
    return closers.idup;
}

// True when `import` or `module` appears as a word on the cursor's line
// before `off`.
private bool lineHasImportModule(const(char)[] text, size_t off) pure nothrow @nogc @safe
{
    size_t ls = off;
    while (ls > 0 && text[ls - 1] != '\n')
        ls--;
    auto line = text[ls .. off];
    static immutable string[] kw = ["import", "module"];
    foreach (k; kw)
        foreach (i; 0 .. line.length)
        {
            if (i + k.length > line.length || line[i .. i + k.length] != k)
                continue;
            if ((i == 0 || !isIdentChar(line[i - 1])) &&
                (i + k.length == line.length || !isIdentChar(line[i + k.length])))
                return true;
        }
    return false;
}

private bool isIdentChar(char c) pure nothrow @nogc @safe
{
    return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9');
}

// A partial identifier alone on a line (`    st`) is a semantic/parse error
// that makes dmd replace the whole function body with ErrorStatement, so
// resolved `auto` local types are lost and completion degrades to "local".
// Removing the standalone token keeps the line valid (an empty statement)
// so the body survives semantic; the prefix and positions still come from
// the original text. Returns null when the token isn't standalone.
private string tokenPlaceholder(const(char)[] text, uint line, uint col)
{
    size_t i = 0;
    uint l = 1;
    while (i < text.length && l < line)
    {
        if (text[i] == '\n')
            l++;
        i++;
    }
    size_t ls = i;
    while (i < text.length && text[i] != '\n')
        i++;
    auto lt = text[ls .. i];
    size_t e = col - 1;
    if (e > lt.length)
        e = lt.length;
    size_t s2 = e;
    while (s2 > 0 && isIdentChar(lt[s2 - 1]))
        s2--;
    size_t e2 = e;
    while (e2 < lt.length && isIdentChar(lt[e2]))
        e2++;
    if (e2 == s2)
        return null; // no identifier at the cursor
    foreach (c; lt[0 .. s2])
        if (c != ' ' && c != '\t')
            return null; // something precedes the token on this line
    bool semi = false;
    foreach (c; lt[e2 .. $])
    {
        if (c == ' ' || c == '\t')
            continue;
        if (c == ';' && !semi)
        {
            semi = true;
            continue;
        }
        return null; // trailing code: not a standalone token
    }
    return (text[0 .. ls + s2] ~ text[ls + e2 .. $]).idup;
}

// Absolute path for a possibly-relative dmd filename (imports found via a
// relative -I are reported relative to the daemon's cwd). Cross-platform.
private string absolutePath(const(char)[] p)
{
    if (p.length && p[0] == '/')
        return p.idup; // POSIX absolute
    if (p.length >= 3 && p[1] == ':' && (p[2] == '/' || p[2] == '\\') &&
        ((p[0] >= 'A' && p[0] <= 'Z') || (p[0] >= 'a' && p[0] <= 'z')))
        return p.idup; // Windows drive-absolute
    version (Posix)
    {
        import core.sys.posix.unistd : getcwd;
        import core.stdc.string : strlen;
        char[4096] buf;
        if (getcwd(buf.ptr, buf.length) is null)
            return p.idup;
        auto cwd = buf[0 .. strlen(buf.ptr)];
        return cast(string)((cwd ~ "/" ~ p).idup);
    }
    else
    {
        // No portable cwd without an OS call; dmd usually reports absolute.
        return p.idup;
    }
}

// file:// URI with minimal percent-encoding (round-trips with uriToPath).
private string pathToUri(const(char)[] path)
{
    static immutable char[] hex = "0123456789ABCDEF";
    auto abs = absolutePath(path);
    // Normalise Windows separators.
    char[] norm;
    norm.reserve(abs.length);
    foreach (c; abs)
        norm ~= (c == '\\' ? '/' : c);
    auto p = norm;
    char[] out_;
    out_ ~= "file://";
    if (p.length >= 2 && p[1] == ':')
        out_ ~= "/"; // file:///C:/...
    foreach (c; p)
    {
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
            (c >= '0' && c <= '9') || c == '/' || c == '-' || c == '_' ||
            c == '.' || c == '~' || c == ':')
            out_ ~= c;
        else
        {
            out_ ~= '%';
            out_ ~= hex[(cast(ubyte)c) >> 4];
            out_ ~= hex[cast(ubyte)c & 0xF];
        }
    }
    return out_.idup;
}

private void handleMessage(App* app, ref RawMsg m)
{
    if (!m.ok)
        return;
    if (!m.hasId)
    {
        // notifications
        if (m.method == "initialized")
        {
            // The handshake is complete; now dynamic registration is allowed.
            sendWatchRegistration(app);
            return;
        }
        if (m.method == "$/cancelRequest")
            return;
        if (m.method == "exit")
        {
            import core.stdc.stdlib : exit;
            exit(app.shutdownRequested ? 0 : 1);
        }
    try
    {
        auto p = jparse(m.paramsJson);
            if (m.method == "textDocument/didOpen")
            {
                auto td = jget(p, "textDocument");
                const(char)[] uri = jstr(jget(td, "uri"));
                if (uri is null)
                    return;
                string path = uriToPath(uri);
                auto tn = jget(td, "text");
                if (!tn)
                    return;
                const(char)[] text = jstr(tn);
                if (text is null)
                    text = "";
                sessionOpen(app.session, path, text);
                if (!isDlsJson(path))
                    publishFor(app, path, text, true);
            }
            else if (m.method == "textDocument/didChange")
            {
                auto tdn = jget(p, "textDocument");
                const(char)[] uri = jstr(jget(tdn, "uri"));
                if (uri is null)
                    return;
                string path = uriToPath(uri);
                if (isDlsJson(path))
                    return; // config, not D (reloaded on didSave)
                auto changes = jget(p, "contentChanges");
                if (!changes || (changes.type & 0xFF) != JsonArray)
                    return;
                // Some clients send incremental changes (with a `range`)
                // even though we advertise full sync. Composing them onto
                // the current text is mandatory: treating a range's `text`
                // as the whole document replaces the buffer with a fragment
                // (dmd then errors at the top of the "file", e.g. bogus
                // "must start with BOM or ASCII character, not \xNN").
                string base;
                if (auto d = sessionFind(app.session, path))
                    base = d.text.idup;
                for (auto c = changes.child; c; c = c.next)
                {
                    auto tn = jget(c, "text");
                    if (!tn)
                        continue;
                    const(char)[] insert = jstr(tn);
                    if (insert is null)
                        insert = "";
                    auto range = jget(c, "range");
                    bool hasRange = range !is null;
                    uint sl = 0, sc = 0, el = 0, ec = 0;
                    if (hasRange)
                    {
                        auto st = jget(range, "start");
                        auto en = jget(range, "end");
                        sl = cast(uint)jint(jget(st, "line"));
                        sc = cast(uint)jint(jget(st, "character"));
                        el = cast(uint)jint(jget(en, "line"));
                        ec = cast(uint)jint(jget(en, "character"));
                    }
                    base = applyChange(base, insert, hasRange, sl, sc, el, ec);
                }
                // A keystroke is a delta patch to the in-memory buffer. The
                // analysis runs after the debounce idle (cheap reuse when a
                // completion already built the current buffer), so the doc is
                // analyzed without saving, without a rebuild per key.
                sessionUpdate(app.session, path, base);
                markPending(app, path);
            }
            else if (m.method == "textDocument/didClose")
            {
                const(char)[] uri = jstr(jget(jget(p, "textDocument"), "uri"));
                if (uri is null)
                    return;
                string path = uriToPath(uri);
                sessionClose(app.session, path);
                clearPending(app, path);
                app.tokCache.remove(path.idup);
                app.tokHash.remove(path.idup);
            }
            else if (m.method == "textDocument/didSave")
            {
                const(char)[] uri = jstr(jget(jget(p, "textDocument"), "uri"));
                if (uri is null)
                    return;
                string path = uriToPath(uri);
                if (isDlsJson(path))
                {
                    // Saving dls.json reloads project config from disk
                    // (covers creating it after initialize too).
                    if (auto root = dirOf(path))
                        notifyNotice(loadFileConfig(app, root));
                    return;
                }
                // Prefer the text the client sends. Otherwise the session
                // already holds the current buffer: never pass that same
                // buffer back through sessionUpdate (it would be freed)
                // and then analyze it — that hands dmd freed garbage.
                if (auto t = jget(p, "text"))
                {
                    const(char)[] text = jstr(t);
                    if (text)
                    {
                        sessionUpdate(app.session, path, text);
                        publishFor(app, path, text, true);
                    }
                }
                else if (auto d = sessionFind(app.session, path))
                {
                    if (d.text)
                        publishFor(app, path, d.text, true);
                }
                else if (auto disk = sessionReadDisk(path))
                {
                    sessionUpdate(app.session, path, disk);
                    publishFor(app, path, disk, true);
                }
            }
            else if (m.method == "workspace/didChangeWatchedFiles")
            {
                // Client-side watcher for the root dls.json (see
                // sendWatchRegistration). Reload on change/create, drop on
                // delete. Nested configs are ignored: the server is single-root.
                if (app.root.length)
                {
                    auto changes = jget(p, "changes");
                    if (changes && (changes.type & 0xFF) == JsonArray)
                    {
                        for (auto c = changes.child; c; c = c.next)
                        {
                            const(char)[] uri = jstr(jget(c, "uri"));
                            if (uri is null)
                                continue;
                            string path = uriToPath(uri);
                            if (!isDlsJson(path) || !sameDir(dirOf(path), app.root))
                                continue;
                            if (fileExists(path))
                                notifyNotice(loadFileConfig(app, app.root));
                            else
                                clearFileConfig(app);
                        }
                    }
                }
            }
        }
        catch (Exception)
        {
        }
        return;
    }
    // A message with an id but no method is the client answering one of our
    // server->client requests (e.g. workspace/semanticTokens/refresh).
    if (m.method.length == 0)
        return;
    // requests
    if (m.method == "initialize")
    {
        auto p = jparse(m.paramsJson);
        if (auto io = jget(p, "initializationOptions"))
            applyConfig(app, io);
        // LSP 3.17 labelDetails: only clients that opt in get the split
        // "(params) / return type" form.
        if (auto capsIn = jget(p, "capabilities"))
        {
            if (auto tdc = jget(capsIn, "textDocument"))
            {
                if (auto compIn = jget(tdc, "completion"))
                    if (auto ciIn = jget(compIn, "completionItem"))
                        app.labelDetails = jbool(jget(ciIn, "labelDetailsSupport"), false);
                app.wantSemantic = jget(tdc, "semanticTokens") !is null;
            }
            // workspace/semanticTokens/refresh: lets us defer token pulls to
            // the debounced build instead of rebuilding on every keystroke.
            if (auto ws = jget(capsIn, "workspace"))
            {
                if (auto st = jget(ws, "semanticTokens"))
                    app.semanticRefresh = jbool(jget(st, "refreshSupport"), false);
                // File watching is client-side; we only register the glob.
                if (auto wf = jget(ws, "didChangeWatchedFiles"))
                    app.watchFiles = jbool(jget(wf, "dynamicRegistration"), false);
            }
        }
        Notice note;
        if (auto root = initRoot(p))
        {
            app.root = root.idup;
            note = loadFileConfig(app, root);
        }
        auto js = jmake();
        auto trig = js.create_array();
        js.add_item_to_array(trig, js.create_string("."));
        js.add_item_to_array(trig, js.create_string("("));
        auto cp = js.create_object();
        js.add_item_to_object(cp, "triggerCharacters", trig);
        auto cpItem = js.create_object();
        js.add_bool_to_object(cpItem, "labelDetailsSupport", true);
        js.add_item_to_object(cp, "completionItem", cpItem);
        auto caps = js.create_object();
        js.add_number_to_object(caps, "textDocumentSync", 1);
        js.add_item_to_object(caps, "completionProvider", cp);
        auto sht = js.create_array();
        js.add_item_to_array(sht, js.create_string("("));
        js.add_item_to_array(sht, js.create_string(","));
        auto sh = js.create_object();
        js.add_item_to_object(sh, "triggerCharacters", sht);
        js.add_item_to_object(caps, "signatureHelpProvider", sh);
        js.add_bool_to_object(caps, "definitionProvider", true);
        js.add_bool_to_object(caps, "hoverProvider", true);
        js.add_bool_to_object(caps, "documentSymbolProvider", true);
        js.add_bool_to_object(caps, "codeActionProvider", true);
        auto legend = js.create_object();
        auto tt = js.create_array();
        foreach (t; tokenTypes)
            js.add_item_to_array(tt, js.create_string(zstr(t)));
        js.add_item_to_object(legend, "tokenTypes", tt);
        auto tm = js.create_array();
        foreach (t; tokenModifiers)
            js.add_item_to_array(tm, js.create_string(zstr(t)));
        js.add_item_to_object(legend, "tokenModifiers", tm);
        auto stp = js.create_object();
        js.add_item_to_object(stp, "legend", legend);
        js.add_bool_to_object(stp, "full", true);
        js.add_item_to_object(caps, "semanticTokensProvider", stp);
        auto si = js.create_object();
        js.add_string_to_object(si, "name", "dmd-lsp");
        js.add_string_to_object(si, "version", dmdLspVersion);
        auto res = js.create_object();
        js.add_item_to_object(res, "capabilities", caps);
        js.add_item_to_object(res, "serverInfo", si);
        lspRespond(m.idJson, printJsonStr(res));
        notifyNotice(note); // after respond: strict clients may drop pre-init notices
        return;
    }
    if (m.method == "shutdown")
    {
        app.shutdownRequested = true;
        lspRespond(m.idJson, "null");
        return;
    }
    try
    {
        auto p = jparse(m.paramsJson);
        if (m.method == "workspace/didChangeConfiguration")
        {
            if (auto s = jget(p, "settings"))
                applyConfig(app, s);
            if (m.hasId)
                lspRespond(m.idJson, "null");
            return;
        }
        if (m.method == "textDocument/completion")
        {
            const(char)[] uri = jstr(jget(jget(p, "textDocument"), "uri"));
            if (uri is null)
            {
                lspRespond(m.idJson, `{"isIncomplete":false,"items":[]}`);
                return;
            }
            string path = uriToPath(uri);
            auto pos = jget(p, "position");
            uint line = cast(uint)jint(jget(pos, "line")) + 1;
            uint col = cast(uint)jint(jget(pos, "character")) + 1;
            string text;
            auto d = sessionFind(app.session, path);
            if (d)
                text = d.text.idup;
            else
                text = sessionReadDisk(path);
            auto js = jmake();
            auto items = js.create_array();
            if (text)
            {
                // A dangling dot, a lone partial identifier, or an
                // unfinished call argument rarely parses; use a placeholder
                // so semantic survives. Chain/positions come from `text`.
                string atext = analysisText(text, line, col);
                auto prefix = extractPrefix(text, line, col);
                worker.WItem[] witems;
                if (workerCompleteRetry(app, path, atext, text, line, col, prefix, witems))
                {
                    foreach (ref it; witems)
                    {
                        auto j = js.create_object();
                        js.add_string_to_object(j, "label", zstr(it.label));
                        js.add_number_to_object(j, "kind", it.kind);
                        bool hasLabelDetails =
                            it.labelDetail.length > 0 || it.labelDesc.length > 0;
                        if (hasLabelDetails && app.labelDetails)
                        {
                            // LSP 3.17: label + "(params)" + " " + return type.
                            auto ld = js.create_object();
                            if (it.labelDetail.length)
                                js.add_string_to_object(ld, "detail", zstr(it.labelDetail));
                            if (it.labelDesc.length)
                                js.add_string_to_object(ld, "description", zstr(it.labelDesc));
                            js.add_item_to_object(j, "labelDetails", ld);
                        }
                        else
                            jaddStrOpt(js, j, "detail", it.detail);
                        jaddStrOpt(js, j, "documentation", it.documentation);
                        jaddStrOpt(js, j, "sortText", it.sortText);
                        js.add_item_to_array(items, j);
                    }
                }
            }
            auto res = js.create_object();
            js.add_bool_to_object(res, "isIncomplete", false);
            js.add_item_to_object(res, "items", items);
            lspRespond(m.idJson, printJsonStr(res));
            return;
        }
        if (m.method == "textDocument/signatureHelp")
        {
            const(char)[] uri = jstr(jget(jget(p, "textDocument"), "uri"));
            if (uri is null)
            {
                lspRespond(m.idJson, `{"signatures":[]}`);
                return;
            }
            string path = uriToPath(uri);
            auto pos = jget(p, "position");
            uint line = cast(uint)jint(jget(pos, "line")) + 1;
            uint col = cast(uint)jint(jget(pos, "character")) + 1;
            string text;
            auto d = sessionFind(app.session, path);
            if (d)
                text = d.text.idup;
            else
                text = sessionReadDisk(path);
            if (!text)
            {
                lspRespond(m.idJson, `{"signatures":[]}`);
                return;
            }
            string atext = analysisText(text, line, col);
            worker.WSig sig;
            auto js = jmake();
            if (workerSignatureRetry(app, path, atext, text, line, col, sig) && sig.found)
            {
                auto sigs = js.create_array();
                auto sg = js.create_object();
                js.add_string_to_object(sg, "label", zstr(sig.label));
                if (sig.doc.length)
                    js.add_string_to_object(sg, "documentation", zstr(sig.doc));
                auto pars = js.create_array();
                foreach (sp; sig.params)
                {
                    auto po = js.create_object();
                    js.add_string_to_object(po, "label", zstr(sp.label));
                    js.add_item_to_array(pars, po);
                }
                js.add_item_to_object(sg, "parameters", pars);
                js.add_item_to_array(sigs, sg);
                auto res = js.create_object();
                js.add_item_to_object(res, "signatures", sigs);
                js.add_number_to_object(res, "activeSignature", 0);
                js.add_number_to_object(res, "activeParameter", sig.activeParameter);
                lspRespond(m.idJson, printJsonStr(res));
            }
            else
                lspRespond(m.idJson, `{"signatures":[]}`);
            return;
        }
        if (m.method == "textDocument/definition")
        {
            const(char)[] uri = jstr(jget(jget(p, "textDocument"), "uri"));
            if (uri is null)
            {
                lspRespond(m.idJson, "null");
                return;
            }
            string path = uriToPath(uri);
            auto pos = jget(p, "position");
            uint line = cast(uint)jint(jget(pos, "line")) + 1;
            uint col = cast(uint)jint(jget(pos, "character")) + 1;
            string text;
            auto d = sessionFind(app.session, path);
            if (d)
                text = d.text.idup;
            else
                text = sessionReadDisk(path);
            if (!text)
            {
                lspRespond(m.idJson, "null");
                return;
            }
            string atext = analysisText(text, line, col);
            worker.WDef def;
            if (workerDefinitionRetry(app, path, atext, text, line, col, def) && def.found)
            {
                auto js = jmake();
                auto loc = js.create_object();
                js.add_string_to_object(loc, "uri", zstr(pathToUri(def.file)));
                uint sline = def.line > 0 ? def.line - 1 : 0;
                uint scol = def.col > 0 ? def.col - 1 : 0;
                auto range = js.create_object();
                auto st = js.create_object();
                js.add_number_to_object(st, "line", sline);
                js.add_number_to_object(st, "character", scol);
                auto en = js.create_object();
                js.add_number_to_object(en, "line", sline);
                js.add_number_to_object(en, "character", scol + def.len);
                js.add_item_to_object(range, "start", st);
                js.add_item_to_object(range, "end", en);
                js.add_item_to_object(loc, "range", range);
                auto arr = js.create_array();
                js.add_item_to_array(arr, loc);
                lspRespond(m.idJson, printJsonStr(arr));
            }
            else
                lspRespond(m.idJson, "null");
            return;
        }
        if (m.method == "textDocument/documentSymbol")
        {
            const(char)[] uri = jstr(jget(jget(p, "textDocument"), "uri"));
            if (uri is null)
            {
                lspRespond(m.idJson, "null");
                return;
            }
            string path = uriToPath(uri);
            string text;
            auto d = sessionFind(app.session, path);
            if (d)
                text = d.text.idup;
            else
                text = sessionReadDisk(path);
            if (!text)
            {
                lspRespond(m.idJson, "[]");
                return;
            }
            string resultJson = "[]";
            if (workerDocumentSymbolRetry(app, path, text, resultJson))
                lspRespond(m.idJson, resultJson);
            else
                lspRespond(m.idJson, "null");
            return;
        }
        if (m.method == "textDocument/hover")
        {            const(char)[] uri = jstr(jget(jget(p, "textDocument"), "uri"));
            if (uri is null)
            {
                lspRespond(m.idJson, "null");
                return;
            }
            string path = uriToPath(uri);
            auto pos = jget(p, "position");
            uint line = cast(uint)jint(jget(pos, "line")) + 1;
            uint col = cast(uint)jint(jget(pos, "character")) + 1;
            string text;
            auto d = sessionFind(app.session, path);
            if (d)
                text = d.text.idup;
            else
                text = sessionReadDisk(path);
            if (!text)
            {
                lspRespond(m.idJson, "null");
                return;
            }
            string atext = analysisText(text, line, col);
            worker.WHover hov;
            if (workerHoverRetry(app, path, atext, text, line, col, hov) && hov.found)
            {
                string value;
                if (hov.detail.length)
                    value ~= "```d\n" ~ hov.detail ~ "\n```";
                if (hov.doc.length)
                {
                    if (value.length)
                        value ~= "\n\n";
                    value ~= hov.doc;
                }
                auto js = jmake();
                auto md = js.create_object();
                js.add_string_to_object(md, "kind", "markdown");
                js.add_string_to_object(md, "value", zstr(value));
                auto res = js.create_object();
                js.add_item_to_object(res, "contents", md);
                lspRespond(m.idJson, printJsonStr(res));
            }
            else
                lspRespond(m.idJson, "null");
            return;
        }
        if (m.method == "textDocument/semanticTokens/full")
        {
            const(char)[] uri = jstr(jget(jget(p, "textDocument"), "uri"));
            if (uri is null)
            {
                lspRespond(m.idJson, `{"data":[]}`);
                return;
            }
            string path = uriToPath(uri);
            string text;
            auto d = sessionFind(app.session, path);
            if (d)
                text = d.text.idup;
            else
                text = sessionReadDisk(path);

            ulong h = text.length ? fnv1a64(cast(const(ubyte)[])text) : 0;
            // Already tokenized this exact text: answer from cache (repeated
            // pulls, and the refresh round-trip after a build).
            if (h && (path.idup in app.tokHash) && app.tokHash[path.idup] == h)
            {
                lspRespond(m.idJson, tokensResultJson(app.tokCache[path.idup]));
                return;
            }
            // Mid-edit (analysis still queued): keep the previous tokens
            // instead of forcing a build per keystroke. The debounce build
            // then refreshes them.
            if (hasPending(app, path) && app.debounceMs > 0)
            {
                worker.WToken[] cached;
                if (auto c = path.idup in app.tokCache)
                    cached = *c;
                lspRespond(m.idJson, tokensResultJson(cached));
                return;
            }
            lspRespond(m.idJson, tokensResultJson(refreshTokens(app, path, text)));
            return;
        }
        if (m.method == "textDocument/codeAction")
        {
            const(char)[] uri = jstr(jget(jget(p, "textDocument"), "uri"));
            string path = uri is null ? null : uriToPath(uri);
            auto js = jmake();
            auto actions = js.create_array();
            if (path !is null)
            {
                if (hasPending(app, path))
                {
                    // Actions carry edit ranges: refresh so they match the
                    // current text.
                    const(char)[] text;
                    auto d = sessionFind(app.session, path);
                    if (d)
                        text = d.text;
                    else
                        text = sessionReadDisk(path);
                    if (text)
                    {
                        worker.WAnalysis a;
                        if (workerAnalyzeRetry(app, path, text, a))
                            app.cache[path.idup] = HitCache(a);
                    }
                }
                if (auto hc = path.idup in app.cache)
                {
                    auto li = (*hc).analysis.lintImports;
                    JsonNode* mkEdit(uint sl, uint el)
                    {
                        auto e = js.create_object();
                        js.add_item_to_object(e, "range", jrange(js, sl - 1, 0, el, 0));
                        js.add_string_to_object(e, "newText", "");
                        return e;
                    }
                    // per-hit quickfixes
                    for (size_t i = 0; i < li.hits.length; i++)
                    {
                        auto h = li.hits[i];
                        auto edits = js.create_array();
                        js.add_item_to_array(edits, mkEdit(h.line, h.endLine));
                        auto changes = js.create_object();
                        js.add_item_to_object(changes, zstr(uri), edits);
                        auto a = js.create_object();
                        js.add_string_to_object(a, "title",
                            zstr("Remove unused import `" ~ h.name ~ "`"));
                        js.add_string_to_object(a, "kind", "quickfix");
                        auto w = js.create_object();
                        js.add_item_to_object(w, "changes", changes);
                        js.add_item_to_object(a, "edit", w);
                        js.add_item_to_array(actions, a);
                    }
                    if (li.hits.length > 1)
                    {
                        auto edits = js.create_array();
                        for (size_t i = 0; i < li.hits.length; i++)
                        {
                            auto h = li.hits[i];
                            js.add_item_to_array(edits, mkEdit(h.line, h.endLine));
                        }
                        auto changes = js.create_object();
                        js.add_item_to_object(changes, zstr(uri), edits);
                        auto a = js.create_object();
                        js.add_string_to_object(a, "title", "Remove all unused imports");
                        js.add_string_to_object(a, "kind", "quickfix");
                        auto w = js.create_object();
                        js.add_item_to_object(w, "changes", changes);
                        js.add_item_to_object(a, "edit", w);
                        js.add_item_to_array(actions, a);
                    }
                }
            }
            lspRespond(m.idJson, printJsonStr(actions));
            return;
        }
    }
    catch (Exception e)
    {
        lspRespondError(m.idJson, -32603, "internal error");
        return;
    }
    lspRespondError(m.idJson, -32601, "method not found: " ~ m.method);
}

private ulong parseHex(const(char)[] s, size_t from, size_t to)
{
    ulong v = 0;
    foreach (i; from .. to)
    {
        char c = s[i];
        v <<= 4;
        if (c >= '0' && c <= '9') v |= c - '0';
        else if (c >= 'a' && c <= 'f') v |= c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') v |= c - 'A' + 10;
    }
    return v;
}

private int runCheck(string[] files, string[] imports, string[] stringImports = null,
    string[] flags = null)
{
    // One-shot batch mode: single process.
    App app;
    app.baseImports = imports;
    app.baseStringImports = stringImports;
    app.baseFlags = flags;
    refreshImports(&app);
    ServerState srv;
    serverInit(srv, app.importPaths, app.stringPaths, app.flags);
    scope (exit)
        serverShutdown(srv);
    int code = 0;
    foreach (f; files)
    {
        string text = sessionReadDisk(f);
        if (!text)
        {
            fprintf(stderr, "%.*s: cannot read file\n", cast(int)f.length, f.ptr);
            code = 2;
            continue;
        }
        auto a = serverAnalyze(srv, f, text);
        if (getenv("DMD_LSP_TRACE_GCSTATS") !is null)
        {
            import core.memory : GC;
            GC.collect();
            auto st = GC.stats();
            auto before = st.usedSize;
            GC.minimize();
            auto after = GC.stats().usedSize;
            fprintf(stderr, "gcstats: used=%zuMB afterMinimize=%zuMB allocatedTotal=%zuMB\n",
                before / 1024 / 1024, after / 1024 / 1024, st.allocatedInCurrentThread / 1024 / 1024);
        }
        foreach (ref d; a.diags)
        {
            if (d.kind == 'S' || d.kind == 'M')
                continue;
            const(char)* k = d.kind == 'E' ? "Error" : d.kind == 'W' ? "Warning" : "Deprecation";
            const(char)[] df = d.file.length ? d.file : f;
            printf("%.*s(%u:%u): %s: %.*s\n", cast(int)df.length, df.ptr, d.line, d.col, k,
                cast(int)d.text.length, d.text.ptr);
            if (d.kind == 'E')
                code = 1;
        }
        for (size_t i = 0; i < a.lintImports.nhits; i++)
        {
            auto h = a.lintImports.hits[i];
            printf("%.*s(%u:%u): Hint: unused import `%.*s`\n", cast(int)f.length, f.ptr,
                h.line, h.col, cast(int)h.name.length, h.name.ptr);
        }
        for (size_t i = 0; i < a.lintParams.nhits; i++)
        {
            auto h = a.lintParams.hits[i];
            printf("%.*s(%u:%u): Hint: unused parameter `%.*s`\n", cast(int)f.length, f.ptr,
                h.line, h.col, cast(int)h.name.length, h.name.ptr);
        }
        if (a.lintImports.skipped)
            printf("%.*s: import lint skipped (%.*s)\n", cast(int)f.length, f.ptr,
                cast(int)a.lintImports.skipReason.length, a.lintImports.skipReason.ptr);
    }
    return code;
}

// Effective import lists: explicit (CLI, replaced by editor settings) ++
// project file ++ builtin defaults, order-preserving dedup. Bumps
// configGen only on actual change (universe invalidation is expensive).
private void refreshImports(App* app)
{
    string[] eff = app.baseImports.dup;
    foreach (p; app.fileCfg.imports)
    {
        bool have = false;
        foreach (q; eff)
            if (q == p)
            {
                have = true;
                break;
            }
        if (!have)
            eff ~= p;
    }
    foreach (d; defaultImports())
    {
        bool have = false;
        foreach (q; eff)
            if (q == d)
            {
                have = true;
                break;
            }
        if (!have)
            eff ~= d;
    }
    string[] seff = app.baseStringImports.dup;
    foreach (p; app.fileCfg.stringImports)
    {
        bool have = false;
        foreach (q; seff)
            if (q == p)
            {
                have = true;
                break;
            }
        if (!have)
            seff ~= p;
    }
    string[] feff = app.baseFlags.dup;
    foreach (f; app.fileCfg.flags)
    {
        bool have = false;
        foreach (q; feff)
            if (q == f)
            {
                have = true;
                break;
            }
        if (!have)
            feff ~= f;
    }
    if (eff != app.importPaths || seff != app.stringPaths || feff != app.flags)
    {
        app.importPaths = eff;
        app.stringPaths = seff;
        app.flags = feff;
        app.configGen++;
        // Host bakes paths in at init; drop it so the next request
        // respawns with the new configuration. Tokens may resolve
        // differently under the new paths, so drop the cache too.
        app.tokCache = null;
        app.tokHash = null;
        workerKill(app.wk);
    }
}

private string[] defaultImports()
{
    string[] found;
    static immutable string[] candidates = [
        // repo druntime first: matches the frontend under development
        "/home/ryuukk/dev/dmd/druntime/src",
        "/home/ryuukk/dlang/dmd-2.113.0/src/phobos",
        "/home/ryuukk/dlang/dmd-2.113.0/src/druntime/import",
    ];
    foreach (c; candidates)
    {
        if (fileExists(c))
            found ~= c.idup;
    }
    return found;
}

enum dmdLspVersion = "0.3.0";

int main(string[] args)
{
    // Worker mode: this process is a spawned analysis child.
    foreach (a; args[1 .. $])
        if (a == "--worker")
        {
            workerMain();
            return 0;
        }

    string[] imports;
    string[] stringImports;
    string[] flags;
    string[] files;
    bool check = false;
    bool stdio_ = false;
    ulong debounceMs = 500;
    bool debounceSet = false;
    foreach (a; args[1 .. $])
    {
        if (a == "--version")
        {
            printf("dmd-lsp %s\n", dmdLspVersion.ptr);
            return 0;
        }
        else if (a == "--check")
            check = true;
        else if (a == "--stdio")
            stdio_ = true;
        else if (a.length > 9 && a[0 .. 9] == "--import=")
            imports ~= a[9 .. $].idup;
        else if (a.length > 16 && a[0 .. 16] == "--string-import=")
            stringImports ~= a[16 .. $].idup;
        else if (a.length > 7 && a[0 .. 7] == "--flag=")
            flags ~= a[7 .. $].idup;
        else if (a.length > 14 && a[0 .. 14] == "--debounce-ms=")
        {
            ulong v = 0;
            foreach (c; a[14 .. $])
            {
                if (c < '0' || c > '9')
                {
                    v = 500;
                    break;
                }
                v = v * 10 + cast(ulong)(c - '0');
            }
            debounceMs = v;
            debounceSet = true;
        }
        else if (a == "--help" || a == "-h")
        {
            printf("usage: dmd-lsp [--stdio] [--check FILE...] [--import=DIR]... [--string-import=DIR]... [--flag=FLAG]... [--debounce-ms=N]\n");
            return 0;
        }
        else
            files ~= a;
    }
    if (check)
        return runCheck(files, imports, stringImports, flags);

    // stdio LSP loop. `didChange` is a delta patch to the in-memory buffer;
    // the analysis runs on the debounce idle (so the unsaved doc is analysed
    // without a save), reusing the live universe when the text is unchanged
    // since the last build. open/save force a real rebuild for exact
    // diagnostics. All dmd work happens in the worker (worker.d); the
    // parent holds no dmd state, so nothing accumulates across rebuilds.
    App app;
    app.debounceMs = debounceMs;
    app.debounceSet = debounceSet;
    app.baseImports = imports;
    app.baseStringImports = stringImports;
    app.baseFlags = flags;
    refreshImports(&app);
    version (Posix)
        signal(SIGPIPE, SIG_IGN); // client may close stdout
    scope (exit)
        workerKill(app.wk);
    app.lastMsgMs = nowMs();
    version (Posix)
    {
        import core.sys.posix.poll : poll, pollfd, POLLIN;
        import core.stdc.stdio : setvbuf, _IONBF, stdin;

        // Unbuffered stdin: poll() observes kernel pipe state, but stdio
        // fgetc/fread would otherwise hoard messages in a userspace buffer
        // (poll blocks on an "empty" pipe while input sits buffered).
        setvbuf(stdin, null, _IONBF, 0);

        RawMsg m;
        string body_;
        for (;;)
        {
            int timeout = -1;
            if (app.pending.length)
            {
                ulong idle = nowMs() - app.lastMsgMs;
                if (idle >= app.debounceMs)
                    timeout = 0;
                else
                {
                    ulong wait = app.debounceMs - idle;
                    timeout = wait > int.max ? int.max : cast(int)wait;
                }
            }
            pollfd pfd;
            pfd.fd = 0; // stdin
            pfd.events = POLLIN;
            int r = poll(&pfd, 1, timeout);
            if (r < 0)
                break;
            if (r == 0)
            {
                flushPending(&app);
                continue;
            }
            if (!lspRead(&m, body_))
                break;
            handleMessage(&app, m);
            // Restart the idle clock after handling so a slow build doesn't
            // make the debounce look elapsed the moment it returns.
            app.lastMsgMs = nowMs();
            GC.collect();
        }
    }
    else version (Windows)
    {
        import core.sys.windows.winbase : WaitForSingleObject, GetStdHandle,
            STD_INPUT_HANDLE, WAIT_OBJECT_0, INFINITE;
        import core.sys.windows.winerror : WAIT_TIMEOUT;
        import core.stdc.stdio : setvbuf, _IONBF, stdin, stdout, FILE;

        // Binary mode: the CRT would otherwise translate CRLF in the framing.
        enum _O_BINARY = 0x8000;
        _setmode(_fileno(cast(void*) stdin), _O_BINARY);
        _setmode(_fileno(cast(void*) stdout), _O_BINARY);
        setvbuf(stdin, null, _IONBF, 0);
        setvbuf(stdout, null, _IONBF, 0);

        auto hIn = GetStdHandle(STD_INPUT_HANDLE);
        RawMsg m;
        string body_;
        for (;;)
        {
            uint timeout = INFINITE;
            if (app.pending.length)
            {
                ulong idle = nowMs() - app.lastMsgMs;
                if (idle >= app.debounceMs)
                    timeout = 0;
                else
                {
                    ulong wait = app.debounceMs - idle;
                    timeout = wait > uint.max ? uint.max : cast(uint)wait;
                }
            }
            auto r = WaitForSingleObject(hIn, timeout);
            if (r == WAIT_TIMEOUT)
            {
                flushPending(&app);
                continue;
            }
            if (r != WAIT_OBJECT_0)
                break;
            if (!lspRead(&m, body_))
                break;
            handleMessage(&app, m);
            app.lastMsgMs = nowMs();
            GC.collect();
        }
    }
    else
    {
        RawMsg m;
        string body_;
        while (lspRead(&m, body_))
            handleMessage(&app, m);
    }
    return 0;
}

module worker;

// Cross-platform analysis worker.
//
// One child process builds a full dmd universe (dependency closure + root) and
// keeps it warm; a root-text edit is re-parsed in place on the warm closure
// (serverAnalyzeIncremental -> dmdReparseModule). A dependency/config/root
// change respawns the child, so the OS reclaims the discarded universe. The
// parent (LSP front end) holds only documents/config.
//
// Transport: two pipes with length-prefixed frames, so the same code runs on
// POSIX and Windows.
//   * POSIX:   fork(); the child dups the pipes onto stdin/stdout and runs
//              workerMain().
//   * Windows: CreateProcess of this executable with `--worker`; main.d calls
//              workerMain(), which speaks over the inherited std handles.
// Struct-only, no phobos.

import arena;
import log : log;
import json;
import lsp;
import session;
import server;
import complete;
import symbols : DocSymbol, documentSymbols, FoldRange, foldingRanges,
    InlayHint, inlayHints;
import references : DeclKey, RefLoc, findReferences, isLocalDsymbol,
    referencesForKey, declKey,
    mergeRefs, resolvedSymbolAt, occurrenceAt, textSpells, isRenameable,
    isAggregateMember, implementationLocs, collectClassDecls, CallSite,
    collectCalls, collectCallsIn, FuncInfo, funcInfo, keyMatches, moduleOf;

import lint;
import lexutil : LexCache, lexSet, lexOver;
import semantic : SemTok, semanticTokens;
import dmdwrap : dmdRootHasImporters, dmdTokenHash, dmdResetRequest, dmdParseOnly,
    dmdParseNoRegister, dmdLocCheckpoint, dmdLocRollback,
    dmdHasUnloadedImport, dmdIsPlainIdentifier, dmdHasHiddenRefRisk;

import dmd.dmodule : Module;
import dmd.dsymbol : Dsymbol;
import dmd.func : FuncDeclaration;
import dmd.dclass : ClassDeclaration;
import dmd.tokens : Token;

version (Posix)
{
    import core.sys.posix.unistd : read, write, close, fork, dup2, pipe, pid_t, _exit;
    import core.stdc.errno : errno, EINTR;
    import core.sys.posix.sys.wait : waitpid, WIFSIGNALED, WTERMSIG, WIFEXITED,
        WEXITSTATUS;
}

version (Windows)
{
    import core.sys.windows.winbase;
    import core.sys.windows.windef;
    import core.sys.windows.winnt;
}

// ---------- framing ----------

struct Chan
{
    version (Posix)
        int fd = -1;
    version (Windows)
    {
        void* h = null;
        // An inherited standard handle: resolve it via GetStdHandle on every
        // call instead of caching (see chanRead/chanWrite). Only the worker's
        // inChan/outChan set this; pipe handles keep a stable `h`.
        bool stdHandle = false;
    }
}

private __gshared Chan inChan;   // child: requests
private __gshared Chan outChan;  // child: responses

// Workspace symbol index (worker process). Parse-only declarations collected
// from the parent's file discovery. Built lazily, invalidated on watched
// changes; rebuilding is registration-free (H3) and keeps the universe.)
struct WIndexSym
{
    string name;
    ubyte kind;
    string file;
    uint line; // 0-based
    uint col;
    string container;
    string moduleName; // declaring module, for add-import
}
private WIndexSym[] g_index;
private bool g_indexBuilt = false;

// Per-file module name + direct imports (parse-only), for locating importer
// modules when searching references workspace-wide.
struct WFileInfo
{
    string file;
    string moduleName;
    string[] imports;
}
private WFileInfo[] g_files;

// Set when a child could not write a response. The worker loop checks it and
// exits, so a lost reply can't leave the parent blocked in readFrame forever.
// Single-threaded: only the worker's main loop writes, and it never resets the
// flag because the process exits (the parent always respawns, never reuses).
__gshared bool g_writeFailed = false;

private bool chanWrite(ref Chan c, const(ubyte)[] data) nothrow
{
    size_t off = 0;
    while (off < data.length)
    {
        version (Posix)
        {
            auto n = write(c.fd, data.ptr + off, data.length - off);
            if (n < 0 && errno == EINTR)
                continue; // interrupted before writing anything: retry
            if (n <= 0)
            {
                g_writeFailed = true;
                return false;
            }
            off += cast(size_t)n;
        }
        version (Windows)
        {
            // A std handle must be re-resolved here instead of caching: it is
            // not stable for the process lifetime.
            auto h = c.h;
            if (c.stdHandle)
                h = GetStdHandle(STD_OUTPUT_HANDLE);
            DWORD n = 0;
            if (!WriteFile(h, data.ptr + off, cast(DWORD)(data.length - off), &n, null) || n == 0)
            {
                g_writeFailed = true;
                return false;
            }
            off += n;
        }
    }
    return true;
}

private bool chanRead(ref Chan c, ubyte[] data) nothrow
{
    size_t off = 0;
    while (off < data.length)
    {
        version (Posix)
        {
            auto n = read(c.fd, data.ptr + off, data.length - off);
            if (n < 0 && errno == EINTR)
                continue; // interrupted before reading anything: retry
            if (n <= 0)
                return false;
            off += cast(size_t)n;
        }
        version (Windows)
        {
            auto h = c.h;
            if (c.stdHandle)
                h = GetStdHandle(STD_INPUT_HANDLE);
            DWORD n = 0;
            if (!ReadFile(h, data.ptr + off, cast(DWORD)(data.length - off), &n, null) || n == 0)
                return false;
            off += n;
        }
    }
    return true;
}

private bool writeFrame(ref Chan c, const(char)[] s) nothrow
{
    uint len = cast(uint)s.length;
    ubyte[4] hdr = [cast(ubyte)(len & 0xff), cast(ubyte)((len >> 8) & 0xff),
        cast(ubyte)((len >> 16) & 0xff), cast(ubyte)((len >> 24) & 0xff)];
    return chanWrite(c, hdr[]) && chanWrite(c, cast(const(ubyte)[])s);
}

private bool readFrame(ref Chan c, ref char[] out_) nothrow
{
    ubyte[4] hdr;
    if (!chanRead(c, hdr[]))
        return false;
    uint len = cast(uint)hdr[0] | (cast(uint)hdr[1] << 8) |
        (cast(uint)hdr[2] << 16) | (cast(uint)hdr[3] << 24);
    if (len > 64 * 1024 * 1024)
        return false;
    out_.length = len;
    return chanRead(c, cast(ubyte[])out_);
}

private string dupOrEmpty(const(char)[] s)
{
    return s is null ? "" : s.idup;
}

private void addStrOpt(Json js, JsonNode* o, const(char)* k, const(char)[] v)
{
    if (v.length)
        js.add_string_to_object(o, k, zstr(v));
    else
        js.add_null_to_object(o, k);
}

// ---------- worker (child) side ----------
    private void sendNeedRespawn()
    {
        auto js = jmake();
        auto root = js.create_object();
        js.add_bool_to_object(root, "needRespawn", true);
        writeFrame(outChan, printJsonStr(root));
    }

    private void addDiags(Json js, JsonNode* root, const ref Analysis a)
    {
        auto arr = js.create_array();
        foreach (ref d; a.diags)
        {
            auto o = js.create_object();
            js.add_string_to_object(o, "file", zstr(d.file));
            js.add_number_to_object(o, "line", d.line);
            js.add_number_to_object(o, "col", d.col);
            char[1] kb = [d.kind];
            js.add_string_to_object(o, "kind", zstr(kb[]));
            js.add_string_to_object(o, "text", zstr(d.text));
            js.add_item_to_array(arr, o);
        }
        js.add_item_to_object(root, "diagnostics", arr);
    }

    private void addLint(Json js, JsonNode* root, const(char)* key, const ref LintOut lo)
    {
        auto o = js.create_object();
        js.add_bool_to_object(o, "skipped", lo.skipped);
        addStrOpt(js, o, "skipReason", lo.skipReason);
        auto arr = js.create_array();
        for (size_t i = 0; i < lo.nhits; i++)
        {
            auto h = lo.hits[i];
            auto e = js.create_object();
            js.add_string_to_object(e, "path", zstr(h.path));
            js.add_number_to_object(e, "line", h.line);
            js.add_number_to_object(e, "col", h.col);
            js.add_number_to_object(e, "kind", h.kind);
            js.add_string_to_object(e, "name", zstr(h.name));
            js.add_number_to_object(e, "endLine", h.endLine);
            js.add_item_to_array(arr, e);
        }
        js.add_item_to_object(o, "hits", arr);
        js.add_item_to_object(root, key, o);
    }

    private void sendAnalyze(const ref Analysis a, bool unchanged = false)
    {
        auto js = jmake();
        auto root = js.create_object();
        addDiags(js, root, a);
        addLint(js, root, "lintImports", a.lintImports);
        addLint(js, root, "lintParams", a.lintParams);
        js.add_bool_to_object(root, "needRespawn", false);
        if (unchanged)
            js.add_bool_to_object(root, "unchanged", true);
        writeFrame(outChan, printJsonStr(root));
    }

    private void sendComplete(const ref CompleteOut out_)
    {
        auto js = jmake();
        auto root = js.create_object();
        auto arr = js.create_array();
        for (size_t i = 0; i < out_.nitems; i++)
        {
            auto it = out_.items[i];
            auto o = js.create_object();
            js.add_string_to_object(o, "label", zstr(it.label));
            js.add_number_to_object(o, "kind", it.kind);
            addStrOpt(js, o, "detail", it.detail);
            addStrOpt(js, o, "documentation", it.documentation);
            addStrOpt(js, o, "sortText", it.sortText);
            addStrOpt(js, o, "labelDetail", it.labelDetail);
            addStrOpt(js, o, "labelDesc", it.labelDesc);
            js.add_item_to_array(arr, o);
        }
        js.add_item_to_object(root, "items", arr);
        js.add_bool_to_object(root, "needRespawn", false);
        writeFrame(outChan, printJsonStr(root));
    }

    private void sendSignature(const ref SignatureInfo si)
    {
        auto js = jmake();
        auto root = js.create_object();
        js.add_bool_to_object(root, "found", si.found);
        if (si.found)
        {
            addStrOpt(js, root, "label", si.label);
            addStrOpt(js, root, "doc", si.doc);
            js.add_number_to_object(root, "activeParameter", si.activeParameter);
            auto arr = js.create_array();
            foreach (p; si.params)
            {
                auto o = js.create_object();
                addStrOpt(js, o, "label", p.label);
                js.add_number_to_object(o, "start", p.start);
                js.add_number_to_object(o, "end", p.end);
                addStrOpt(js, o, "doc", p.doc);
                js.add_item_to_array(arr, o);
            }
            js.add_item_to_object(root, "parameters", arr);
        }
        js.add_bool_to_object(root, "needRespawn", false);
        writeFrame(outChan, printJsonStr(root));
    }

    private void sendDefinition(const ref DefLoc def)
    {
        auto js = jmake();
        auto root = js.create_object();
        js.add_bool_to_object(root, "found", def.found);
        if (def.found)
        {
            addStrOpt(js, root, "file", def.file);
            js.add_number_to_object(root, "line", def.line);
            js.add_number_to_object(root, "col", def.col);
            js.add_number_to_object(root, "len", cast(double)def.len);
        }
        js.add_bool_to_object(root, "needRespawn", false);
        writeFrame(outChan, printJsonStr(root));
    }

    private void sendLocs(RefLoc[] locs)
    {
        auto js = jmake();
        auto root = js.create_object();
        auto arr = js.create_array();
        foreach (r; locs)
        {
            auto o = js.create_object();
            addStrOpt(js, o, "file", r.file);
            js.add_number_to_object(o, "line", r.line);
            js.add_number_to_object(o, "col", r.col);
            js.add_number_to_object(o, "len", r.len);
            js.add_item_to_array(arr, o);
        }
        js.add_item_to_object(root, "locs", arr);
        js.add_bool_to_object(root, "needRespawn", false);
        writeFrame(outChan, printJsonStr(root));
    }

    private void sendHints(InlayHint[] hints)
    {
        auto js = jmake();
        auto root = js.create_object();
        auto arr = js.create_array();
        foreach (h; hints)
        {
            auto o = js.create_object();
            js.add_number_to_object(o, "line", h.line);
            js.add_number_to_object(o, "col", h.col);
            addStrOpt(js, o, "label", h.label);
            js.add_bool_to_object(o, "padL", h.paddingLeft);
            js.add_bool_to_object(o, "padR", h.paddingRight);
            js.add_item_to_array(arr, o);
        }
        js.add_item_to_object(root, "hints", arr);
        js.add_bool_to_object(root, "needRespawn", false);
        writeFrame(outChan, printJsonStr(root));
    }

    private void sendFolds(FoldRange[] folds)
    {
        auto js = jmake();
        auto root = js.create_object();
        auto arr = js.create_array();
        foreach (f; folds)
        {
            auto o = js.create_object();
            js.add_number_to_object(o, "start", f.startLine);
            js.add_number_to_object(o, "end", f.endLine);
            addStrOpt(js, o, "kind", f.kind);
            js.add_item_to_array(arr, o);
        }
        js.add_item_to_object(root, "folds", arr);
        js.add_bool_to_object(root, "needRespawn", false);
        writeFrame(outChan, printJsonStr(root));
    }

    // Recursively emit one DocumentSymbol (LSP shape) into `arr`.
    private void addDocSymbol(Json js, JsonNode* arr, ref DocSymbol d)
    {
        auto o = js.create_object();
        js.add_string_to_object(o, "name", zstr(d.name));
        if (d.detail.length)
            js.add_string_to_object(o, "detail", zstr(d.detail));
        js.add_number_to_object(o, "kind", d.kind);
        auto range = js.create_object();
        auto st = js.create_object();
        js.add_number_to_object(st, "line", d.line);
        js.add_number_to_object(st, "character", d.col);
        auto en = js.create_object();
        js.add_number_to_object(en, "line", d.endLine);
        js.add_number_to_object(en, "character", d.endCol);
        js.add_item_to_object(range, "start", st);
        js.add_item_to_object(range, "end", en);
        js.add_item_to_object(o, "range", range);
        auto sel = js.create_object();
        auto ss = js.create_object();
        js.add_number_to_object(ss, "line", d.selLine);
        js.add_number_to_object(ss, "character", d.selCol);
        auto se = js.create_object();
        js.add_number_to_object(se, "line", d.selEndLine);
        js.add_number_to_object(se, "character", d.selEndCol);
        js.add_item_to_object(sel, "start", ss);
        js.add_item_to_object(sel, "end", se);
        js.add_item_to_object(o, "selectionRange", sel);
        if (d.children.length)
        {
            auto kids = js.create_array();
            foreach (ref c; d.children)
                addDocSymbol(js, kids, c);
            js.add_item_to_object(o, "children", kids);
        }
        js.add_item_to_array(arr, o);
    }

    private void sendDocumentSymbol(const ref Analysis a, const(char)[] text)
    {
        auto js = jmake();
        auto root = js.create_object();
        auto arr = js.create_array();
        DocSymbol[] syms = documentSymbols(cast(Module)a.module_, text);
        foreach (ref d; syms)
            addDocSymbol(js, arr, d);
        js.add_item_to_object(root, "result", arr);
        js.add_bool_to_object(root, "needRespawn", false);
        writeFrame(outChan, printJsonStr(root));
    }

    private void sendReferences(const(RefLoc)[] refs, bool complete = true,
        const(char)[] reason = null)
    {
        auto js = jmake();
        auto root = js.create_object();
        auto arr = js.create_array();
        foreach (r; refs)
        {
            auto o = js.create_object();
            js.add_string_to_object(o, "file", zstr(r.file));
            js.add_number_to_object(o, "line", r.line);
            js.add_number_to_object(o, "col", r.col);
            js.add_number_to_object(o, "len", r.len);
            js.add_item_to_array(arr, o);
        }
        js.add_item_to_object(root, "refs", arr);
        js.add_bool_to_object(root, "complete", complete);
        if (reason.length)
            js.add_string_to_object(root, "reason", zstr(reason));
        js.add_bool_to_object(root, "needRespawn", false);
        import core.stdc.stdlib : getenv;
        if (getenv("DMD_LSP_TRACE_REFS"))
        {
            const(char)[] rs = reason.length ? reason : "";
            log("refs n=%zu complete=%d reason=%.*s",
                refs.length, complete ? 1 : 0, cast(int) rs.length, rs.ptr);
        }
        writeFrame(outChan, printJsonStr(root));
    }

    private void sendSemantic(const(SemTok)[] toks)
    {
        auto js = jmake();
        auto root = js.create_object();
        auto arr = js.create_array();
        foreach (t; toks)
        {
            auto o = js.create_object();
            js.add_number_to_object(o, "line", t.line);
            js.add_number_to_object(o, "col", t.col);
            js.add_number_to_object(o, "len", t.len);
            js.add_number_to_object(o, "type", t.type);
            js.add_number_to_object(o, "mods", t.mods);
            js.add_item_to_array(arr, o);
        }
        js.add_item_to_object(root, "tokens", arr);
        js.add_bool_to_object(root, "needRespawn", false);
        writeFrame(outChan, printJsonStr(root));
    }

    private void sendHover(const ref HoverInfo h)
    {
        auto js = jmake();
        auto root = js.create_object();
        js.add_bool_to_object(root, "found", h.found);
        if (h.found)
        {
            addStrOpt(js, root, "detail", h.detail);
            addStrOpt(js, root, "doc", h.doc);
        }
        js.add_bool_to_object(root, "needRespawn", false);
        writeFrame(outChan, printJsonStr(root));
    }

    // Run `work` in a fork child over the inherited (copy-on-write) universe:
    // the child answers on `fd` and exits, so its mutations and any leak from
    // the incremental re-analysis die with it and the warm universe in this
    // process is never touched. Returns true only if the child exited 0 (i.e.
    // it produced its response); false means the caller must respawn.
    private bool forkRun(scope void delegate() work)
    {
        version (Posix)
        {
            auto pid = fork();
            if (pid < 0)
                return false;
            if (pid == 0)
            {
                try
                    work();
                catch (Throwable)
                    _exit(1);
                _exit(0);
            }
            int status = 0;
            if (waitpid(pid, &status, 0) < 0)
                return false;
            return WIFEXITED(status) && WEXITSTATUS(status) == 0;
        }
        else
        {
            // No fork on Windows: run inline in the worker. The worker is
            // replaced on a rebuild anyway, so the leak is bounded by respawn.
            try
                work();
            catch (Throwable)
                return false;
            return true;
        }
    }

    // Per-op tail shared by the in-process (hit/first-build) path and the
    // fork-child (incremental) path.
    private void completeAndSend(ref ServerState s, const ref Analysis a,
        const(char)[] orig, uint line, uint col, const(char)[] prefix)
    {
        CompleteCtx ctx;
        ctx.line = line;
        ctx.character = col;
        ctx.prefix = prefix;
        CompleteOut out_;
        completeAt(&s.scratch, cast(Module)a.module_, &ctx, orig, a.syn, out_);
        sendComplete(out_);
    }

    private void signatureAndSend(ref ServerState s, const ref Analysis a,
        const(char)[] orig, uint line, uint col)
    {
        CompleteCtx ctx;
        ctx.line = line;
        ctx.character = col;
        SignatureInfo si;
        signatureAt(&s.scratch, cast(Module)a.module_, &ctx, orig, a.syn, si);
        sendSignature(si);
    }

    private void definitionAndSend(ref ServerState s, const ref Analysis a,
        const(char)[] orig, uint line, uint col, bool typeDef = false)
    {
        CompleteCtx ctx;
        ctx.line = line;
        ctx.character = col;
        DefLoc def;
        if (typeDef)
            typeDefinitionAt(&s.scratch, cast(Module)a.module_, &ctx, orig, a.syn, def);
        else
            definitionAt(&s.scratch, cast(Module)a.module_, &ctx, orig, a.syn, def);
        sendDefinition(def);
    }

    // `textDocument/documentHighlight`: every occurrence of the cursor's symbol
    // in the current file (the request universe is that one module).
    private void documentHighlightAndSend(ref ServerState s, const ref Analysis a,
        const(char)[] path, const(char)[] orig, uint line, uint col)
    {
        auto target = resolvedSymbolAt(cast(Module)a.module_, line, col, orig);
        RefLoc[] locs;
        if (target)
            locs = findReferences(cast(Module)a.module_, target, true, path, orig);
        sendLocs(locs);
    }

    private void inlayHintsAndSend(ref ServerState s, const ref Analysis a,
        const(char)[] text)
    {
        sendHints(inlayHints(cast(Module)a.module_, text));
    }

    // ---------- call hierarchy ----------

    private void addCallItemFields(Json js, JsonNode* o, const ref WCallItem it)
    {
        js.add_string_to_object(o, "name", zstr(it.name));
        js.add_number_to_object(o, "kind", it.kind);
        js.add_string_to_object(o, "file", zstr(it.file));
        js.add_number_to_object(o, "line", it.line);
        js.add_number_to_object(o, "col", it.col);
        js.add_number_to_object(o, "endLine", it.endLine);
        js.add_number_to_object(o, "endCol", it.endCol);
    }

    private void sendCalls(string mode, WCallItem[] items, WCall[] calls)
    {
        auto js = jmake();
        auto root = js.create_object();
        js.add_string_to_object(root, "mode", zstr(mode));
        if (items.length)
        {
            auto arr = js.create_array();
            foreach (it; items)
            {
                auto o = js.create_object();
                addCallItemFields(js, o, it);
                js.add_item_to_array(arr, o);
            }
            js.add_item_to_object(root, "items", arr);
        }
        if (calls.length)
        {
            auto arr = js.create_array();
            foreach (c; calls)
            {
                auto o = js.create_object();
                auto it = js.create_object();
                addCallItemFields(js, it, c.item);
                js.add_item_to_object(o, "item", it);
                auto rs = js.create_array();
                foreach (r; c.ranges)
                {
                    auto ro = js.create_object();
                    js.add_number_to_object(ro, "line", r.line);
                    js.add_number_to_object(ro, "col", r.col);
                    js.add_number_to_object(ro, "len", r.len);
                    js.add_item_to_array(rs, ro);
                }
                js.add_item_to_object(o, "ranges", rs);
                js.add_item_to_array(arr, o);
            }
            js.add_item_to_object(root, "calls", arr);
        }
        js.add_bool_to_object(root, "needRespawn", false);
        writeFrame(outChan, printJsonStr(root));
    }

    private bool fillCallItem(ref WCallItem it, Dsymbol d)
    {
        auto fi = funcInfo(d);
        if (!fi.found)
            return false;
        it.name = fi.name;
        it.kind = fi.kind;
        it.file = fi.file;
        it.line = fi.line;
        it.col = fi.col;
        it.endLine = fi.endLine;
        it.endCol = fi.endCol;
        return true;
    }

    private void callAndSend(ref ServerState s, const ref Analysis a,
        const(char)[] path, const(char)[] orig, uint line, uint col, string mode)
    {
        import core.stdc.string : strlen;
        auto target = resolvedSymbolAt(cast(Module)a.module_, line, col, orig);
        auto fd = target ? target.isFuncDeclaration() : null;
        if (!fd)
        {
            sendCalls(mode, null, null);
            return;
        }
        if (mode == "prepare")
        {
            WCallItem it;
            if (fillCallItem(it, fd))
                sendCalls(mode, [it], null);
            else
                sendCalls(mode, null, null);
            return;
        }
        if (mode == "outgoing")
        {
            CallSite[] sites;
            collectCallsIn(fd, sites);
            size_t[Dsymbol] idx;
            WCall[] calls;
            foreach (site; sites)
            {
                if (!site.callee || !site.callee.ident)
                    continue;
                auto len = cast(uint) site.callee.ident.toString().length;
                if (auto p = site.callee in idx)
                {
                    calls[*p].ranges ~= WCallRange(site.line, site.col, len);
                    continue;
                }
                WCall c;
                if (!fillCallItem(c.item, site.callee))
                    continue;
                c.ranges ~= WCallRange(site.line, site.col, len);
                idx[site.callee] = calls.length;
                calls ~= c;
            }
            sendCalls(mode, null, calls);
            return;
        }
        // incoming: workspace-wide callers.
        auto targetKey = declKey(fd);
        const(char)* df = fd.loc.filename();
        string declFile = df ? df[0 .. strlen(df)].idup : null;
        string declName = declFile.length ? indexModuleOfFile(declFile) : null;
        size_t[Dsymbol] idx;
        WCall[] calls;
        void scanCandidate(Module m)
        {
            CallSite[] sites;
            collectCalls(m, sites);
            foreach (site; sites)
            {
                if (!site.callee || !site.enclosing || !site.callee.ident)
                    continue;
                if (!keyMatches(declKey(site.callee), targetKey))
                    continue;
                auto len = cast(uint) site.callee.ident.toString().length;
                if (auto p = site.enclosing in idx)
                {
                    calls[*p].ranges ~= WCallRange(site.line, site.col, len);
                    continue;
                }
                WCall c;
                if (!fillCallItem(c.item, site.enclosing))
                    continue;
                c.ranges ~= WCallRange(site.line, site.col, len);
                idx[site.enclosing] = calls.length;
                calls ~= c;
            }
        }
        scanCandidate(cast(Module)a.module_);
        if (declName.length)
        {
            bool[string] want;
            want[declName] = true;
            string reqName = indexModuleOfFile(path);
            if (reqName.length)
                want[reqName] = true;
            foreach (mn; importerModules(declName))
                want[mn] = true;
            foreach (mn, _; want)
            {
                auto f = indexFileOf(mn);
                if (!f.length || f == path)
                    continue; // request module already scanned
                const(char)[] text = sessionReadDisk(f);
                if (!text.length)
                    continue;
                auto ca = serverAnalyze(s, f, text);
                if (ca.ok && ca.module_)
                    scanCandidate(cast(Module)ca.module_);
            }
        }
        sendCalls(mode, null, calls);
    }

    // Best-effort `textDocument/implementation`: derived classes for a class/
    // interface, overrides for a method. Each candidate module is analysed on
    // its own and the base is matched by key (symbols do not cross universes).
    private void implementationAndSend(ref ServerState s, const ref Analysis a,
        const(char)[] path, const(char)[] orig, uint line, uint col)
    {
        import core.stdc.string : strlen;
        auto target = resolvedSymbolAt(cast(Module)a.module_, line, col, orig);
        Dsymbol cls = null;
        const(char)[] methodName = null;
        if (target)
        {
            if (auto fd = target.isFuncDeclaration())
            {
                if (fd.parent)
                    cls = fd.parent.isClassDeclaration();
                if (cls)
                    methodName = target.ident ? target.ident.toString().idup : null;
            }
            else if (target.isClassDeclaration())
                cls = target;
        }
        if (!cls)
        {
            sendLocs(null);
            return;
        }
        auto classKey = declKey(cls);
        const(char)* df = cls.loc.filename();
        string declFile = df ? df[0 .. strlen(df)].idup : null;
        string declName = declFile.length ? indexModuleOfFile(declFile) : null;
        RefLoc[] out_;
        if (!declName.length)
        {
            implementationLocs(cast(Module)a.module_, classKey, methodName, out_);
            sendLocs(out_);
            return;
        }
        bool[string] want;
        want[declName] = true;
        string reqName = indexModuleOfFile(path);
        if (reqName.length)
            want[reqName] = true;
        foreach (mn; importerModules(declName))
            want[mn] = true;
        foreach (mn, _; want)
        {
            auto f = indexFileOf(mn);
            if (!f.length)
                continue;
            const(char)[] text = (f == path && orig.length) ? orig : sessionReadDisk(f);
            if (!text.length)
                continue;
            auto ca = serverAnalyze(s, f, text);
            if (!ca.ok || !ca.module_)
                continue;
            implementationLocs(cast(Module)ca.module_, classKey, methodName, out_);
        }
        sendLocs(mergeRefs(out_, null));
    }

    private void hoverAndSend(ref ServerState s, const ref Analysis a,
        const(char)[] orig, uint line, uint col)
    {
        CompleteCtx ctx;
        ctx.line = line;
        ctx.character = col;
        HoverInfo h;
        hoverAt(&s.scratch, cast(Module)a.module_, &ctx, orig, a.syn, h);
        sendHover(h);
    }

// ---------- workspace symbol index ----------
private void flattenIndex(const(DocSymbol)[] syms, const(char)[] file,
    const(char)[] container, ref WIndexSym[] out_)
{
    foreach (ref d; syms)
    {
        out_ ~= WIndexSym(d.name.idup, d.kind, file.idup, d.line, d.col,
            container.idup);
        if (d.children.length)
            flattenIndex(d.children, file, d.name, out_);
    }
}

// Parse-only index build via the registration-free parse (H3), so the live
// universe is not evicted by the parse.
// Fully-qualified module name from a registration-free parse (H3): no package
// parent exists, so rebuild it from the module declaration.
private string indexModuleName(Module mod)
{
    string name;
    if (mod.md)
        foreach (p; mod.md.packages)
        {
            name ~= p.toString();
            name ~= ".";
        }
    if (mod.ident)
        name ~= mod.ident.toString();
    return name.length ? name.idup : null;
}

private void buildIndexNow(ref ServerState s, string[] files)
{
    import timing : nowMs, traceMs;

    ulong t0 = nowMs();
    g_index = null;
    g_files = null;
    // H3: parse each file without registering it, so the live semantic
    // universe survives (no `dmdResetRequest`). Roll back the Loc entries the
    // parses append, like the in-place re-parse path.
    size_t locTableLen;
    uint locIndex;
    dmdLocCheckpoint(locTableLen, locIndex);
    scope (exit)
        dmdLocRollback(locTableLen, locIndex);
    foreach (f; files)
    {
        auto text = sessionReadDisk(f);
        if (!text)
            continue;
        auto pr = dmdParseNoRegister(f, text);
        if (!pr.ok || !pr.module_)
            continue;
        auto mod = cast(Module)pr.module_;
        string moduleName = indexModuleName(mod);
        size_t before = g_index.length;
        flattenIndex(documentSymbols(mod, text), f, null, g_index);
        foreach (i; before .. g_index.length)
            g_index[i].moduleName = moduleName;
        WFileInfo fi;
        fi.file = f.idup;
        fi.moduleName = moduleName;
        if (mod.members)
            foreach (i; 0 .. (*mod.members).length)
            {
                auto imp = (*mod.members)[i].isImport();
                if (!imp || !imp.id)
                    continue;
                string name;
                foreach (p; imp.packages)
                {
                    name ~= p.toString();
                    name ~= ".";
                }
                name ~= imp.id.toString();
                if (name.length)
                    fi.imports ~= name.idup;
            }
        g_files ~= fi;
    }
    g_indexBuilt = true;
    traceMs("index.build", nowMs() - t0);
}

// File of a recorded module name, or null.
private string indexFileOf(const(char)[] moduleName)
{
    foreach (fi; g_files)
        if (fi.moduleName == moduleName)
            return fi.file;
    return null;
}

// Recorded module name of a file, or null.
private string indexModuleOfFile(const(char)[] file)
{
    foreach (fi; g_files)
        if (fi.file == file)
            return fi.moduleName;
    return null;
}

// Module names that can see `declName` through imports (declName included).
private string[] importerModules(const(char)[] declName)
{
    bool[string] canSee;
    canSee[declName] = true;
    bool changed = true;
    while (changed)
    {
        changed = false;
        foreach (fi; g_files)
        {
            if (fi.moduleName in canSee)
                continue;
            foreach (i; fi.imports)
                if (i in canSee)
                {
                    canSee[fi.moduleName] = true;
                    changed = true;
                    break;
                }
        }
    }
    string[] out_;
    foreach (k, v; canSee)
        out_ ~= k;
    return out_;
}

private char lowerChar(char c) pure nothrow @nogc @safe
{
    return (c >= 'A' && c <= 'Z') ? cast(char)(c + 32) : c;
}

// -1 no match, 0 prefix, 1 substring, 2 subsequence (case-insensitive).
private int indexRank(const(char)[] name, const(char)[] q)
{
    if (!q.length)
        return 1;
    if (name.length >= q.length)
    {
        bool prefix = true;
        foreach (i; 0 .. q.length)
            if (lowerChar(name[i]) != lowerChar(q[i]))
            {
                prefix = false;
                break;
            }
        if (prefix)
            return 0;
        foreach (start; 0 .. name.length - q.length + 1)
        {
            bool hit = true;
            foreach (i; 0 .. q.length)
                if (lowerChar(name[start + i]) != lowerChar(q[i]))
                {
                    hit = false;
                    break;
                }
            if (hit)
                return 1;
        }
    }
    size_t j = 0;
    foreach (c; name)
    {
        if (lowerChar(c) == lowerChar(q[j]))
        {
            j++;
            if (j == q.length)
                return 2;
        }
    }
    return -1;
}

private WIndexSym[] queryIndex(const(char)[] q, size_t cap = 200)
{
    WIndexSym[] out_;
    foreach (r; 0 .. 3)
        foreach (s; g_index)
        {
            if (indexRank(s.name, q) == r)
            {
                out_ ~= s;
                if (out_.length >= cap)
                    return out_;
            }
        }
    return out_;
}

private void sendIndexBuilt(size_t count)
{
    auto js = jmake();
    auto root = js.create_object();
    js.add_bool_to_object(root, "ok", true);
    js.add_number_to_object(root, "count", count);
    js.add_bool_to_object(root, "needRespawn", false);
    writeFrame(outChan, printJsonStr(root));
}

private void sendWorkspaceSymbols(const(WIndexSym)[] syms)
{
    auto js = jmake();
    auto root = js.create_object();
    auto arr = js.create_array();
    foreach (s; syms)
    {
        auto o = js.create_object();
        js.add_string_to_object(o, "name", zstr(s.name));
        js.add_number_to_object(o, "kind", s.kind);
        js.add_string_to_object(o, "file", zstr(s.file));
        js.add_number_to_object(o, "line", s.line);
        js.add_number_to_object(o, "col", s.col);
        if (s.container.length)
            js.add_string_to_object(o, "container", zstr(s.container));
        js.add_item_to_array(arr, o);
    }
    js.add_item_to_object(root, "syms", arr);
    js.add_bool_to_object(root, "needRespawn", false);
    writeFrame(outChan, printJsonStr(root));
}

// Symbols named `name` in indexed modules that `path` neither declares nor
// already imports, for an add-import quickfix. One per module.
private WIndexSym[] importCandidates(const(char)[] name, const(char)[] path)
{
    WIndexSym[] out_;
    if (!g_indexBuilt || !name.length)
        return out_;
    bool[string] imported;
    foreach (fi; g_files)
        if (fi.file == path)
            foreach (im; fi.imports)
                imported[im] = true;
    bool[string] seenModule;
    foreach (s; g_index)
    {
        if (s.name != name || s.file == path)
            continue;
        if (s.moduleName in imported || s.moduleName in seenModule)
            continue;
        seenModule[s.moduleName] = true;
        out_ ~= s;
        if (out_.length >= 20)
            break;
    }
    return out_;
}

private void sendImportCandidates(const(WIndexSym)[] cands)
{
    auto js = jmake();
    auto root = js.create_object();
    auto arr = js.create_array();
    foreach (s; cands)
    {
        auto o = js.create_object();
        js.add_string_to_object(o, "name", zstr(s.name));
        js.add_string_to_object(o, "module", zstr(s.moduleName));
        js.add_string_to_object(o, "file", zstr(s.file));
        js.add_number_to_object(o, "kind", s.kind);
        if (s.container.length)
            js.add_string_to_object(o, "container", zstr(s.container));
        js.add_item_to_array(arr, o);
    }
    js.add_item_to_object(root, "cands", arr);
    js.add_bool_to_object(root, "needRespawn", false);
    writeFrame(outChan, printJsonStr(root));
}

// Indexed symbols whose name starts with `prefix` in modules `path` does not
// import, for auto-import completion. One per (name, module).
private WIndexSym[] importCompletions(const(char)[] prefix, const(char)[] path)
{
    WIndexSym[] out_;
    if (!g_indexBuilt || prefix.length < 2)
        return out_;
    bool[string] imported;
    foreach (fi; g_files)
        if (fi.file == path)
            foreach (im; fi.imports)
                imported[im] = true;
    bool[string] seen;
    foreach (s; g_index)
    {
        if (s.file == path || s.moduleName in imported)
            continue;
        if (s.name.length < prefix.length || s.name[0 .. prefix.length] != prefix)
            continue;
        string key = s.name ~ "\x1f" ~ s.moduleName;
        if (key in seen)
            continue;
        seen[key] = true;
        out_ ~= s;
        if (out_.length >= 50)
            break;
    }
    return out_;
}

// ---------- implement / override stubs ----------

struct WStub
{
    string name;
    string sig; // `override <ret> <name>(<params>)`
}

// Parameter-type key: `name(t1,t2)`. Return type is ignored (D overloads by
// parameters), so a covariant override still matches its base.
private string paramKey(FuncDeclaration fd)
{
    import core.stdc.string : strlen;
    import dmd.mtype : TypeFunction;

    string k = fd.ident ? fd.ident.toString().idup : "";
    k ~= "(";
    auto tf = fd.type ? fd.type.isTypeFunction() : null;
    if (tf && tf.parameterList.parameters)
        foreach (i; 0 .. (*tf.parameterList.parameters).length)
        {
            if (i)
                k ~= ",";
            auto p = (*tf.parameterList.parameters)[i];
            const(char)* ts = (p && p.type) ? p.type.toChars() : null;
            k ~= ts ? ts[0 .. strlen(ts)] : "?";
        }
    k ~= ")";
    return k;
}

// `override <ret> <name>(<params>)`, storage classes preserved so the stub
// actually overrides.
private string methodSig(FuncDeclaration fd)
{
    import core.stdc.string : strlen;
    import dmd.astenums : STC, VarArg;

    auto tf = fd.type ? fd.type.isTypeFunction() : null;
    if (!tf || !fd.ident)
        return null;
    const(char)* rs = tf.next ? tf.next.toChars() : null;
    string ret = rs ? rs[0 .. strlen(rs)].idup : "auto";
    string ps;
    if (tf.parameterList.parameters)
        foreach (i; 0 .. (*tf.parameterList.parameters).length)
        {
            auto p = (*tf.parameterList.parameters)[i];
            if (!p)
                continue;
            if (ps.length)
                ps ~= ", ";
            if (p.storageClass & STC.ref_) ps ~= "ref ";
            else if (p.storageClass & STC.out_) ps ~= "out ";
            else if (p.storageClass & STC.lazy_) ps ~= "lazy ";
            else if (p.storageClass & STC.scope_) ps ~= "scope ";
            else if (p.storageClass & STC.in_) ps ~= "in ";
            const(char)* ts = p.type ? p.type.toChars() : null;
            ps ~= ts ? ts[0 .. strlen(ts)] : "?";
            if (p.ident)
            {
                ps ~= " ";
                ps ~= p.ident.toString();
            }
        }
    if (tf.parameterList.varargs != VarArg.none)
    {
        if (ps.length)
            ps ~= ", ";
        ps ~= "...";
    }
    return ("override " ~ ret ~ " " ~ fd.ident.toString() ~ "(" ~ ps ~ ")").idup;
}

private void sendImplementStubs(const(WStub)[] stubs)
{
    auto js = jmake();
    auto root = js.create_object();
    auto arr = js.create_array();
    foreach (s; stubs)
    {
        auto o = js.create_object();
        js.add_string_to_object(o, "name", zstr(s.name));
        js.add_string_to_object(o, "sig", zstr(s.sig));
        js.add_item_to_array(arr, o);
    }
    js.add_item_to_object(root, "stubs", arr);
    js.add_bool_to_object(root, "needRespawn", false);
    writeFrame(outChan, printJsonStr(root));
}

// The class the cursor is on (its name) or inside (a member's parent chain).
// Handles template instantiations (`Read!(Data!int)`) and the template
// declaration itself (`interface Read(T)`).
private ClassDeclaration classAt(Module mod, uint line, uint col,
    const(char)[] text)
{
    auto sym = resolvedSymbolAt(mod, line, col, text);
    if (!sym)
        return null;
    if (auto cd = sym.isClassDeclaration())
        return cd;
    if (auto ti = sym.isTemplateInstance())
        if (ti.inst)
            if (auto cd = ti.inst.isClassDeclaration())
                return cd;
    if (auto td = sym.isTemplateDeclaration())
    {
        if (td.onemember)
            if (auto cd = td.onemember.isClassDeclaration())
                return cd;
        if (td.members)
            foreach (i; 0 .. (*td.members).length)
                if (auto cd = (*td.members)[i].isClassDeclaration())
                    return cd;
    }
    for (auto p = sym.parent; p; p = p.parent)
        if (auto cd = p.isClassDeclaration())
            return cd;
    return null;
}

// Declaration key with template instantiations reduced to their template, so a
// `class C : Read!int` matches the `interface Read(T)` declaration.
private DeclKey originDeclKey(Dsymbol sym)
{
    if (sym.parent)
    {
        if (auto ti = sym.parent.isTemplateInstance())
            if (ti.tempdecl)
                return declKey(ti.tempdecl);
        // The aggregate declared by a template (`interface Read(T)`): key on
        // the template declaration so it matches every instantiation.
        if (sym.parent.isTemplateDeclaration())
            return declKey(sym.parent);
    }
    return declKey(sym);
}

private void implementStubsAndSend(ref ServerState s, const ref Analysis a,
    const(char)[] text, uint line, uint col)
{
    import dmd.func : FuncDeclaration;

    WStub[] stubs;
    if (auto cd = classAt(cast(Module)a.module_, line, col, text))
    {
        bool[string] have;
        foreach (m; scopeMembers(cd))
            if (auto fd = m.isFuncDeclaration())
                have[paramKey(fd)] = true;
        void add(FuncDeclaration fd, bool needAbstract)
        {
            if (!fd || !fd.ident)
                return;
            auto nm = fd.ident.toString();
            if (nm == "this" || nm == "~this" || nm == "new" || nm == "delete")
                return;
            if (needAbstract && !fd.isAbstract())
                return;
            auto k = paramKey(fd);
            if (k in have)
                return;
            have[k] = true;
            auto sig = methodSig(fd);
            if (sig.length)
                stubs ~= WStub(nm.idup, sig);
        }
        foreach (bc; cd.interfaces)
            if (bc.sym)
                foreach (m; scopeMembers(bc.sym))
                    add(m.isFuncDeclaration(), false);
        for (auto b = cd.baseClass; b; b = b.baseClass)
            foreach (m; scopeMembers(b))
                add(m.isFuncDeclaration(), true);
    }
    sendImplementStubs(stubs);
}

// ---------- type hierarchy ----------

struct WTypeItem
{
    string name;
    ubyte kind; // LSP SymbolKind (class 5, interface 11)
    string file;
    uint line; // 1-based
    uint col; // 1-based
    uint len;
}

// Column of `name` on 1-based `line`, searching the line from 1-based
// `fromCol` (aggregate `loc` points at the declaration keyword, not the name).
private void nameSpan(const(char)[] text, uint line, uint fromCol,
    const(char)[] name, out uint col, out uint len)
{
    col = fromCol;
    len = cast(uint) name.length;
    if (!name.length)
        return;
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
    size_t lineLen = i - ls;
    size_t s = fromCol > 0 ? fromCol - 1 : 0;
    if (s > lineLen)
        s = lineLen;
    for (size_t k = s; k + name.length <= lineLen; k++)
        if (text[ls + k .. ls + k + name.length] == name)
        {
            col = cast(uint)(k + 1);
            return;
        }
}

// Display name: the instantiated name for a template instance
// (`Read!(Data!(int))`), else the plain identifier.
private string typeName(ClassDeclaration cd)
{
    import core.stdc.string : strlen;

    if (cd.parent)
        if (auto ti = cd.parent.isTemplateInstance())
        {
            const(char)* s = ti.toChars();
            if (s)
                return s[0 .. strlen(s)].idup;
        }
    return cd.ident ? cd.ident.toString().idup : null;
}

private WTypeItem typeItem(ClassDeclaration cd)
{
    import core.stdc.string : strlen;

    WTypeItem it;
    it.name = typeName(cd);
    it.kind = cd.isInterfaceDeclaration() ? 11 : 5;
    const(char)* f = cd.loc.filename();
    it.file = f ? f[0 .. strlen(f)].idup : null;
    it.line = cd.loc.linnum();
    it.col = cast(uint) cd.loc.charnum();
    it.len = cd.ident ? cast(uint) cd.ident.toString().length : 0;
    if (cd.ident && it.line >= 1)
    {
        auto mod = moduleOf(cd);
        if (mod && mod.src.length)
            nameSpan(cast(const(char)[]) mod.src, it.line, it.col,
                cd.ident.toString(), it.col, it.len);
    }
    return it;
}

private void sendTypeItems(const(WTypeItem)[] items)
{
    auto js = jmake();
    auto root = js.create_object();
    auto arr = js.create_array();
    foreach (it; items)
    {
        auto o = js.create_object();
        js.add_string_to_object(o, "name", zstr(it.name));
        js.add_number_to_object(o, "kind", it.kind);
        js.add_string_to_object(o, "file", zstr(it.file));
        js.add_number_to_object(o, "line", it.line);
        js.add_number_to_object(o, "col", it.col);
        js.add_number_to_object(o, "len", it.len);
        js.add_item_to_array(arr, o);
    }
    js.add_item_to_object(root, "items", arr);
    js.add_bool_to_object(root, "needRespawn", false);
    writeFrame(outChan, printJsonStr(root));
}

// Classes in `mod` that directly derive from / implement `baseKey`.
private void collectSubtypesIn(Module mod, ref const DeclKey baseKey,
    ref WTypeItem[] out_)
{
    if (!mod || !mod.members)
        return;
    Dsymbol[] top;
    foreach (i; 0 .. (*mod.members).length)
        top ~= (*mod.members)[i];
    ClassDeclaration[] classes;
    collectClassDecls(top, classes);
    foreach (cd; classes)
    {
        bool direct = cd.baseClass &&
            keyMatches(originDeclKey(cd.baseClass), baseKey);
        if (!direct)
            foreach (bc; cd.interfaces)
                if (bc.sym && keyMatches(originDeclKey(bc.sym), baseKey))
                {
                    direct = true;
                    break;
                }
        if (direct)
            out_ ~= typeItem(cd);
    }
}

private void typeHierarchyAndSend(ref ServerState s, const ref Analysis a,
    const(char)[] path, const(char)[] orig, uint line, uint col,
    const(char)[] mode)
{
    import core.stdc.string : strlen;

    WTypeItem[] items;
    auto cd = classAt(cast(Module)a.module_, line, col, orig);
    if (!cd)
    {
        sendTypeItems(items);
        return;
    }
    if (mode == "prepare")
    {
        items ~= typeItem(cd);
        sendTypeItems(items);
        return;
    }
    if (mode == "supertypes")
    {
        // `baseClass` is null for interfaces; `interfaces` covers both a
        // class's implemented interfaces and an interface's base interfaces.
        for (auto b = cd.baseClass; b; b = b.baseClass)
            items ~= typeItem(b);
        foreach (bc; cd.interfaces)
            if (bc.sym)
                items ~= typeItem(bc.sym);
        sendTypeItems(items);
        return;
    }
    // subtypes: workspace-wide, mirroring the `implementation` op.
    auto baseKey = originDeclKey(cd);
    const(char)* df = cd.loc.filename();
    string declFile = df ? df[0 .. strlen(df)].idup : null;
    string declName = declFile.length ? indexModuleOfFile(declFile) : null;
    if (!declName.length)
    {
        sendTypeItems(items);
        return;
    }
    bool[string] want;
    want[declName] = true;
    string reqName = indexModuleOfFile(path);
    if (reqName.length)
        want[reqName] = true;
    foreach (mn; importerModules(declName))
        want[mn] = true;
    foreach (mn, _; want)
    {
        auto f = indexFileOf(mn);
        if (!f.length)
            continue;
        const(char)[] text = (f == path && orig.length) ? orig : sessionReadDisk(f);
        if (!text.length)
            continue;
        auto ca = serverAnalyze(s, f, text);
        if (!ca.ok || !ca.module_)
            continue;
        collectSubtypesIn(cast(Module)ca.module_, baseKey, items);
    }
    WTypeItem[] uniq;
    foreach (it; items)
    {
        bool dup = false;
        foreach (u; uniq)
            if (u.file == it.file && u.line == it.line && u.col == it.col)
            {
                dup = true;
                break;
            }
        if (!dup)
            uniq ~= it;
    }
    sendTypeItems(uniq);
}

// ---------- import-statement completion ----------

private bool startsWith(const(char)[] s, const(char)[] prefix)
{
    return s.length >= prefix.length && s[0 .. prefix.length] == prefix;
}

// If the cursor is completing an `import`, report the module-path prefix
// (module context) or the module + partial member (selective context).
// Textual: this is completion's own concern, no analysis.
// Tokens of the current line up to the cursor, lexed from the cached buffer
// (which is NUL-terminated at the cursor for the duration of the scan).
private Token[] lineTokens(ref LexCache c, const(char)[] text, uint line,
    uint col)
{
    import dmd.tokens : Token, TOK;

    Token[] toks;
    lexSet(c, text);
    if (c.buf is null)
        return toks;
    auto buf = cast(const(char)[]) c.buf[0 .. c.len];
    size_t ls = 0;
    uint l = 1;
    while (ls < c.len && l < line)
    {
        if (buf[ls] == '\n')
            l++;
        ls++;
    }
    size_t want = col > 0 ? col - 1 : 0;
    size_t avail = 0;
    while (ls + avail < c.len && buf[ls + avail] != '\n' && avail < want)
        avail++;
    size_t end = ls + avail;
    char saved = c.buf[end];
    c.buf[end] = 0;
    scope (exit)
        c.buf[end] = saved;
    scope lex = lexOver(c, ls, end);
    while (true)
    {
        Token t;
        lex.scan(&t);
        if (t.value == TOK.endOfFile)
            break;
        toks ~= t;
    }
    return toks;
}

private bool importContext(ref LexCache c, const(char)[] text, uint line,
    uint col, out const(char)[] modulePrefix, out const(char)[] selectModule,
    out const(char)[] selectPrefix)
{
    import dmd.tokens : TOK;

    modulePrefix = null;
    selectModule = null;
    selectPrefix = null;
    auto toks = lineTokens(c, text, line, col);
    size_t idx = 0;
    if (idx < toks.length &&
        (toks[idx].value == TOK.static_ || toks[idx].value == TOK.public_))
        idx++;
    if (idx >= toks.length || toks[idx].value != TOK.import_)
        return false;
    idx++;
    const(char)[] path;
    bool wantIdent = true;
    while (idx < toks.length)
    {
        auto tv = toks[idx].value;
        if (tv == TOK.identifier && wantIdent)
        {
            path ~= toks[idx].ident.toString();
            wantIdent = false;
            idx++;
        }
        else if (tv == TOK.dot && !wantIdent)
        {
            path ~= ".";
            wantIdent = true;
            idx++;
        }
        else
            break;
    }
    if (idx < toks.length && toks[idx].value == TOK.colon)
    {
        idx++;
        const(char)[] sp;
        while (idx < toks.length)
        {
            auto tv = toks[idx].value;
            if (tv == TOK.identifier)
            {
                sp = toks[idx].ident.toString();
                idx++;
            }
            else if (tv == TOK.comma)
            {
                sp = null;
                idx++;
            }
            else
                break;
        }
        selectModule = path.idup;
        selectPrefix = sp.length ? sp.idup : null;
        return true;
    }
    modulePrefix = path.idup;
    return true;
}

// Module name of a file under import dir `dir`, or null.
private string moduleNameOfFile(const(char)[] dir, const(char)[] file)
{
    size_t dl = dir.length;
    while (dl > 0 && (dir[dl - 1] == '/' || dir[dl - 1] == '\\'))
        dl--;
    if (file.length <= dl)
        return null;
    const(char)[] rel = file[dl .. $];
    while (rel.length && (rel[0] == '/' || rel[0] == '\\'))
        rel = rel[1 .. $];
    size_t e = rel.length;
    if (e >= 3 && rel[e - 3 .. e] == ".di")
        e -= 3;
    else if (e >= 2 && rel[e - 2 .. e] == ".d")
        e -= 2;
    rel = rel[0 .. e];
    size_t bs = e;
    while (bs > 0 && rel[bs - 1] != '/' && rel[bs - 1] != '\\')
        bs--;
    if (rel[bs .. e] == "package")
    {
        rel = rel[0 .. bs];
        while (rel.length && (rel[rel.length - 1] == '/' ||
            rel[rel.length - 1] == '\\'))
            rel = rel[0 .. rel.length - 1];
    }
    if (!rel.length)
        return null;
    string out_;
    foreach (c; rel)
        out_ ~= (c == '/' || c == '\\') ? '.' : c;
    return out_;
}

private __gshared string[] g_stdModules;

private string[] allModuleNames(ref ServerState s)
{
    string[] out_;
    foreach (fi; g_files)
        if (fi.moduleName.length)
            out_ ~= fi.moduleName;
    if (!g_stdModules.length)
    {
        import fsutil : findDFiles;
        foreach (dir; s.dmd.importPaths)
            foreach (f; findDFiles(dir))
            {
                auto mn = moduleNameOfFile(dir, f);
                if (mn.length)
                    g_stdModules ~= mn;
            }
    }
    out_ ~= g_stdModules;
    return out_;
}

// Handle an import-statement completion; true when it answered.
private bool completeImportAndSend(ref ServerState s, const(char)[] text,
    uint line, uint col)
{
    const(char)[] mprefix, smod, sprefix;
    if (!importContext(s.lex, text, line, col, mprefix, smod, sprefix))
        return false;
    // `import m : ` is handled semantically by `completeAt` (its
    // `selectiveImportAt`, incl. public re-exports); only the module-list
    // context is ours.
    if (smod !is null)
        return false;
    // Module labels are dotted and longer than the token the client would
    // replace (`rt.str` -> `rt.stream`), so send an explicit textEdit that
    // replaces the whole typed module path.
    auto js = jmake();
    auto root = js.create_object();
    auto arr = js.create_array();
    uint sl = line > 0 ? line - 1 : 0;
    uint sc = col > 0 ? col - 1 : 0;
    uint startCol = sc >= mprefix.length ? sc - cast(uint) mprefix.length : 0;
    bool[string] seen;
    foreach (mn; allModuleNames(s))
    {
        if (!startsWith(mn, mprefix) || mn in seen)
            continue;
        seen[mn] = true;
        auto o = js.create_object();
        js.add_string_to_object(o, "label", zstr(mn));
        js.add_number_to_object(o, "kind", 9); // CompletionItemKind.Module
        js.add_string_to_object(o, "detail", "module");
        auto te = js.create_object();
        auto range = js.create_object();
        auto st = js.create_object();
        js.add_number_to_object(st, "line", sl);
        js.add_number_to_object(st, "character", startCol);
        auto en = js.create_object();
        js.add_number_to_object(en, "line", sl);
        js.add_number_to_object(en, "character", sc);
        js.add_item_to_object(range, "start", st);
        js.add_item_to_object(range, "end", en);
        js.add_item_to_object(te, "range", range);
        js.add_string_to_object(te, "newText", zstr(mn));
        js.add_item_to_object(o, "textEdit", te);
        js.add_item_to_array(arr, o);
    }
    js.add_item_to_object(root, "items", arr);
    js.add_bool_to_object(root, "needRespawn", false);
    writeFrame(outChan, printJsonStr(root));
    return true;
}

// ---------- version/debug completion ----------

private immutable string[] versionPredefined =
[
    "Posix", "Windows", "linux", "OSX", "FreeBSD", "OpenBSD", "NetBSD",
    "DragonFlyBSD", "Solaris", "Haiku", "Android", "iOS", "tvOS", "watchOS",
    "DigitalMars", "GNU", "LDC", "SDC", "LittleEndian", "BigEndian", "D_LP64",
    "D_X32", "D_Version2", "D_InlineAsm_X86", "D_InlineAsm_X86_64", "D_SIMD",
    "D_AVX", "D_AVX2", "D_HardFloat", "D_SoftFloat", "D_BetterC", "D_Coverage",
    "D_Ddoc", "D_GC", "D_ProfileGC", "D_Exceptions", "D_ModuleInfo",
    "D_TypeInfo", "D_PIC", "D_NoBoundsChecks", "CRuntime_Bionic",
    "CRuntime_DigitalMars", "CRuntime_Glibc", "CRuntime_Microsoft",
    "CRuntime_Musl", "CRuntime_Newlib", "CRuntime_UClibc", "CRuntime_WASI",
    "CppRuntime_Clang", "CppRuntime_DigitalMars", "CppRuntime_Gcc",
    "CppRuntime_Microsoft", "X86", "X86_64", "ARM", "AArch64", "MIPS32",
    "MIPS64", "PPC", "PPC64", "RISCV32", "RISCV64", "S390X", "SPARC",
    "SPARC64", "SystemZ", "assert", "unittest", "all", "none", "Win32",
    "Win64",
];

// `version(Pos` / `debug(foo` — the partial condition inside the parens.
private bool versionContext(ref LexCache c, const(char)[] text, uint line,
    uint col, out const(char)[] prefix)
{
    import dmd.tokens : TOK;

    prefix = null;
    auto toks = lineTokens(c, text, line, col);
    size_t idx = 0;
    if (idx >= toks.length ||
        (toks[idx].value != TOK.version_ && toks[idx].value != TOK.debug_))
        return false;
    idx++;
    if (idx >= toks.length || toks[idx].value != TOK.leftParenthesis)
        return false;
    idx++;
    if (idx < toks.length && toks[idx].value == TOK.identifier)
    {
        prefix = toks[idx].ident.toString().idup;
        idx++;
    }
    // The cursor must still be inside the parens (no `)` seen yet).
    return idx == toks.length;
}

// `version = X;` / `debug = X;` identifiers declared in `text`.
private string[] userVersionNames(ref LexCache c, const(char)[] text)
{
    import dmd.tokens : Token, TOK;

    string[] out_;
    if (!text.length)
        return out_;
    lexSet(c, text);
    scope lex = lexOver(c, 0, c.len);
    int state = 0; // 1 after version/debug, 2 after `=`
    while (true)
    {
        Token t;
        lex.scan(&t);
        if (t.value == TOK.endOfFile)
            break;
        if (t.value == TOK.version_ || t.value == TOK.debug_)
        {
            state = 1;
            continue;
        }
        if (state == 1 && t.value == TOK.assign)
        {
            state = 2;
            continue;
        }
        if (state == 2 && t.value == TOK.identifier)
        {
            auto nm = t.ident ? t.ident.toString() : null;
            if (nm.length)
                out_ ~= nm.idup;
        }
        state = 0;
    }
    return out_;
}

private bool completeVersionAndSend(ref ServerState s, const(char)[] text,
    uint line, uint col)
{
    const(char)[] prefix;
    if (!versionContext(s.lex, text, line, col, prefix))
        return false;
    string[] names;
    ubyte[] kinds;
    void add(const(char)[] n)
    {
        if (!startsWith(n, prefix))
            return;
        foreach (e; names)
            if (e == n)
                return;
        names ~= n.idup;
        kinds ~= cast(ubyte) 21; // CompletionItemKind.Constant
    }
    foreach (n; versionPredefined)
        add(n);
    foreach (n; userVersionNames(s.lex, text))
        add(n);
    CompleteOut out_;
    addImportItems(&s.scratch, out_, names, kinds, "version");
    sendComplete(out_);
    return true;
}

// ---------- document links ----------

struct WLink
{
    uint sl, sc, el, ec; // 0-based LSP range (the string contents)
    string file; // resolved target
}

// `import("...")` string imports, resolved against `dirs`. Lexer-based, so
// comments/strings cannot confuse it.
private WLink[] documentLinks(ref LexCache c, const(char)[] text,
    const(string)[] dirs)
{
    import dmd.tokens : Token, TOK;

    WLink[] out_;
    if (!text.length)
        return out_;
    lexSet(c, text);
    scope lex = lexOver(c, 0, c.len);
    int state = 0; // 0 none, 1 after `import`, 2 after its `(`
    while (true)
    {
        Token t;
        lex.scan(&t);
        if (t.value == TOK.endOfFile)
            break;
        if (t.value == TOK.import_)
        {
            state = 1;
            continue;
        }
        if (t.value == TOK.leftParenthesis && state == 1)
        {
            state = 2;
            continue;
        }
        if (t.value == TOK.string_ && state == 2)
        {
            const(char)[] rel = t.ustring ? t.ustring[0 .. t.len] : null;
            state = 0;
            if (!rel.length)
                continue;
            foreach (d; dirs)
            {
                const(char)[] cand = d ~ "/" ~ rel;
                if (!fileExists(cand))
                    continue;
                WLink l;
                l.sl = t.loc.linnum() > 0 ? t.loc.linnum() - 1 : 0;
                l.sc = t.loc.charnum(); // 0-based start of the contents
                l.el = l.sl;
                l.ec = l.sc + cast(uint) rel.length;
                l.file = cand.idup;
                out_ ~= l;
                break;
            }
            continue;
        }
        state = 0;
    }
    return out_;
}

private void sendDocumentLinks(const(WLink)[] links)
{
    auto js = jmake();
    auto root = js.create_object();
    auto arr = js.create_array();
    foreach (l; links)
    {
        auto o = js.create_object();
        js.add_number_to_object(o, "sl", l.sl);
        js.add_number_to_object(o, "sc", l.sc);
        js.add_number_to_object(o, "el", l.el);
        js.add_number_to_object(o, "ec", l.ec);
        js.add_string_to_object(o, "file", zstr(l.file));
        js.add_item_to_array(arr, o);
    }
    js.add_item_to_object(root, "links", arr);
    js.add_bool_to_object(root, "needRespawn", false);
    writeFrame(outChan, printJsonStr(root));
}

private void referencesAndSend(ref ServerState s, const ref Analysis a,
    const(char)[] path, const(char)[] orig, uint line, uint col,
    bool includeDecl)
{
    auto target = resolvedSymbolAt(cast(Module)a.module_, line, col, orig);
    RefLoc[] refs;
    if (target)
        refs = findReferences(cast(Module)a.module_, target, includeDecl,
            path, orig);
    sendReferences(refs);
}

// ---- workspace-wide references ----
// The index gives the candidate importer modules; each candidate is then
// analysed as its own root (isolating failures) and uses are matched by
// declaration key, so no synthetic combined universe is needed. Completeness
// is tracked per candidate and reported alongside the locations (it gates
// rename). Must run in a fork: every `serverAnalyze` resets dmd state.

private bool isIdChar(char c) pure nothrow @nogc @safe
{
    return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9');
}

private bool containsWord(const(char)[] text, const(char)[] word)
{
    if (!word.length || text.length < word.length)
        return false;
    foreach (i; 0 .. text.length - word.length + 1)
    {
        if (text[i .. i + word.length] != word)
            continue;
        if (i > 0 && isIdChar(text[i - 1]))
            continue;
        if (i + word.length < text.length && isIdChar(text[i + word.length]))
            continue;
        return true;
    }
    return false;
}

// One references computation: in-universe target resolution plus per-candidate
// importer analysis, with completeness. Shared by references and rename.
struct RefResult
{
    bool found; // target resolved
    RefLoc[] refs;
    bool complete = true;
    string reason;
    string oldName; // target identifier (for the stale-source check)
    string declFile; // declaring file (workspace policy)
}

private RefResult computeRefs(ref ServerState s, const ref Analysis a,
    const(char)[] path, const(char)[] orig, uint line, uint col,
    bool includeDecl)
{
    import core.stdc.string : strlen;
    import timing : nowMs, traceMs;

    ulong tComputeStart = nowMs();
    RefResult r;
    auto target = resolvedSymbolAt(cast(Module)a.module_, line, col, orig);
    if (!target)
    {
        r.complete = false;
        r.reason = "no symbol";
        return r;
    }
    r.found = true;
    r.oldName = target.ident ? target.ident.toString().idup : "";
    const(char)* df = target.loc.filename();
    r.declFile = df ? df[0 .. strlen(df)].idup : null;
    // Reflective __traits can only hide a reference to an aggregate member;
    // module-level symbols and string mixins are covered by the resolved AST.
    const bool riskyMatters = isAggregateMember(target);

    if (isLocalDsymbol(target))
    {
        // A local cannot be referenced from another module: the request
        // universe is the whole search.
        r.refs = findReferences(cast(Module)a.module_, target, includeDecl,
            path, orig);
        return r;
    }

    // The target identity must be copied before any reset invalidates the
    // request universe; matching below is by key only.
    auto key = declKey(target);

    string declName = r.declFile.length ? indexModuleOfFile(r.declFile) : null;
    if (!declName.length)
    {
        // No index mapping: fall back to the in-universe closure walk (rare).
        r.refs = findReferences(cast(Module)a.module_, target, includeDecl,
            path, orig);
        r.complete = false;
        r.reason = "declaring module not indexed";
        return r;
    }
    const(char)[] ident = r.oldName;

    // Candidate set: declaring module + request module + every transitive
    // importer, word-prefiltered (cannot contain a use otherwise).
    bool[string] want;
    want[declName] = true;
    string reqName = indexModuleOfFile(path);
    if (reqName.length)
        want[reqName] = true;
    bool complete = reqName.length != 0;
    string reason = complete ? null : "request module not indexed";
    ulong tGather0 = nowMs();
    auto imp = importerModules(declName);
    foreach (mn; imp)
    {
        if (mn in want)
            continue;
        auto f = indexFileOf(mn);
        if (!f.length)
        {
            complete = false;
            if (!reason.length)
                reason = "unlocatable importer " ~ mn;
            continue;
        }
        auto t = sessionReadDisk(f);
        if (ident.length && t && !containsWord(t, ident))
            continue;
        want[mn] = true;
    }
    traceMs("refs.wide.gather", nowMs() - tGather0);

    // Analyse each candidate as its own root and match by declaration key.
    // A module that fails to load marks the result incomplete but cannot hide
    // its siblings. Runs in a fork: each `serverAnalyze` resets dmd state.
    RefLoc[] out_;
    ulong tAnalyze0 = nowMs();
    // Resolving a reference to a manifest constant requires the *unfolded* AST:
    // the frontend substitutes `Test.A` with its value, losing the member. Turn
    // that substitution off for the candidate analyses only (diagnostics and
    // completion keep it), and drop the cached universe so the request module is
    // re-analysed unfolded too. `lspNoManifestExpand` is imported from the
    // vendored frontend on purpose: a `make vendor` that drops the patch fails
    // to compile here instead of silently regressing.
    import dmd.optimize : lspNoManifestExpand;
    lspNoManifestExpand = true;
    s.uni.valid = false;
    scope (exit)
        lspNoManifestExpand = false;
    foreach (mn, _; want)
    {
        auto f = indexFileOf(mn);
        if (!f.length)
            continue;
        const(char)[] text;
        if (f == path && orig.length)
            text = orig; // request buffer may be ahead of disk
        else
            text = sessionReadDisk(f);
        if (!text.length)
        {
            complete = false;
            if (!reason.length)
                reason = "unreadable " ~ mn;
            continue;
        }
        if (ident.length && !containsWord(text, ident))
            continue;
        auto ca = serverAnalyze(s, f, text);
        if (!ca.ok || !ca.module_)
        {
            complete = false;
            if (!reason.length)
                reason = "parse failed " ~ mn;
            continue;
        }
        bool unloaded = dmdHasUnloadedImport(ca.module_);
        if (unloaded)
        {
            complete = false;
            if (!reason.length)
                reason = "unloaded import in " ~ mn;
        }
        else if (ca.errors > 0)
        {
            // A module that did not analyse cleanly can hide uses inside the
            // functions dmd collapsed, so the reference set is not exhaustive.
            complete = false;
            if (!reason.length)
                reason = "semantic errors in " ~ mn;
        }
        if (riskyMatters && dmdHasHiddenRefRisk(text, ident))
        {
            complete = false;
            if (!reason.length)
                reason = "__traits in " ~ mn;
        }
        out_ ~= referencesForKey([cast(Module) ca.module_], key, includeDecl,
            f, text);
    }
    traceMs("refs.wide.analyze", nowMs() - tAnalyze0, "modules");
    traceMs("refs.wide.total", nowMs() - tComputeStart);
    r.refs = mergeRefs(out_, null);
    r.complete = complete;
    r.reason = reason;
    return r;
}

private void wideReferencesAndSend(ref ServerState s, const ref Analysis a,
    const(char)[] path, const(char)[] orig, uint line, uint col,
    bool includeDecl)
{
    auto r = computeRefs(s, a, path, orig, line, col, includeDecl);
    sendReferences(r.refs, r.complete, r.reason);
}

// ---------- rename ----------

private void sendRename(bool ok, const(char)[] reason, const(char)[] declFile,
    const(RefLoc)[] edits)
{
    auto js = jmake();
    auto root = js.create_object();
    js.add_bool_to_object(root, "ok", ok);
    if (reason.length)
        js.add_string_to_object(root, "reason", zstr(reason));
    if (declFile.length)
        js.add_string_to_object(root, "declFile", zstr(declFile));
    auto arr = js.create_array();
    foreach (e; edits)
    {
        auto o = js.create_object();
        js.add_string_to_object(o, "file", zstr(e.file));
        js.add_number_to_object(o, "line", e.line);
        js.add_number_to_object(o, "col", e.col);
        js.add_number_to_object(o, "len", e.len);
        js.add_item_to_array(arr, o);
    }
    js.add_item_to_object(root, "edits", arr);
    js.add_bool_to_object(root, "needRespawn", false);
    writeFrame(outChan, printJsonStr(root));
}

private void sendPrepareRename(bool ok, uint line, uint col, uint len,
    const(char)[] name, const(char)[] reason)
{
    auto js = jmake();
    auto root = js.create_object();
    js.add_bool_to_object(root, "ok", ok);
    if (ok)
    {
        js.add_number_to_object(root, "line", line);
        js.add_number_to_object(root, "col", col);
        js.add_number_to_object(root, "len", len);
        if (name.length)
            js.add_string_to_object(root, "name", zstr(name));
    }
    if (reason.length)
        js.add_string_to_object(root, "reason", zstr(reason));
    js.add_bool_to_object(root, "needRespawn", false);
    writeFrame(outChan, printJsonStr(root));
}

// Two occurrences of the same identifier cannot overlap unless a producer
// double-recorded a span. Refuse rather than emit a corrupting edit.
private bool hasOverlappingEdits(const(RefLoc)[] refs)
{
    foreach (i; 0 .. refs.length)
        foreach (j; i + 1 .. refs.length)
        {
            if (refs[i].file != refs[j].file || refs[i].line != refs[j].line)
                continue;
            uint a0 = refs[i].col;
            uint a1 = a0 + refs[i].len;
            uint b0 = refs[j].col;
            uint b1 = b0 + refs[j].len;
            if (a0 < b1 && b0 < a1)
                return true;
        }
    return false;
}

private void renameAndSend(ref ServerState s, const ref Analysis a,
    const(char)[] path, const(char)[] orig, uint line, uint col,
    const(char)[] newName)
{
    auto occ = occurrenceAt(cast(Module)a.module_, line, col, orig);
    if (!occ.sym)
    {
        sendRename(false, "no symbol under cursor", null, null);
        return;
    }
    if (!isRenameable(occ.sym))
    {
        sendRename(false, "not a renameable declaration", null, null);
        return;
    }
    if (!dmdIsPlainIdentifier(newName))
    {
        sendRename(false, "invalid identifier", null, null);
        return;
    }
    auto r = computeRefs(s, a, path, orig, line, col, true);
    if (!r.found)
    {
        sendRename(false, r.reason.length ? r.reason : "no symbol", null, null);
        return;
    }
    if (!r.complete)
    {
        sendRename(false, r.reason.length ? r.reason : "incomplete",
            r.declFile, null);
        return;
    }
    // Stale-source guard: every edit's span must still spell the old name.
    foreach (e; r.refs)
    {
        const(char)[] text;
        if (e.file == path && orig.length)
            text = orig; // request buffer may be ahead of disk
        else
            text = sessionReadDisk(e.file);
        if (!text.length || !textSpells(text, e.line, e.col, r.oldName))
        {
            sendRename(false, "source changed, retry", r.declFile, null);
            return;
        }
    }
    if (hasOverlappingEdits(r.refs))
    {
        sendRename(false, "overlapping edits", r.declFile, null);
        return;
    }
    sendRename(true, null, r.declFile, r.refs);
}

    void workerMain()
    {
        version (Posix) { inChan.fd = 0; outChan.fd = 1; }
        version (Windows)
        {
            // Resolve the inherited std handles on each call (chanRead/chanWrite).
            inChan.stdHandle = true;
            outChan.stdHandle = true;
        }
        ServerState s;
        bool built = false;
        for (;;)
        {
            // A response we could not deliver already wedged the parent; exit
            // so it sees EOF and respawns instead of waiting forever.
            if (g_writeFailed)
                break;
            char[] req;
            if (!readFrame(inChan, req))
                break;
            jtmp.reset();
            auto p = jparse(req);
            auto ops = p ? jstr(jget(p, "op")) : null;
            if (ops == "shutdown")
                break;
            if (ops == "init")
            {
                string[] imports;
                string[] strings;
                if (auto ip = jget(p, "importPaths"))
                    if ((ip.type & 0xFF) == JsonArray)
                        for (auto c = ip.child; c; c = c.next)
                        {
                            auto v = jstr(c);
                            if (v.length)
                                imports ~= v.idup;
                        }
                if (auto sp = jget(p, "stringPaths"))
                    if ((sp.type & 0xFF) == JsonArray)
                        for (auto c = sp.child; c; c = c.next)
                        {
                            auto v = jstr(c);
                            if (v.length)
                                strings ~= v.idup;
                        }
                string[] flags;
                if (auto fp = jget(p, "flags"))
                    if ((fp.type & 0xFF) == JsonArray)
                        for (auto c = fp.child; c; c = c.next)
                        {
                            auto v = jstr(c);
                            if (v.length)
                                flags ~= v.idup;
                        }
                serverInit(s, imports, strings, flags);
                auto js = jmake();
                auto root = js.create_object();
                js.add_bool_to_object(root, "ok", true);
                writeFrame(outChan, printJsonStr(root));
                continue;
            }
            if (ops == "analyze")
            {
                auto path = dupOrEmpty(jstr(jget(p, "path")));
                auto text = jstr(jget(p, "text"));
                if (text is null)
                    text = "";
                // Diagnostics must never come from a completion-neutralized
                // universe, and open/save must not use the in-place re-parse:
                // for an edited root it leaves modules that import the root
                // holding stale symbols (false "not callable" in cyclic
                // projects). Reuse only an exact-text universe, else rebuild.
                auto st = built ? serverUniState(s, path, null, text) : UniState.miss;
                // Trivia-only edit (same significant tokens): diagnostics are
                // unchanged, so report them as-is. Leave the universe valid
                // with its old text hashes: the next semantic request then
                // re-analyses in place (incremental) instead of being forced
                // into a respawn. The cached analysis has stale positions, but
                // the edited text never matches its hashes, so it is never
                // reused.
                if (built && st == UniState.incremental &&
                    dmdTokenHash(text) == s.uni.tokenHash)
                {
                    Analysis none;
                    sendAnalyze(none, true);
                    continue;
                }
                // Narrowed to cyclic roots: only an in-place re-parse of a
                // root that some loaded module imports is unsafe (stale
                // symbols). Any other root keeps the cheap incremental path.
                if (st == UniState.incremental && built &&
                    dmdRootHasImporters(s.uni.analysis.module_))
                    st = UniState.miss;
                // Only the root text changed: re-analyze it in a fork child on
                // the warm dependency closure. A root switch, dependency edit
                // or config change needs a fresh universe.
                if (built && st == UniState.incremental && forkRun(() {
                    auto a = serverAnalyzeIncremental(s, path, text, null);
                    sendAnalyze(a);
                }))
                    continue;
                if (built && st != UniState.reuse)
                {
                    sendNeedRespawn();
                    continue;
                }
                auto a = built ? s.uni.analysis : serverAnalyze(s, path, text);
                if (built)
                    s.scratch.rewind(s.uni.mark);
                sendAnalyze(a);
                built = true;
                continue;
            }
            if (ops == "lint")
            {
                auto path = dupOrEmpty(jstr(jget(p, "path")));
                auto text = jstr(jget(p, "text"));
                if (text is null)
                    text = "";
                // Parse + AST lints on a fresh state. On POSIX this runs in a
                // fork child and leaves the live universe untouched; on
                // Windows it runs inline, so invalidate the universe and let
                // the next semantic request respawn.
                if (forkRun(() {
                    auto a = serverLint(s, path, text);
                    sendAnalyze(a);
                    version (Windows)
                        s.uni.valid = false;
                }))
                    continue;
                auto a = serverLint(s, path, text);
                sendAnalyze(a);
                version (Windows)
                    s.uni.valid = false;
                continue;
            }
            if (ops == "complete")
            {
                auto path = dupOrEmpty(jstr(jget(p, "path")));
                auto atext = jstr(jget(p, "atext"));
                if (atext is null)
                    atext = "";
                auto orig = jstr(jget(p, "origText"));
                if (orig is null)
                    orig = "";
                uint line = cast(uint)jint(jget(p, "line"));
                uint col = cast(uint)jint(jget(p, "col"));
                auto prefix = jstr(jget(p, "prefix"));
                if (prefix is null)
                    prefix = "";
                // Import-statement completion is textual: module names, or a
                // module's members after `import m : `.
                if (completeImportAndSend(s, orig, line, col))
                    continue;
                if (completeVersionAndSend(s, orig, line, col))
                    continue;
                // Keyed on the analysis text only, never the document
                // identity: while a member name grows, the neutralised buffer
                // is unchanged and the warm universe already answers it, so
                // matching on the document (which did move) would be a false
                // reuse of the wrong analysis.
                auto st = built ? serverUniState(s, path, null, atext) : UniState.miss;
                if (built && st == UniState.incremental && forkRun(() {
                    auto a2 = serverAnalyzeIncremental(s, path, atext, orig);
                    completeAndSend(s, a2, orig, line, col, prefix);
                }))
                    continue;
                if (built && st != UniState.reuse)
                {
                    sendNeedRespawn();
                    continue;
                }
                Analysis a;
                if (built)
                {
                    // Record the current document version so the debounced
                    // keypress analyze reuses this universe (cheap) instead of
                    // forking. open/save pass realOnly and get the real text.
                    import session : fnv1a64;
                    s.uni.rootHash = fnv1a64(cast(const(ubyte)[])orig);
                    s.scratch.rewind(s.uni.mark);
                    a = s.uni.analysis;
                }
                else
                {
                    a = serverAnalyze(s, path, atext, orig);
                }
                completeAndSend(s, a, orig, line, col, prefix);
                built = true;
                continue;
            }
            if (ops == "signature")
            {
                auto path = dupOrEmpty(jstr(jget(p, "path")));
                auto atext = jstr(jget(p, "atext"));
                if (atext is null)
                    atext = "";
                auto orig = jstr(jget(p, "origText"));
                if (orig is null)
                    orig = "";
                uint line = cast(uint)jint(jget(p, "line"));
                uint col = cast(uint)jint(jget(p, "col"));
                auto st = built ? serverUniState(s, path, orig, null) : UniState.miss;
                if (built && st == UniState.incremental && forkRun(() {
                    auto a = serverAnalyzeIncremental(s, path, atext, orig);
                    signatureAndSend(s, a, orig, line, col);
                }))
                    continue;
                if (built && st != UniState.reuse)
                {
                    sendNeedRespawn();
                    continue;
                }
                auto a = built ? s.uni.analysis : serverAnalyze(s, path, atext, orig);
                if (built)
                    s.scratch.rewind(s.uni.mark);
                signatureAndSend(s, a, orig, line, col);
                built = true;
                continue;
            }
            if (ops == "definition")
            {
                auto path = dupOrEmpty(jstr(jget(p, "path")));
                auto atext = jstr(jget(p, "atext"));
                if (atext is null)
                    atext = "";
                auto orig = jstr(jget(p, "origText"));
                if (orig is null)
                    orig = "";
                uint line = cast(uint)jint(jget(p, "line"));
                uint col = cast(uint)jint(jget(p, "col"));
                bool typeDef = jbool(jget(p, "type"), false);
                auto st = built ? serverUniState(s, path, orig, null) : UniState.miss;
                if (built && st == UniState.incremental && forkRun(() {
                    auto a = serverAnalyzeIncremental(s, path, atext, orig);
                    definitionAndSend(s, a, orig, line, col, typeDef);
                }))
                    continue;
                if (built && st != UniState.reuse)
                {
                    sendNeedRespawn();
                    continue;
                }
                auto a = built ? s.uni.analysis : serverAnalyze(s, path, atext, orig);
                if (built)
                    s.scratch.rewind(s.uni.mark);
                definitionAndSend(s, a, orig, line, col, typeDef);
                built = true;
                continue;
            }
            if (ops == "implementStubs")
            {
                auto path = dupOrEmpty(jstr(jget(p, "path")));
                auto atext = jstr(jget(p, "atext"));
                if (atext is null)
                    atext = "";
                auto orig = jstr(jget(p, "origText"));
                if (orig is null)
                    orig = "";
                uint line = cast(uint)jint(jget(p, "line"));
                uint col = cast(uint)jint(jget(p, "col"));
                auto st = built ? serverUniState(s, path, orig, null) : UniState.miss;
                if (built && st == UniState.incremental && forkRun(() {
                    auto a = serverAnalyzeIncremental(s, path, atext, orig);
                    implementStubsAndSend(s, a, orig, line, col);
                }))
                    continue;
                if (built && st != UniState.reuse)
                {
                    sendNeedRespawn();
                    continue;
                }
                auto a = built ? s.uni.analysis : serverAnalyze(s, path, atext, orig);
                if (built)
                    s.scratch.rewind(s.uni.mark);
                implementStubsAndSend(s, a, orig, line, col);
                built = true;
                continue;
            }
            if (ops == "inlayHint")
            {
                auto path = dupOrEmpty(jstr(jget(p, "path")));
                auto atext = jstr(jget(p, "atext"));
                if (atext is null)
                    atext = "";
                auto orig = jstr(jget(p, "origText"));
                if (orig is null)
                    orig = "";
                auto st = built ? serverUniState(s, path, orig, null) : UniState.miss;
                if (built && st == UniState.incremental && forkRun(() {
                    auto a = serverAnalyzeIncremental(s, path, atext, orig);
                    inlayHintsAndSend(s, a, orig);
                }))
                    continue;
                if (built && st != UniState.reuse)
                {
                    sendNeedRespawn();
                    continue;
                }
                auto a = built ? s.uni.analysis : serverAnalyze(s, path, atext, orig);
                if (built)
                    s.scratch.rewind(s.uni.mark);
                inlayHintsAndSend(s, a, orig);
                built = true;
                continue;
            }
            if (ops == "foldingRange")
            {
                auto text = jstr(jget(p, "text"));
                if (text is null)
                    text = "";
                sendFolds(foldingRanges(text));
                continue;
            }
            if (ops == "documentLink")
            {
                auto text = jstr(jget(p, "text"));
                if (text is null)
                    text = "";
                string[] dirs;
                if (auto da = jget(p, "dirs"))
                    if ((da.type & 0xFF) == JsonArray)
                        for (auto c = da.child; c; c = c.next)
                        {
                            auto v = jstr(c);
                            if (v.length)
                                dirs ~= v.idup;
                        }
                sendDocumentLinks(documentLinks(s.lex, text, dirs));
                continue;
            }
            if (ops == "documentHighlight")
            {
                auto path = dupOrEmpty(jstr(jget(p, "path")));
                auto atext = jstr(jget(p, "atext"));
                if (atext is null)
                    atext = "";
                auto orig = jstr(jget(p, "origText"));
                if (orig is null)
                    orig = "";
                uint line = cast(uint)jint(jget(p, "line"));
                uint col = cast(uint)jint(jget(p, "col"));
                auto st = built ? serverUniState(s, path, orig, null) : UniState.miss;
                if (built && st == UniState.incremental && forkRun(() {
                    auto a = serverAnalyzeIncremental(s, path, atext, orig);
                    documentHighlightAndSend(s, a, path, orig, line, col);
                }))
                    continue;
                if (built && st != UniState.reuse)
                {
                    sendNeedRespawn();
                    continue;
                }
                auto a = built ? s.uni.analysis : serverAnalyze(s, path, atext, orig);
                if (built)
                    s.scratch.rewind(s.uni.mark);
                documentHighlightAndSend(s, a, path, orig, line, col);
                built = true;
                continue;
            }
            if (ops == "callHierarchy")
            {
                auto path = dupOrEmpty(jstr(jget(p, "path")));
                auto atext = jstr(jget(p, "atext"));
                if (atext is null)
                    atext = "";
                auto orig = jstr(jget(p, "origText"));
                if (orig is null)
                    orig = "";
                uint line = cast(uint)jint(jget(p, "line"));
                uint col = cast(uint)jint(jget(p, "col"));
                auto mode = dupOrEmpty(jstr(jget(p, "mode")));
                auto st = built ? serverUniState(s, path, orig, null) : UniState.miss;
                if (built && st == UniState.incremental && forkRun(() {
                    auto a = serverAnalyzeIncremental(s, path, atext, orig);
                    callAndSend(s, a, path, orig, line, col, mode);
                }))
                    continue;
                if (built && st != UniState.reuse)
                {
                    sendNeedRespawn();
                    continue;
                }
                auto a = built ? s.uni.analysis : serverAnalyze(s, path, atext, orig);
                if (built)
                    s.scratch.rewind(s.uni.mark);
                if (forkRun(() {
                    callAndSend(s, a, path, orig, line, col, mode);
                }))
                    continue;
                sendCalls(mode, null, null);
                built = true;
                continue;
            }
            if (ops == "typeHierarchy")
            {
                auto path = dupOrEmpty(jstr(jget(p, "path")));
                auto atext = jstr(jget(p, "atext"));
                if (atext is null)
                    atext = "";
                auto orig = jstr(jget(p, "origText"));
                if (orig is null)
                    orig = "";
                uint line = cast(uint)jint(jget(p, "line"));
                uint col = cast(uint)jint(jget(p, "col"));
                auto mode = dupOrEmpty(jstr(jget(p, "mode")));
                auto st = built ? serverUniState(s, path, orig, null) : UniState.miss;
                if (built && st == UniState.incremental && forkRun(() {
                    auto a = serverAnalyzeIncremental(s, path, atext, orig);
                    typeHierarchyAndSend(s, a, path, orig, line, col, mode);
                }))
                    continue;
                if (built && st != UniState.reuse)
                {
                    sendNeedRespawn();
                    continue;
                }
                auto a = built ? s.uni.analysis : serverAnalyze(s, path, atext, orig);
                if (built)
                    s.scratch.rewind(s.uni.mark);
                if (forkRun(() {
                    typeHierarchyAndSend(s, a, path, orig, line, col, mode);
                }))
                    continue;
                WTypeItem[] none;
                sendTypeItems(none);
                built = true;
                continue;
            }
            if (ops == "implementation")
            {
                auto path = dupOrEmpty(jstr(jget(p, "path")));
                auto atext = jstr(jget(p, "atext"));
                if (atext is null)
                    atext = "";
                auto orig = jstr(jget(p, "origText"));
                if (orig is null)
                    orig = "";
                uint line = cast(uint)jint(jget(p, "line"));
                uint col = cast(uint)jint(jget(p, "col"));
                auto st = built ? serverUniState(s, path, orig, null) : UniState.miss;
                if (built && st == UniState.incremental && forkRun(() {
                    auto a = serverAnalyzeIncremental(s, path, atext, orig);
                    implementationAndSend(s, a, path, orig, line, col);
                }))
                    continue;
                if (built && st != UniState.reuse)
                {
                    sendNeedRespawn();
                    continue;
                }
                auto a = built ? s.uni.analysis : serverAnalyze(s, path, atext, orig);
                if (built)
                    s.scratch.rewind(s.uni.mark);
                if (forkRun(() {
                    implementationAndSend(s, a, path, orig, line, col);
                }))
                    continue;
                sendLocs(null);
                built = true;
                continue;
            }
            if (ops == "references")
            {
                auto path = dupOrEmpty(jstr(jget(p, "path")));
                auto atext = jstr(jget(p, "atext"));
                if (atext is null)
                    atext = "";
                auto orig = jstr(jget(p, "origText"));
                if (orig is null)
                    orig = "";
                uint line = cast(uint)jint(jget(p, "line"));
                uint col = cast(uint)jint(jget(p, "col"));
                bool includeDecl = jbool(jget(p, "includeDeclaration"), true);
                if (g_indexBuilt)
                {
                    // Workspace-wide: ensure the request universe, then fork
                    // (the per-candidate re-analysis clobbers the warm
                    // universe). Without a fork, fall back to the
                    // in-universe result rather than risk clobbering.
                    auto st0 = built ? serverUniState(s, path, orig, null) : UniState.miss;
                    Analysis a0;
                    if (built && st0 == UniState.reuse)
                        a0 = s.uni.analysis;
                    else
                    {
                        a0 = serverAnalyze(s, path, atext, orig);
                        built = true;
                    }
                    if (forkRun(() {
                        wideReferencesAndSend(s, a0, path, orig, line, col, includeDecl);
                    }))
                        continue;
                    referencesAndSend(s, a0, path, orig, line, col, includeDecl);
                    continue;
                }
                auto st = built ? serverUniState(s, path, orig, null) : UniState.miss;
                if (built && st == UniState.incremental && forkRun(() {
                    auto a = serverAnalyzeIncremental(s, path, atext, orig);
                    referencesAndSend(s, a, path, orig, line, col, includeDecl);
                }))
                    continue;
                if (built && st != UniState.reuse)
                {
                    sendNeedRespawn();
                    continue;
                }
                auto a = built ? s.uni.analysis : serverAnalyze(s, path, atext, orig);
                if (built)
                    s.scratch.rewind(s.uni.mark);
                referencesAndSend(s, a, path, orig, line, col, includeDecl);
                built = true;
                continue;
            }
            if (ops == "prepareRename")
            {
                auto path = dupOrEmpty(jstr(jget(p, "path")));
                auto atext = jstr(jget(p, "atext"));
                if (atext is null)
                    atext = "";
                auto orig = jstr(jget(p, "origText"));
                if (orig is null)
                    orig = "";
                uint line = cast(uint)jint(jget(p, "line"));
                uint col = cast(uint)jint(jget(p, "col"));
                auto st = built ? serverUniState(s, path, orig, null) : UniState.miss;
                Analysis a;
                if (built && st == UniState.reuse)
                    a = s.uni.analysis;
                else
                {
                    a = serverAnalyze(s, path, atext, orig);
                    built = true;
                }
                auto occ = occurrenceAt(cast(Module)a.module_, line, col, orig);
                if (!occ.sym || !isRenameable(occ.sym))
                    sendPrepareRename(false, 0, 0, 0, null, "not renameable");
                else
                    sendPrepareRename(true, occ.line, occ.col, occ.len,
                        occ.sym.ident.toString(), null);
                continue;
            }
            if (ops == "rename")
            {
                auto path = dupOrEmpty(jstr(jget(p, "path")));
                auto atext = jstr(jget(p, "atext"));
                if (atext is null)
                    atext = "";
                auto orig = jstr(jget(p, "origText"));
                if (orig is null)
                    orig = "";
                uint line = cast(uint)jint(jget(p, "line"));
                uint col = cast(uint)jint(jget(p, "col"));
                auto newName = jstr(jget(p, "newName"));
                if (newName is null)
                    newName = "";
                auto st = built ? serverUniState(s, path, orig, null) : UniState.miss;
                Analysis a0;
                if (built && st == UniState.reuse)
                    a0 = s.uni.analysis;
                else
                {
                    a0 = serverAnalyze(s, path, atext, orig);
                    built = true;
                }
                if (forkRun(() {
                    renameAndSend(s, a0, path, orig, line, col, newName);
                }))
                    continue;
                // No fork (Windows) or child failed: run inline and drop the
                // warm universe (per-candidate analysis resets it).
                renameAndSend(s, a0, path, orig, line, col, newName);
                built = false;
                continue;
            }
            if (ops == "hover")
            {
                auto path = dupOrEmpty(jstr(jget(p, "path")));
                auto atext = jstr(jget(p, "atext"));
                if (atext is null)
                    atext = "";
                auto orig = jstr(jget(p, "origText"));
                if (orig is null)
                    orig = "";
                uint line = cast(uint)jint(jget(p, "line"));
                uint col = cast(uint)jint(jget(p, "col"));
                auto st = built ? serverUniState(s, path, orig, null) : UniState.miss;
                if (built && st == UniState.incremental && forkRun(() {
                    auto a = serverAnalyzeIncremental(s, path, atext, orig);
                    hoverAndSend(s, a, orig, line, col);
                }))
                    continue;
                if (built && st != UniState.reuse)
                {
                    sendNeedRespawn();
                    continue;
                }
                auto a = built ? s.uni.analysis : serverAnalyze(s, path, atext, orig);
                if (built)
                    s.scratch.rewind(s.uni.mark);
                hoverAndSend(s, a, orig, line, col);
                built = true;
                continue;
            }
            if (ops == "documentSymbol")
            {
                auto path = dupOrEmpty(jstr(jget(p, "path")));
                auto text = jstr(jget(p, "text"));
                if (text is null)
                    text = "";
                auto st = built ? serverUniState(s, path, text, null) : UniState.miss;
                if (built && st == UniState.incremental && forkRun(() {
                    auto a = serverAnalyzeIncremental(s, path, text, null);
                    sendDocumentSymbol(a, text);
                }))
                    continue;
                if (built && st != UniState.reuse)
                {
                    sendNeedRespawn();
                    continue;
                }
                auto a = built ? s.uni.analysis : serverAnalyze(s, path, text);
                if (built)
                    s.scratch.rewind(s.uni.mark);
                sendDocumentSymbol(a, text);
                built = true;
                continue;
            }
            if (ops == "buildIndex")
            {
                string[] files;
                if (auto a = jget(p, "files"))
                    if ((a.type & 0xFF) == JsonArray)
                        for (auto c = a.child; c; c = c.next)
                        {
                            auto v = jstr(c);
                            if (v.length)
                                files ~= v.idup;
                        }
                buildIndexNow(s, files);
                // H3 keeps the parse registration-free, so the warm universe
                // is untouched and stays valid for the next request.
                sendIndexBuilt(g_index.length);
                continue;
            }
            if (ops == "workspaceSymbol")
            {
                auto q = jstr(jget(p, "query"));
                if (q is null)
                    q = "";
                sendWorkspaceSymbols(queryIndex(q));
                continue;
            }
            if (ops == "importCandidates")
            {
                auto nm = dupOrEmpty(jstr(jget(p, "name")));
                auto path = dupOrEmpty(jstr(jget(p, "path")));
                sendImportCandidates(importCandidates(nm, path));
                continue;
            }
            if (ops == "importCompletions")
            {
                auto pfx = dupOrEmpty(jstr(jget(p, "prefix")));
                auto path = dupOrEmpty(jstr(jget(p, "path")));
                sendImportCandidates(importCompletions(pfx, path));
                continue;
            }
            if (ops == "invalidateIndex")
            {
                g_index = null;
                g_indexBuilt = false;
                auto js = jmake();
                auto root = js.create_object();
                js.add_bool_to_object(root, "ok", true);
                js.add_bool_to_object(root, "needRespawn", false);
                writeFrame(outChan, printJsonStr(root));
                continue;
            }
            if (ops == "semantic")
            {
                auto path = dupOrEmpty(jstr(jget(p, "path")));
                auto text = jstr(jget(p, "text"));
                if (text is null)
                    text = "";
                // Reuse the live universe by document identity, like
                // diagnostics: this is what keeps completion/token/analyze
                // requests on the same buffer instead of evicting each other.
                // A neutralised universe is fine — the classifier is
                // position-safe and falls back to the pre-semantic snapshot.
                auto st = built ? serverUniState(s, path, text, null) : UniState.miss;
                if (built && st == UniState.incremental && forkRun(() {
                    auto a = serverAnalyzeIncremental(s, path, text, null);
                    SemTok[] toks;
                    semanticTokens(cast(Module)a.module_, a.syn, text, toks);
                    sendSemantic(toks);
                }))
                    continue;
                if (built && st != UniState.reuse)
                {
                    sendNeedRespawn();
                    continue;
                }
                auto a = built ? s.uni.analysis : serverAnalyze(s, path, text);
                if (built)
                    s.scratch.rewind(s.uni.mark);
                SemTok[] toks;
                semanticTokens(cast(Module)a.module_, a.syn, text, toks);
                sendSemantic(toks);
                built = true;
                continue;
            }
            sendNeedRespawn(); // unknown op
        }
    }


// ---------- parent side ----------
struct Worker
{
    Chan req;   // parent -> child requests
    Chan resp;  // child -> parent responses
    version (Posix)
        pid_t pid = -1;
    version (Windows)
        void* proc = null;
    bool alive = false;
}

private bool workerExchange(ref Worker w, const(char)[] req, ref char[] resp)
{
    if (!w.alive)
        return false;
    if (writeFrame(w.req, req) && readFrame(w.resp, resp))
        return true;
    log("worker exchange failed; respawning");
    return false;
}

void workerKill(ref Worker w)
{
    version (Posix)
    {
        if (w.req.fd >= 0) { close(w.req.fd); w.req.fd = -1; }
        if (w.resp.fd >= 0) { close(w.resp.fd); w.resp.fd = -1; }
        if (w.pid > 0)
        {
            int status = 0;
            waitpid(w.pid, &status, 0);
            if (WIFSIGNALED(status))
            {
                log("worker killed by signal %d", WTERMSIG(status));
            }
            w.pid = -1;
        }
    }
    version (Windows)
    {
        if (w.req.h) { CloseHandle(w.req.h); w.req.h = null; }
        if (w.resp.h) { CloseHandle(w.resp.h); w.resp.h = null; }
        if (w.proc)
        {
            TerminateProcess(w.proc, 0);
            WaitForSingleObject(w.proc, 5000);
            CloseHandle(w.proc);
            w.proc = null;
        }
    }
    w.alive = false;
}

// Pipe fds of `w` that a newly forked worker must close. Without this, a
// second worker inherits the first's pipe ends; killing the first then cannot
// EOF it (another process still holds the write end) and the server blocks in
// waitpid. Windows has no fork; use workerDisinherit instead.
void workerChildFds(ref Worker w, ref int[] out_)
{
    version (Posix)
    {
        if (w.req.fd >= 0)
            out_ ~= w.req.fd;
        if (w.resp.fd >= 0)
            out_ ~= w.resp.fd;
    }
}

// Windows: mark the server's ends of `w` non-inheritable so a later worker
// (CreateProcess inherits inheritable handles) cannot hold them open.
void workerDisinherit(ref Worker w)
{
    version (Windows)
    {
        import core.sys.windows.winbase : SetHandleInformation,
            HANDLE_FLAG_INHERIT;
        if (w.req.h)
            SetHandleInformation(w.req.h, HANDLE_FLAG_INHERIT, 0);
        if (w.resp.h)
            SetHandleInformation(w.resp.h, HANDLE_FLAG_INHERIT, 0);
    }
}

bool workerSpawn(ref Worker w, string[] imports, string[] strings, string[] flags,
    scope const(int)[] closeInChild = null)
{
    version (Posix)
    {
        int[2] toChild, fromChild;
        if (pipe(toChild) != 0)
            return false;
        if (pipe(fromChild) != 0)
        {
            close(toChild[0]); close(toChild[1]);
            return false;
        }
        auto pid = fork();
        if (pid < 0)
        {
            close(toChild[0]); close(toChild[1]);
            close(fromChild[0]); close(fromChild[1]);
            return false;
        }
        if (pid == 0)
        {
            // Child: never touch the parent's LSP stdout channel.
            dup2(toChild[0], 0);
            dup2(fromChild[1], 1);
            close(toChild[0]); close(toChild[1]);
            close(fromChild[0]); close(fromChild[1]);
            // Drop the server's other workers' pipe ends: inheriting them
            // would keep those workers alive after the server closes its end.
            foreach (fd; closeInChild)
                if (fd >= 0)
                    close(fd);
            workerMain();
            _exit(0);
        }
        close(toChild[0]);
        close(fromChild[1]);
        w.req.fd = toChild[1];
        w.resp.fd = fromChild[0];
        w.pid = pid;
        w.alive = true;
    }
    version (Windows)
    {
        SECURITY_ATTRIBUTES secattr;
        secattr.nLength = SECURITY_ATTRIBUTES.sizeof;
        secattr.lpSecurityDescriptor = null;
        secattr.bInheritHandle = TRUE;
        HANDLE toChildR, toChildW, fromChildR, fromChildW;
        if (!CreatePipe(&toChildR, &toChildW, &secattr, 0))
            return false;
        if (!CreatePipe(&fromChildR, &fromChildW, &secattr, 0))
        {
            CloseHandle(toChildR); CloseHandle(toChildW);
            return false;
        }
        // Don't inherit the parent's pipe ends, so the worker sees stdin EOF
        // when this process exits.
        SetHandleInformation(toChildW, HANDLE_FLAG_INHERIT, 0);
        SetHandleInformation(fromChildR, HANDLE_FLAG_INHERIT, 0);
        // Nor the LSP transport: an orphaned worker holding this process's
        // stdout would keep the client's pipe open and the server "running".
        SetHandleInformation(GetStdHandle(STD_INPUT_HANDLE), HANDLE_FLAG_INHERIT, 0);
        SetHandleInformation(GetStdHandle(STD_OUTPUT_HANDLE), HANDLE_FLAG_INHERIT, 0);
        STARTUPINFOA si;
        si.cb = STARTUPINFOA.sizeof;
        si.dwFlags = STARTF_USESTDHANDLES;
        si.hStdInput = toChildR;
        si.hStdOutput = fromChildW;
        si.hStdError = GetStdHandle(STD_ERROR_HANDLE);
        PROCESS_INFORMATION pi;
        char[4096] exe;
        auto n = GetModuleFileNameA(null, exe.ptr, cast(DWORD)exe.length);
        if (n == 0 || n >= exe.length)
        {
            CloseHandle(toChildR); CloseHandle(toChildW);
            CloseHandle(fromChildR); CloseHandle(fromChildW);
            return false;
        }
        exe[n] = 0;
        // argv[0] must be the exe: druntime rebuilds args from the command
        // line, and main.d finds the worker via `--worker` in args[1..$].
        char[4200] cmd;
        size_t ci = 0;
        cmd[ci++] = '"';
        cmd[ci .. ci + n] = exe[0 .. n];
        ci += n;
        cmd[ci++] = '"';
        cmd[ci++] = ' ';
        foreach (c; "--worker")
            cmd[ci++] = c;
        cmd[ci] = 0;
        if (!CreateProcessA(exe.ptr, cmd.ptr, null, null, TRUE, 0, null, null, &si, &pi))
        {
            CloseHandle(toChildR); CloseHandle(toChildW);
            CloseHandle(fromChildR); CloseHandle(fromChildW);
            return false;
        }
        CloseHandle(pi.hThread);
        CloseHandle(toChildR);
        CloseHandle(fromChildW);
        w.req.h = toChildW;
        w.resp.h = fromChildR;
        w.proc = pi.hProcess;
        w.alive = true;
    }

    auto js = jmake();
    auto root = js.create_object();
    js.add_string_to_object(root, "op", zstr("init"));
    auto ia = js.create_array();
    foreach (p; imports)
        js.add_item_to_array(ia, js.create_string(zstr(p)));
    js.add_item_to_object(root, "importPaths", ia);
    auto sa = js.create_array();
    foreach (p; strings)
        js.add_item_to_array(sa, js.create_string(zstr(p)));
    js.add_item_to_object(root, "stringPaths", sa);
    auto fa = js.create_array();
    foreach (p; flags)
        js.add_item_to_array(fa, js.create_string(zstr(p)));
    js.add_item_to_object(root, "flags", fa);

    char[] resp;
    if (!workerExchange(w, printJsonStr(root), resp))
    {
        log("worker: init exchange failed");
        workerKill(w);
        return false;
    }
    return true;
}

struct WDiag
{
    string file;
    uint line = 0;
    uint col = 0;
    char kind = 'E';
    string text;
}

struct WHit
{
    string path;
    uint line = 0;
    uint col = 0;
    ubyte kind = 0;
    string name;
    uint endLine = 0;
}

struct WLint
{
    WHit[] hits;
    bool skipped = false;
    string skipReason;
}

struct WAnalysis
{
    WDiag[] diags;
    WLint lintImports;
    WLint lintParams;
    bool unchanged; // trivia-only edit: no re-analysis, keep prior diagnostics
}

struct WItem
{
    string label;
    ubyte kind = 0;
    string detail;
    string documentation;
    string sortText;
    string labelDetail;
    string labelDesc;
    // Explicit replacement (0-based), for items whose label is longer than the
    // text the client would replace (e.g. dotted module names).
    bool hasEdit = false;
    uint editSl, editSc, editEl, editEc;
    string editText;
}

struct WSigParam
{
    string label;
    uint start = 0;
    uint end = 0;
}

struct WSig
{
    bool found = false;
    string label;
    string doc;
    WSigParam[] params;
    int activeParameter = 0;
}

struct WDef
{
    bool found = false;
    string file;
    uint line = 0; // 1-based
    uint col = 0;  // 1-based
    size_t len = 0;
}

struct WRef
{
    string file;
    uint line = 0; // 1-based
    uint col = 0;  // 1-based
    uint len = 0;
}

struct WFold
{
    uint start = 0; // 0-based line
    uint end = 0;   // 0-based line
    string kind;
}

struct WHint
{
    uint line = 0; // 0-based
    uint col = 0;  // 0-based
    string label;
    bool padL = false;
    bool padR = false;
}

struct WCallItem
{
    string name;
    ubyte kind;
    string file;
    uint line = 0, col = 0;       // 1-based name
    uint endLine = 0, endCol = 0; // 1-based function end
}

struct WCallRange
{
    uint line = 0, col = 0, len = 0; // 1-based
}

struct WCall
{
    WCallItem item;
    WCallRange[] ranges;
}

// References result plus whether the search is believed exhaustive. `complete`
// gates rename (all-or-nothing); references themselves are best-effort.
struct WRefs
{
    WRef[] refs;
    bool complete = true;
    string reason;
}

// prepareRename result: the identifier occurrence under the cursor.
struct WPrep
{
    bool ok = false;
    uint line = 0; // 1-based
    uint col = 0;  // 1-based
    uint len = 0;
    string name;
    string reason;
}

// rename result: the full edit set (empty on refusal, with `reason`).
struct WRename
{
    bool ok = false;
    string reason;
    string declFile; // declaring file (workspace policy)
    WRef[] edits;
}

struct WHover
{
    bool found = false;
    string detail;
    string doc;
}

struct WToken
{
    uint line = 0; // 0-based
    uint col = 0;  // 0-based
    uint len = 0;
    ubyte type = 0;
    uint mods = 0;
}

enum ExchangeResult
{
    ok,
    respawn,
    failed,
}

private void parseLint(JsonNode* node, ref WLint out_)
{
    if (!node)
        return;
    out_.skipped = jbool(jget(node, "skipped"), false);
    out_.skipReason = dupOrEmpty(jstr(jget(node, "skipReason")));
    if (auto arr = jget(node, "hits"))
    {
        for (auto c = arr.child; c; c = c.next)
        {
            WHit h;
            h.path = dupOrEmpty(jstr(jget(c, "path")));
            h.line = cast(uint)jint(jget(c, "line"));
            h.col = cast(uint)jint(jget(c, "col"));
            h.kind = cast(ubyte)jint(jget(c, "kind"));
            h.name = dupOrEmpty(jstr(jget(c, "name")));
            h.endLine = cast(uint)jint(jget(c, "endLine"));
            out_.hits ~= h;
        }
    }
}

private void parseAnalysis(JsonNode* root, ref WAnalysis out_)
{
    if (auto arr = jget(root, "diagnostics"))
    {
        for (auto c = arr.child; c; c = c.next)
        {
            WDiag d;
            d.file = dupOrEmpty(jstr(jget(c, "file")));
            d.line = cast(uint)jint(jget(c, "line"));
            d.col = cast(uint)jint(jget(c, "col"));
            auto ks = jstr(jget(c, "kind"));
            d.kind = ks.length ? ks[0] : 'E';
            d.text = dupOrEmpty(jstr(jget(c, "text")));
            out_.diags ~= d;
        }
    }
    parseLint(jget(root, "lintImports"), out_.lintImports);
    parseLint(jget(root, "lintParams"), out_.lintParams);
}

ExchangeResult workerAnalyze(ref Worker w, const(char)[] path, const(char)[] text,
    ref WAnalysis out_, bool realOnly = false)
{
    auto js = jmake();
    auto root = js.create_object();
    // open/save (realOnly) get full semantic diagnostics. The debounced
    // keypress normally uses the parse-only lint path, which is cheap because
    // POSIX forks a child for it. Windows has no fork, so the lint would
    // clobber the warm universe and force a worker respawn on the next
    // semantic request; use the in-place analyze path there instead.
    version (Windows)
        immutable bool useLint = false;
    else
        immutable bool useLint = !realOnly;
    js.add_string_to_object(root, "op", zstr(useLint ? "lint" : "analyze"));
    js.add_string_to_object(root, "path", zstr(path));
    js.add_string_to_object(root, "text", zstr(text));
    char[] resp;
    if (!workerExchange(w, printJsonStr(root), resp))
        return ExchangeResult.failed;
    auto r = jparse(resp);
    if (!r)
        return ExchangeResult.failed;
    if (jbool(jget(r, "needRespawn"), false))
        return ExchangeResult.respawn;
    out_.unchanged = jbool(jget(r, "unchanged"), false);
    parseAnalysis(r, out_);
    return ExchangeResult.ok;
}

ExchangeResult workerComplete(ref Worker w, const(char)[] path, const(char)[] atext,
    const(char)[] origText, uint line, uint col, const(char)[] prefix, ref WItem[] items)
{
    auto js = jmake();
    auto root = js.create_object();
    js.add_string_to_object(root, "op", zstr("complete"));
    js.add_string_to_object(root, "path", zstr(path));
    js.add_string_to_object(root, "atext", zstr(atext));
    js.add_string_to_object(root, "origText", zstr(origText));
    js.add_number_to_object(root, "line", line);
    js.add_number_to_object(root, "col", col);
    js.add_string_to_object(root, "prefix", zstr(prefix));
    char[] resp;
    if (!workerExchange(w, printJsonStr(root), resp))
        return ExchangeResult.failed;
    auto r = jparse(resp);
    if (!r)
        return ExchangeResult.failed;
    if (jbool(jget(r, "needRespawn"), false))
        return ExchangeResult.respawn;
    if (auto arr = jget(r, "items"))
    {
        for (auto c = arr.child; c; c = c.next)
        {
            WItem it;
            it.label = dupOrEmpty(jstr(jget(c, "label")));
            it.kind = cast(ubyte)jint(jget(c, "kind"));
            it.detail = dupOrEmpty(jstr(jget(c, "detail")));
            it.documentation = dupOrEmpty(jstr(jget(c, "documentation")));
            it.sortText = dupOrEmpty(jstr(jget(c, "sortText")));
            it.labelDetail = dupOrEmpty(jstr(jget(c, "labelDetail")));
            it.labelDesc = dupOrEmpty(jstr(jget(c, "labelDesc")));
            if (auto te = jget(c, "textEdit"))
            {
                it.hasEdit = true;
                auto rg = jget(te, "range");
                auto st = jget(rg, "start");
                auto en = jget(rg, "end");
                it.editSl = cast(uint)jint(jget(st, "line"));
                it.editSc = cast(uint)jint(jget(st, "character"));
                it.editEl = cast(uint)jint(jget(en, "line"));
                it.editEc = cast(uint)jint(jget(en, "character"));
                it.editText = dupOrEmpty(jstr(jget(te, "newText")));
            }
            items ~= it;
        }
    }
    return ExchangeResult.ok;
}

ExchangeResult workerSignature(ref Worker w, const(char)[] path, const(char)[] atext,
    const(char)[] origText, uint line, uint col, ref WSig out_)
{
    auto js = jmake();
    auto root = js.create_object();
    js.add_string_to_object(root, "op", zstr("signature"));
    js.add_string_to_object(root, "path", zstr(path));
    js.add_string_to_object(root, "atext", zstr(atext));
    js.add_string_to_object(root, "origText", zstr(origText));
    js.add_number_to_object(root, "line", line);
    js.add_number_to_object(root, "col", col);
    char[] resp;
    if (!workerExchange(w, printJsonStr(root), resp))
        return ExchangeResult.failed;
    auto r = jparse(resp);
    if (!r)
        return ExchangeResult.failed;
    if (jbool(jget(r, "needRespawn"), false))
        return ExchangeResult.respawn;
    out_.found = jbool(jget(r, "found"), false);
    if (out_.found)
    {
        out_.label = dupOrEmpty(jstr(jget(r, "label")));
        out_.doc = dupOrEmpty(jstr(jget(r, "doc")));
        out_.activeParameter = cast(int)jint(jget(r, "activeParameter"));
        if (auto arr = jget(r, "parameters"))
        {
            for (auto c = arr.child; c; c = c.next)
            {
                WSigParam p;
                p.label = dupOrEmpty(jstr(jget(c, "label")));
                p.start = cast(uint)jint(jget(c, "start"));
                p.end = cast(uint)jint(jget(c, "end"));
                out_.params ~= p;
            }
        }
    }
    return ExchangeResult.ok;
}

ExchangeResult workerDefinition(ref Worker w, const(char)[] path, const(char)[] atext,
    const(char)[] origText, uint line, uint col, ref WDef out_)
{
    auto js = jmake();
    auto root = js.create_object();
    js.add_string_to_object(root, "op", zstr("definition"));
    js.add_string_to_object(root, "path", zstr(path));
    js.add_string_to_object(root, "atext", zstr(atext));
    js.add_string_to_object(root, "origText", zstr(origText));
    js.add_number_to_object(root, "line", line);
    js.add_number_to_object(root, "col", col);
    char[] resp;
    if (!workerExchange(w, printJsonStr(root), resp))
        return ExchangeResult.failed;
    auto r = jparse(resp);
    if (!r)
        return ExchangeResult.failed;
    if (jbool(jget(r, "needRespawn"), false))
        return ExchangeResult.respawn;
    out_.found = jbool(jget(r, "found"), false);
    if (out_.found)
    {
        out_.file = dupOrEmpty(jstr(jget(r, "file")));
        out_.line = cast(uint)jint(jget(r, "line"));
        out_.col = cast(uint)jint(jget(r, "col"));
        out_.len = cast(size_t)jint(jget(r, "len"));
    }
    return ExchangeResult.ok;
}

ExchangeResult workerTypeDefinition(ref Worker w, const(char)[] path,
    const(char)[] atext, const(char)[] origText, uint line, uint col, ref WDef out_)
{
    auto js = jmake();
    auto root = js.create_object();
    js.add_string_to_object(root, "op", zstr("definition"));
    js.add_string_to_object(root, "path", zstr(path));
    js.add_string_to_object(root, "atext", zstr(atext));
    js.add_string_to_object(root, "origText", zstr(origText));
    js.add_number_to_object(root, "line", line);
    js.add_number_to_object(root, "col", col);
    js.add_bool_to_object(root, "type", true);
    char[] resp;
    if (!workerExchange(w, printJsonStr(root), resp))
        return ExchangeResult.failed;
    auto r = jparse(resp);
    if (!r)
        return ExchangeResult.failed;
    if (jbool(jget(r, "needRespawn"), false))
        return ExchangeResult.respawn;
    out_.found = jbool(jget(r, "found"), false);
    if (out_.found)
    {
        out_.file = dupOrEmpty(jstr(jget(r, "file")));
        out_.line = cast(uint)jint(jget(r, "line"));
        out_.col = cast(uint)jint(jget(r, "col"));
        out_.len = cast(size_t)jint(jget(r, "len"));
    }
    return ExchangeResult.ok;
}

ExchangeResult workerImplementation(ref Worker w, const(char)[] path,
    const(char)[] atext, const(char)[] origText, uint line, uint col,
    ref WRef[] out_)
{
    auto js = jmake();
    auto root = js.create_object();
    js.add_string_to_object(root, "op", zstr("implementation"));
    js.add_string_to_object(root, "path", zstr(path));
    js.add_string_to_object(root, "atext", zstr(atext));
    js.add_string_to_object(root, "origText", zstr(origText));
    js.add_number_to_object(root, "line", line);
    js.add_number_to_object(root, "col", col);
    char[] resp;
    if (!workerExchange(w, printJsonStr(root), resp))
        return ExchangeResult.failed;
    auto r = jparse(resp);
    if (!r)
        return ExchangeResult.failed;
    if (jbool(jget(r, "needRespawn"), false))
        return ExchangeResult.respawn;
    if (auto la = jget(r, "locs"))
        if ((la.type & 0xFF) == JsonArray)
            for (auto c = la.child; c; c = c.next)
            {
                WRef l;
                l.file = dupOrEmpty(jstr(jget(c, "file")));
                l.line = cast(uint)jint(jget(c, "line"));
                l.col = cast(uint)jint(jget(c, "col"));
                l.len = cast(uint)jint(jget(c, "len"));
                out_ ~= l;
            }
    return ExchangeResult.ok;
}

private WCallItem parseCallItem(JsonNode* c)
{
    WCallItem it;
    it.name = dupOrEmpty(jstr(jget(c, "name")));
    it.kind = cast(ubyte) jint(jget(c, "kind"));
    it.file = dupOrEmpty(jstr(jget(c, "file")));
    it.line = cast(uint)jint(jget(c, "line"));
    it.col = cast(uint)jint(jget(c, "col"));
    it.endLine = cast(uint)jint(jget(c, "endLine"));
    it.endCol = cast(uint)jint(jget(c, "endCol"));
    return it;
}

ExchangeResult workerCallHierarchy(ref Worker w, const(char)[] path,
    const(char)[] atext, const(char)[] origText, uint line, uint col,
    const(char)[] mode, ref WCallItem[] items, ref WCall[] calls)
{
    auto js = jmake();
    auto root = js.create_object();
    js.add_string_to_object(root, "op", zstr("callHierarchy"));
    js.add_string_to_object(root, "path", zstr(path));
    js.add_string_to_object(root, "atext", zstr(atext));
    js.add_string_to_object(root, "origText", zstr(origText));
    js.add_number_to_object(root, "line", line);
    js.add_number_to_object(root, "col", col);
    js.add_string_to_object(root, "mode", zstr(mode));
    char[] resp;
    if (!workerExchange(w, printJsonStr(root), resp))
        return ExchangeResult.failed;
    auto r = jparse(resp);
    if (!r)
        return ExchangeResult.failed;
    if (jbool(jget(r, "needRespawn"), false))
        return ExchangeResult.respawn;
    if (auto ia = jget(r, "items"))
        if ((ia.type & 0xFF) == JsonArray)
            for (auto c = ia.child; c; c = c.next)
                items ~= parseCallItem(c);
    if (auto ca = jget(r, "calls"))
        if ((ca.type & 0xFF) == JsonArray)
            for (auto c = ca.child; c; c = c.next)
            {
                WCall call;
                if (auto io = jget(c, "item"))
                    call.item = parseCallItem(io);
                if (auto ra = jget(c, "ranges"))
                    if ((ra.type & 0xFF) == JsonArray)
                        for (auto rc = ra.child; rc; rc = rc.next)
                        {
                            WCallRange range;
                            range.line = cast(uint)jint(jget(rc, "line"));
                            range.col = cast(uint)jint(jget(rc, "col"));
                            range.len = cast(uint)jint(jget(rc, "len"));
                            call.ranges ~= range;
                        }
                calls ~= call;
            }
    return ExchangeResult.ok;
}

// Type hierarchy (prepare/supertypes/subtypes).
ExchangeResult workerTypeHierarchy(ref Worker w, const(char)[] path,
    const(char)[] atext, const(char)[] origText, uint line, uint col,
    const(char)[] mode, ref WTypeItem[] out_)
{
    auto js = jmake();
    auto root = js.create_object();
    js.add_string_to_object(root, "op", zstr("typeHierarchy"));
    js.add_string_to_object(root, "path", zstr(path));
    js.add_string_to_object(root, "atext", zstr(atext));
    js.add_string_to_object(root, "origText", zstr(origText));
    js.add_number_to_object(root, "line", line);
    js.add_number_to_object(root, "col", col);
    js.add_string_to_object(root, "mode", zstr(mode));
    char[] resp;
    if (!workerExchange(w, printJsonStr(root), resp))
        return ExchangeResult.failed;
    auto r = jparse(resp);
    if (!r)
        return ExchangeResult.failed;
    if (jbool(jget(r, "needRespawn"), false))
        return ExchangeResult.respawn;
    if (auto arr = jget(r, "items"))
        for (auto c = arr.child; c; c = c.next)
        {
            WTypeItem it;
            it.name = dupOrEmpty(jstr(jget(c, "name")));
            it.kind = cast(ubyte) jint(jget(c, "kind"));
            it.file = dupOrEmpty(jstr(jget(c, "file")));
            it.line = cast(uint) jint(jget(c, "line"));
            it.col = cast(uint) jint(jget(c, "col"));
            it.len = cast(uint) jint(jget(c, "len"));
            out_ ~= it;
        }
    return ExchangeResult.ok;
}

ExchangeResult workerInlayHints(ref Worker w, const(char)[] path,
    const(char)[] atext, const(char)[] origText, ref WHint[] out_)
{
    auto js = jmake();
    auto root = js.create_object();
    js.add_string_to_object(root, "op", zstr("inlayHint"));
    js.add_string_to_object(root, "path", zstr(path));
    js.add_string_to_object(root, "atext", zstr(atext));
    js.add_string_to_object(root, "origText", zstr(origText));
    char[] resp;
    if (!workerExchange(w, printJsonStr(root), resp))
        return ExchangeResult.failed;
    auto r = jparse(resp);
    if (!r)
        return ExchangeResult.failed;
    if (jbool(jget(r, "needRespawn"), false))
        return ExchangeResult.respawn;
    if (auto ha = jget(r, "hints"))
        if ((ha.type & 0xFF) == JsonArray)
            for (auto c = ha.child; c; c = c.next)
            {
                WHint h;
                h.line = cast(uint)jint(jget(c, "line"));
                h.col = cast(uint)jint(jget(c, "col"));
                h.label = dupOrEmpty(jstr(jget(c, "label")));
                h.padL = jbool(jget(c, "padL"), false);
                h.padR = jbool(jget(c, "padR"), false);
                out_ ~= h;
            }
    return ExchangeResult.ok;
}

ExchangeResult workerFolding(ref Worker w, const(char)[] text, ref WFold[] out_)
{
    auto js = jmake();
    auto root = js.create_object();
    js.add_string_to_object(root, "op", zstr("foldingRange"));
    js.add_string_to_object(root, "text", zstr(text));
    char[] resp;
    if (!workerExchange(w, printJsonStr(root), resp))
        return ExchangeResult.failed;
    auto r = jparse(resp);
    if (!r)
        return ExchangeResult.failed;
    if (jbool(jget(r, "needRespawn"), false))
        return ExchangeResult.respawn;
    if (auto fa = jget(r, "folds"))
        if ((fa.type & 0xFF) == JsonArray)
            for (auto c = fa.child; c; c = c.next)
            {
                WFold f;
                f.start = cast(uint)jint(jget(c, "start"));
                f.end = cast(uint)jint(jget(c, "end"));
                f.kind = dupOrEmpty(jstr(jget(c, "kind")));
                out_ ~= f;
            }
    return ExchangeResult.ok;
}

ExchangeResult workerDocumentLinks(ref Worker w, const(char)[] text,
    const(string)[] dirs, ref WLink[] out_)
{
    auto js = jmake();
    auto root = js.create_object();
    js.add_string_to_object(root, "op", zstr("documentLink"));
    js.add_string_to_object(root, "text", zstr(text));
    auto da = js.create_array();
    foreach (d; dirs)
        js.add_item_to_array(da, js.create_string(zstr(d)));
    js.add_item_to_object(root, "dirs", da);
    char[] resp;
    if (!workerExchange(w, printJsonStr(root), resp))
        return ExchangeResult.failed;
    auto r = jparse(resp);
    if (!r)
        return ExchangeResult.failed;
    if (jbool(jget(r, "needRespawn"), false))
        return ExchangeResult.respawn;
    if (auto la = jget(r, "links"))
        if ((la.type & 0xFF) == JsonArray)
            for (auto c = la.child; c; c = c.next)
            {
                WLink l;
                l.sl = cast(uint)jint(jget(c, "sl"));
                l.sc = cast(uint)jint(jget(c, "sc"));
                l.el = cast(uint)jint(jget(c, "el"));
                l.ec = cast(uint)jint(jget(c, "ec"));
                l.file = dupOrEmpty(jstr(jget(c, "file")));
                out_ ~= l;
            }
    return ExchangeResult.ok;
}

ExchangeResult workerDocumentHighlight(ref Worker w, const(char)[] path,
    const(char)[] atext, const(char)[] origText, uint line, uint col,
    ref WRef[] out_)
{
    auto js = jmake();
    auto root = js.create_object();
    js.add_string_to_object(root, "op", zstr("documentHighlight"));
    js.add_string_to_object(root, "path", zstr(path));
    js.add_string_to_object(root, "atext", zstr(atext));
    js.add_string_to_object(root, "origText", zstr(origText));
    js.add_number_to_object(root, "line", line);
    js.add_number_to_object(root, "col", col);
    char[] resp;
    if (!workerExchange(w, printJsonStr(root), resp))
        return ExchangeResult.failed;
    auto r = jparse(resp);
    if (!r)
        return ExchangeResult.failed;
    if (jbool(jget(r, "needRespawn"), false))
        return ExchangeResult.respawn;
    if (auto la = jget(r, "locs"))
        if ((la.type & 0xFF) == JsonArray)
            for (auto c = la.child; c; c = c.next)
            {
                WRef l;
                l.file = dupOrEmpty(jstr(jget(c, "file")));
                l.line = cast(uint)jint(jget(c, "line"));
                l.col = cast(uint)jint(jget(c, "col"));
                l.len = cast(uint)jint(jget(c, "len"));
                out_ ~= l;
            }
    return ExchangeResult.ok;
}

ExchangeResult workerHover(ref Worker w, const(char)[] path, const(char)[] atext,
    const(char)[] origText, uint line, uint col, ref WHover out_)
{
    auto js = jmake();
    auto root = js.create_object();
    js.add_string_to_object(root, "op", zstr("hover"));
    js.add_string_to_object(root, "path", zstr(path));
    js.add_string_to_object(root, "atext", zstr(atext));
    js.add_string_to_object(root, "origText", zstr(origText));
    js.add_number_to_object(root, "line", line);
    js.add_number_to_object(root, "col", col);
    char[] resp;
    if (!workerExchange(w, printJsonStr(root), resp))
        return ExchangeResult.failed;
    auto r = jparse(resp);
    if (!r)
        return ExchangeResult.failed;
    if (jbool(jget(r, "needRespawn"), false))
        return ExchangeResult.respawn;
    out_.found = jbool(jget(r, "found"), false);
    if (out_.found)
    {
        out_.detail = dupOrEmpty(jstr(jget(r, "detail")));
        out_.doc = dupOrEmpty(jstr(jget(r, "doc")));
    }
    return ExchangeResult.ok;
}

ExchangeResult workerSemantic(ref Worker w, const(char)[] path, const(char)[] text,
    ref WToken[] toks)
{
    auto js = jmake();
    auto root = js.create_object();
    js.add_string_to_object(root, "op", zstr("semantic"));
    js.add_string_to_object(root, "path", zstr(path));
    js.add_string_to_object(root, "text", zstr(text));
    char[] resp;
    if (!workerExchange(w, printJsonStr(root), resp))
        return ExchangeResult.failed;
    auto r = jparse(resp);
    if (!r)
        return ExchangeResult.failed;
    if (jbool(jget(r, "needRespawn"), false))
        return ExchangeResult.respawn;
    if (auto arr = jget(r, "tokens"))
    {
        for (auto c = arr.child; c; c = c.next)
        {
            WToken t;
            t.line = cast(uint)jint(jget(c, "line"));
            t.col = cast(uint)jint(jget(c, "col"));
            t.len = cast(uint)jint(jget(c, "len"));
            t.type = cast(ubyte)jint(jget(c, "type"));
            t.mods = cast(uint)jint(jget(c, "mods"));
            toks ~= t;
        }
    }
    return ExchangeResult.ok;
}

// documentSymbol is forwarded as raw LSP JSON: the tree is built in the child
// (which owns the Module) and the parent re-serializes the `result` subtree.
ExchangeResult workerDocumentSymbol(ref Worker w, const(char)[] path,
    const(char)[] text, ref string resultJson)
{
    auto js = jmake();
    auto root = js.create_object();
    js.add_string_to_object(root, "op", zstr("documentSymbol"));
    js.add_string_to_object(root, "path", zstr(path));
    js.add_string_to_object(root, "text", zstr(text));
    char[] resp;
    if (!workerExchange(w, printJsonStr(root), resp))
        return ExchangeResult.failed;
    auto r = jparse(resp);
    if (!r)
        return ExchangeResult.failed;
    if (jbool(jget(r, "needRespawn"), false))
        return ExchangeResult.respawn;
    resultJson = printJsonStr(jget(r, "result"));
    return ExchangeResult.ok;
}

ExchangeResult workerReferences(ref Worker w, const(char)[] path,
    const(char)[] atext, const(char)[] origText, uint line, uint col,
    bool includeDecl, ref WRefs out_)
{
    auto js = jmake();
    auto root = js.create_object();
    js.add_string_to_object(root, "op", zstr("references"));
    js.add_string_to_object(root, "path", zstr(path));
    js.add_string_to_object(root, "atext", zstr(atext));
    js.add_string_to_object(root, "origText", zstr(origText));
    js.add_number_to_object(root, "line", line);
    js.add_number_to_object(root, "col", col);
    js.add_bool_to_object(root, "includeDeclaration", includeDecl);
    char[] resp;
    if (!workerExchange(w, printJsonStr(root), resp))
        return ExchangeResult.failed;
    auto r = jparse(resp);
    if (!r)
        return ExchangeResult.failed;
    if (jbool(jget(r, "needRespawn"), false))
        return ExchangeResult.respawn;
    // A fresh result each request.
    out_.refs = null;
    out_.complete = jbool(jget(r, "complete"), true);
    out_.reason = dupOrEmpty(jstr(jget(r, "reason")));
    if (auto arr = jget(r, "refs"))
    {
        for (auto c = arr.child; c; c = c.next)
        {
            WRef ref_;
            ref_.file = dupOrEmpty(jstr(jget(c, "file")));
            ref_.line = cast(uint)jint(jget(c, "line"));
            ref_.col = cast(uint)jint(jget(c, "col"));
            ref_.len = cast(uint)jint(jget(c, "len"));
            out_.refs ~= ref_;
        }
    }
    return ExchangeResult.ok;
}

private void parseEdits(JsonNode* r, ref WRef[] out_)
{
    out_.length = 0;
    if (auto arr = jget(r, "edits"))
        for (auto c = arr.child; c; c = c.next)
        {
            WRef e;
            e.file = dupOrEmpty(jstr(jget(c, "file")));
            e.line = cast(uint)jint(jget(c, "line"));
            e.col = cast(uint)jint(jget(c, "col"));
            e.len = cast(uint)jint(jget(c, "len"));
            out_ ~= e;
        }
}

ExchangeResult workerPrepareRename(ref Worker w, const(char)[] path,
    const(char)[] atext, const(char)[] origText, uint line, uint col,
    ref WPrep out_)
{
    auto js = jmake();
    auto root = js.create_object();
    js.add_string_to_object(root, "op", zstr("prepareRename"));
    js.add_string_to_object(root, "path", zstr(path));
    js.add_string_to_object(root, "atext", zstr(atext));
    js.add_string_to_object(root, "origText", zstr(origText));
    js.add_number_to_object(root, "line", line);
    js.add_number_to_object(root, "col", col);
    char[] resp;
    if (!workerExchange(w, printJsonStr(root), resp))
        return ExchangeResult.failed;
    auto r = jparse(resp);
    if (!r)
        return ExchangeResult.failed;
    if (jbool(jget(r, "needRespawn"), false))
        return ExchangeResult.respawn;
    out_ = WPrep.init;
    out_.ok = jbool(jget(r, "ok"), false);
    out_.line = cast(uint)jint(jget(r, "line"));
    out_.col = cast(uint)jint(jget(r, "col"));
    out_.len = cast(uint)jint(jget(r, "len"));
    out_.name = dupOrEmpty(jstr(jget(r, "name")));
    out_.reason = dupOrEmpty(jstr(jget(r, "reason")));
    return ExchangeResult.ok;
}

ExchangeResult workerRename(ref Worker w, const(char)[] path,
    const(char)[] atext, const(char)[] origText, uint line, uint col,
    const(char)[] newName, ref WRename out_)
{
    auto js = jmake();
    auto root = js.create_object();
    js.add_string_to_object(root, "op", zstr("rename"));
    js.add_string_to_object(root, "path", zstr(path));
    js.add_string_to_object(root, "atext", zstr(atext));
    js.add_string_to_object(root, "origText", zstr(origText));
    js.add_number_to_object(root, "line", line);
    js.add_number_to_object(root, "col", col);
    js.add_string_to_object(root, "newName", zstr(newName));
    char[] resp;
    if (!workerExchange(w, printJsonStr(root), resp))
        return ExchangeResult.failed;
    auto r = jparse(resp);
    if (!r)
        return ExchangeResult.failed;
    if (jbool(jget(r, "needRespawn"), false))
        return ExchangeResult.respawn;
    out_ = WRename.init;
    out_.ok = jbool(jget(r, "ok"), false);
    out_.reason = dupOrEmpty(jstr(jget(r, "reason")));
    out_.declFile = dupOrEmpty(jstr(jget(r, "declFile")));
    parseEdits(r, out_.edits);
    return ExchangeResult.ok;
}

ExchangeResult workerBuildIndex(ref Worker w, string[] files)
{
    auto js = jmake();
    auto root = js.create_object();
    js.add_string_to_object(root, "op", zstr("buildIndex"));
    auto arr = js.create_array();
    foreach (f; files)
        js.add_item_to_array(arr, js.create_string(zstr(f)));
    js.add_item_to_object(root, "files", arr);
    char[] resp;
    if (!workerExchange(w, printJsonStr(root), resp))
        return ExchangeResult.failed;
    auto r = jparse(resp);
    if (!r)
        return ExchangeResult.failed;
    if (jbool(jget(r, "needRespawn"), false))
        return ExchangeResult.respawn;
    return ExchangeResult.ok;
}

ExchangeResult workerWorkspaceSymbol(ref Worker w, const(char)[] query,
    ref WIndexSym[] out_)
{
    auto js = jmake();
    auto root = js.create_object();
    js.add_string_to_object(root, "op", zstr("workspaceSymbol"));
    js.add_string_to_object(root, "query", zstr(query));
    char[] resp;
    if (!workerExchange(w, printJsonStr(root), resp))
        return ExchangeResult.failed;
    auto r = jparse(resp);
    if (!r)
        return ExchangeResult.failed;
    if (jbool(jget(r, "needRespawn"), false))
        return ExchangeResult.respawn;
    if (auto arr = jget(r, "syms"))
    {
        for (auto c = arr.child; c; c = c.next)
        {
            WIndexSym s;
            s.name = dupOrEmpty(jstr(jget(c, "name")));
            s.kind = cast(ubyte)jint(jget(c, "kind"));
            s.file = dupOrEmpty(jstr(jget(c, "file")));
            s.line = cast(uint)jint(jget(c, "line"));
            s.col = cast(uint)jint(jget(c, "col"));
            s.container = dupOrEmpty(jstr(jget(c, "container")));
            out_ ~= s;
        }
    }
    return ExchangeResult.ok;
}

private ExchangeResult workerImportCands(ref Worker w, const(char)[] op,
    const(char)[] key, const(char)[] keyName, const(char)[] path,
    ref WIndexSym[] out_)
{
    auto js = jmake();
    auto root = js.create_object();
    js.add_string_to_object(root, "op", zstr(op));
    js.add_string_to_object(root, zstr(keyName), zstr(key));
    js.add_string_to_object(root, "path", zstr(path));
    char[] resp;
    if (!workerExchange(w, printJsonStr(root), resp))
        return ExchangeResult.failed;
    auto r = jparse(resp);
    if (!r)
        return ExchangeResult.failed;
    if (jbool(jget(r, "needRespawn"), false))
        return ExchangeResult.respawn;
    if (auto arr = jget(r, "cands"))
        for (auto c = arr.child; c; c = c.next)
        {
            WIndexSym s;
            s.name = dupOrEmpty(jstr(jget(c, "name")));
            s.moduleName = dupOrEmpty(jstr(jget(c, "module")));
            s.file = dupOrEmpty(jstr(jget(c, "file")));
            s.kind = cast(ubyte)jint(jget(c, "kind"));
            s.container = dupOrEmpty(jstr(jget(c, "container")));
            out_ ~= s;
        }
    return ExchangeResult.ok;
}

// Modules exporting `name` that `path` does not already import.
ExchangeResult workerImportCandidates(ref Worker w, const(char)[] name,
    const(char)[] path, ref WIndexSym[] out_)
{
    return workerImportCands(w, "importCandidates", name, "name", path, out_);
}

// Indexed symbols starting with `prefix` (auto-import completion).
ExchangeResult workerImportCompletions(ref Worker w, const(char)[] prefix,
    const(char)[] path, ref WIndexSym[] out_)
{
    return workerImportCands(w, "importCompletions", prefix, "prefix", path, out_);
}

// Interface/abstract methods a class still needs to implement, near (line,col).
ExchangeResult workerImplementStubs(ref Worker w, const(char)[] path,
    const(char)[] atext, const(char)[] origText, uint line, uint col,
    ref WStub[] out_)
{
    auto js = jmake();
    auto root = js.create_object();
    js.add_string_to_object(root, "op", zstr("implementStubs"));
    js.add_string_to_object(root, "path", zstr(path));
    js.add_string_to_object(root, "atext", zstr(atext));
    js.add_string_to_object(root, "origText", zstr(origText));
    js.add_number_to_object(root, "line", line);
    js.add_number_to_object(root, "col", col);
    char[] resp;
    if (!workerExchange(w, printJsonStr(root), resp))
        return ExchangeResult.failed;
    auto r = jparse(resp);
    if (!r)
        return ExchangeResult.failed;
    if (jbool(jget(r, "needRespawn"), false))
        return ExchangeResult.respawn;
    if (auto arr = jget(r, "stubs"))
        for (auto c = arr.child; c; c = c.next)
            out_ ~= WStub(dupOrEmpty(jstr(jget(c, "name"))),
                dupOrEmpty(jstr(jget(c, "sig"))));
    return ExchangeResult.ok;
}

ExchangeResult workerInvalidateIndex(ref Worker w)
{
    auto js = jmake();
    auto root = js.create_object();
    js.add_string_to_object(root, "op", zstr("invalidateIndex"));
    char[] resp;
    if (!workerExchange(w, printJsonStr(root), resp))
        return ExchangeResult.failed;
    auto r = jparse(resp);
    if (!r)
        return ExchangeResult.failed;
    return ExchangeResult.ok;
}

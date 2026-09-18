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
import json;
import lsp;
import session;
import server;
import complete;
import symbols : DocSymbol, documentSymbols;
import references : RefLoc, findReferences, isLocalDsymbol;
import lint;
import semantic : SemTok, semanticTokens;
import dmdwrap : dmdRootHasImporters, dmdTokenHash, dmdResetRequest, dmdParseOnly, dmdSemantic3Closure;

import dmd.dmodule : Module;

version (Posix)
{
    import core.sys.posix.unistd : read, write, close, fork, dup2, pipe, pid_t, _exit;
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
        void* h = null;
}

private __gshared Chan inChan;   // child: requests
private __gshared Chan outChan;  // child: responses

// Workspace symbol index (worker process). Parse-only declarations collected
// from the parent's file discovery. Built lazily, invalidated on watched
// changes; rebuilding resets the warm universe (see the `buildIndex` op).
struct WIndexSym
{
    string name;
    ubyte kind;
    string file;
    uint line; // 0-based
    uint col;
    string container;
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

private bool chanWrite(ref Chan c, const(ubyte)[] data) nothrow
{
    size_t off = 0;
    while (off < data.length)
    {
        version (Posix)
        {
            auto n = write(c.fd, data.ptr + off, data.length - off);
            if (n <= 0)
                return false;
            off += cast(size_t)n;
        }
        version (Windows)
        {
            DWORD n = 0;
            if (!WriteFile(c.h, data.ptr + off, cast(DWORD)(data.length - off), &n, null) || n == 0)
                return false;
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
            if (n <= 0)
                return false;
            off += cast(size_t)n;
        }
        version (Windows)
        {
            DWORD n = 0;
            if (!ReadFile(c.h, data.ptr + off, cast(DWORD)(data.length - off), &n, null) || n == 0)
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

    private void sendReferences(const(RefLoc)[] refs)
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
        js.add_bool_to_object(root, "needRespawn", false);
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
        const(char)[] orig, uint line, uint col)
    {
        CompleteCtx ctx;
        ctx.line = line;
        ctx.character = col;
        DefLoc def;
        definitionAt(&s.scratch, cast(Module)a.module_, &ctx, orig, a.syn, def);
        sendDefinition(def);
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

// Parse-only index build. Resets the dmd request state, so the caller must
// drop the warm universe (the op branch sets `built = false`).
private void buildIndexNow(ref ServerState s, string[] files)
{
    import core.stdc.string : strlen;

    g_index = null;
    g_files = null;
    dmdResetRequest(s.dmd, &s.sink);
    foreach (f; files)
    {
        auto text = sessionReadDisk(f);
        if (!text)
            continue;
        auto pr = dmdParseOnly(f, text);
        if (!pr.ok || !pr.module_)
            continue;
        auto mod = cast(Module)pr.module_;
        flattenIndex(documentSymbols(mod, text), f, null, g_index);
        WFileInfo fi;
        fi.file = f.idup;
        const(char)* mn = mod.toChars();
        if (mn)
            fi.moduleName = mn[0 .. strlen(mn)].idup;
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

private void referencesAndSend(ref ServerState s, const ref Analysis a,
    const(char)[] orig, uint line, uint col, bool includeDecl)
{
    CompleteCtx ctx;
    ctx.line = line;
    ctx.character = col;
    auto target = symbolAt(cast(Module)a.module_, &ctx, orig, a.syn);
    RefLoc[] refs;
    if (target)
        refs = findReferences(cast(Module)a.module_, target, includeDecl);
    sendReferences(refs);
}

// ---- workspace-wide references ----
// When the index is warm, extend the search to importer modules outside the
// request universe: build a synthetic root importing the request module, the
// declaring module and every (word-prefiltered) importer, re-analyze it, then
// match by declaration identity inside that combined universe. Must run in a
// fork (serverAnalyze resets the state).
private Module findModuleByFile(Module root, const(char)[] file)
{
    if (!root)
        return null;
    Module[] stack = [root];
    bool[Module] seen;
    seen[root] = true;
    while (stack.length)
    {
        auto m = stack[$ - 1];
        stack.length--;
        if (m.srcfile.toString() == file || m.arg == file)
            return m;
        if (!m.members)
            continue;
        foreach (i; 0 .. (*m.members).length)
        {
            auto imp = (*m.members)[i].isImport();
            if (imp && imp.mod && !(imp.mod in seen))
            {
                seen[imp.mod] = true;
                stack ~= imp.mod;
            }
        }
    }
    return null;
}

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

private void wideReferencesAndSend(ref ServerState s, const ref Analysis a,
    const(char)[] path, const(char)[] orig, uint line, uint col,
    bool includeDecl)
{
    import core.stdc.string : strlen;

    CompleteCtx ctx;
    ctx.line = line;
    ctx.character = col;
    auto target = symbolAt(cast(Module)a.module_, &ctx, orig, a.syn);
    if (!target || isLocalDsymbol(target))
    {
        RefLoc[] r0;
        if (target)
            r0 = findReferences(cast(Module)a.module_, target, includeDecl);
        sendReferences(r0);
        return;
    }
    // Universe-scoped result is computed before the synthetic re-analysis
    // below invalidates `a`; it is the fallback for every failure path.
    RefLoc[] base = findReferences(cast(Module)a.module_, target, includeDecl);
    const(char)* df = target.loc.filename();
    string declFile = df ? df[0 .. strlen(df)].idup : null;
    string declName = declFile.length ? indexModuleOfFile(declFile) : null;
    if (!declName.length)
    {
        sendReferences(base);
        return;
    }
    const(char)[] ident = target.ident ? target.ident.toString() : null;
    string reqName = indexModuleOfFile(path);
    bool[string] want;
    want[declName] = true;
    if (reqName.length)
        want[reqName] = true;
    foreach (mn; importerModules(declName))
    {
        if (mn in want)
            continue;
        auto f = indexFileOf(mn);
        if (!f.length)
            continue;
        auto t = sessionReadDisk(f);
        if (ident.length && t && !containsWord(t, ident))
            continue;
        want[mn] = true;
    }
    string synth = "module __dmd_lsp_ws;\n";
    foreach (mn, _; want)
        synth ~= "import " ~ mn ~ ";\n";
    auto a2 = serverAnalyze(s, "/tmp/dmd-lsp-ws/__dmd_lsp_ws.d", synth);
    dmdSemantic3Closure(a2.module_); // resolve importer bodies
    auto reqMod = findModuleByFile(cast(Module)a2.module_, path);
    auto reqText = sessionReadDisk(path);
    if (!reqMod || !reqText)
    {
        sendReferences(base);
        return;
    }
    SynMod empty;
    CompleteCtx rctx;
    rctx.line = line;
    rctx.character = col;
    auto t2 = symbolAt(reqMod, &rctx, reqText, empty);
    if (!t2)
    {
        sendReferences(base);
        return;
    }
    sendReferences(findReferences(cast(Module)a2.module_, t2, includeDecl));
}

    void workerMain()
    {
        version (Posix) { inChan.fd = 0; outChan.fd = 1; }
        version (Windows)
        {
            inChan.h = GetStdHandle(STD_INPUT_HANDLE);
            outChan.h = GetStdHandle(STD_OUTPUT_HANDLE);
        }
        ServerState s;
        bool built = false;
        for (;;)
        {
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
                // Trivia-only edit (same significant tokens): no re-analysis.
                // The program is unchanged, so keep the previous diagnostics
                // and just invalidate the universe (positions moved) so the
                // next semantic request rebuilds cleanly.
                if (built && st == UniState.incremental &&
                    dmdTokenHash(text) == s.uni.tokenHash)
                {
                    s.uni.valid = false;
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
                auto st = built ? serverUniState(s, path, orig, null) : UniState.miss;
                if (built && st == UniState.incremental && forkRun(() {
                    auto a = serverAnalyzeIncremental(s, path, atext, orig);
                    definitionAndSend(s, a, orig, line, col);
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
                definitionAndSend(s, a, orig, line, col);
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
                    // (the wide walk re-analyzes a synthetic importer root and
                    // would otherwise clobber the warm universe).
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
                    wideReferencesAndSend(s, a0, path, orig, line, col, includeDecl);
                    continue;
                }
                auto st = built ? serverUniState(s, path, orig, null) : UniState.miss;
                if (built && st == UniState.incremental && forkRun(() {
                    auto a = serverAnalyzeIncremental(s, path, atext, orig);
                    referencesAndSend(s, a, orig, line, col, includeDecl);
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
                referencesAndSend(s, a, orig, line, col, includeDecl);
                built = true;
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
                built = false; // reset above invalidated the warm universe
                s.uni.valid = false;
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
    import core.stdc.stdio : fprintf, stderr;
    fprintf(stderr, "dmd-lsp: worker exchange failed; respawning\n");
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
                import core.stdc.stdio : fprintf, stderr;
                fprintf(stderr, "dmd-lsp: worker killed by signal %d\n", WTERMSIG(status));
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

bool workerSpawn(ref Worker w, string[] imports, string[] strings, string[] flags)
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
        char* cmd = cast(char*) "--worker".ptr;
        if (!CreateProcessA(exe.ptr, cmd, null, null, TRUE, 0, null, null, &si, &pi))
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
    // open/save (realOnly) get full semantic diagnostics; the debounced
    // keypress uses the parse-only lint path, which is independent of the
    // (possibly neutralized, possibly stale) warm universe.
    js.add_string_to_object(root, "op", zstr(realOnly ? "analyze" : "lint"));
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
    bool includeDecl, ref WRef[] out_)
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
    if (auto arr = jget(r, "refs"))
    {
        for (auto c = arr.child; c; c = c.next)
        {
            WRef ref_;
            ref_.file = dupOrEmpty(jstr(jget(c, "file")));
            ref_.line = cast(uint)jint(jget(c, "line"));
            ref_.col = cast(uint)jint(jget(c, "col"));
            ref_.len = cast(uint)jint(jget(c, "len"));
            out_ ~= ref_;
        }
    }
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

module worker;

// Process-isolated analysis. The LSP front end (parent) holds no dmd state:
// dmd's process-global state is never fully reset by `deinitializeDMD`, so
// reusing one universe across rebuilds leaks. Instead a worker process is
// forked per universe; it performs exactly one full dmd build and then serves
// cache hits, so nothing accumulates. On invalidation the worker is discarded
// and the OS reclaims everything. All results crossing the boundary are plain
// data. Struct-only, no phobos. Requires Posix (fork/socketpair).

import arena;
import json;
import lsp;
import session;
import server;
import complete;
import lint;

import dmd.dmodule : Module;

version (Posix):
import core.stdc.stdio : fprintf, stderr;
import core.sys.posix.unistd : read, write, close, fork, dup2, pid_t;
import core.sys.posix.sys.socket : socketpair, AF_UNIX, SOCK_STREAM;
import core.sys.posix.sys.wait : waitpid;
import core.sys.posix.unistd : _exit;

// ---------- framing (length-prefixed, like LSP) ----------
private bool writeAll(int fd, const(ubyte)[] data) nothrow
{
    size_t off = 0;
    while (off < data.length)
    {
        auto n = write(fd, data.ptr + off, data.length - off);
        if (n <= 0)
            return false;
        off += cast(size_t)n;
    }
    return true;
}

private bool readAll(int fd, ubyte[] data) nothrow
{
    size_t off = 0;
    while (off < data.length)
    {
        auto n = read(fd, data.ptr + off, data.length - off);
        if (n <= 0)
            return false;
        off += cast(size_t)n;
    }
    return true;
}

private bool writeFrame(int fd, const(char)[] s) nothrow
{
    uint len = cast(uint)s.length;
    ubyte[4] hdr = [cast(ubyte)(len & 0xff), cast(ubyte)((len >> 8) & 0xff),
        cast(ubyte)((len >> 16) & 0xff), cast(ubyte)((len >> 24) & 0xff)];
    return writeAll(fd, hdr[]) && writeAll(fd, cast(const(ubyte)[])s);
}

private bool readFrame(int fd, ref char[] out_) nothrow
{
    ubyte[4] hdr;
    if (!readAll(fd, hdr[]))
        return false;
    uint len = cast(uint)hdr[0] | (cast(uint)hdr[1] << 8) |
        (cast(uint)hdr[2] << 16) | (cast(uint)hdr[3] << 24);
    if (len > 64 * 1024 * 1024)
        return false;
    out_.length = len;
    return readAll(fd, cast(ubyte[])out_);
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
version (Posix)
{
    private void sendNeedRespawn(int fd)
    {
        auto js = jmake();
        auto root = js.create_object();
        js.add_bool_to_object(root, "needRespawn", true);
        writeFrame(fd, printJsonStr(root));
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

    private void sendAnalyze(int fd, const ref Analysis a)
    {
        auto js = jmake();
        auto root = js.create_object();
        addDiags(js, root, a);
        addLint(js, root, "lintImports", a.lintImports);
        addLint(js, root, "lintParams", a.lintParams);
        js.add_bool_to_object(root, "needRespawn", false);
        writeFrame(fd, printJsonStr(root));
    }

    private void sendComplete(int fd, const ref CompleteOut out_)
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
        writeFrame(fd, printJsonStr(root));
    }

    private void sendSignature(int fd, const ref SignatureInfo si)
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
        writeFrame(fd, printJsonStr(root));
    }

    private void workerLoop(int fd)
    {
        ServerState s;
        bool built = false;
        for (;;)
        {
            char[] req;
            if (!readFrame(fd, req))
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
                writeFrame(fd, printJsonStr(root));
                continue;
            }
            if (ops == "analyze")
            {
                auto path = dupOrEmpty(jstr(jget(p, "path")));
                auto text = jstr(jget(p, "text"));
                if (text is null)
                    text = "";
                if (built && !serverWouldHit(s, path, text))
                {
                    sendNeedRespawn(fd);
                    continue;
                }
                auto a = serverAnalyze(s, path, text);
                sendAnalyze(fd, a);
                built = true;
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
                if (built && !serverWouldHitAnalysis(s, path, orig, atext))
                {
                    sendNeedRespawn(fd);
                    continue;
                }
                auto a = serverAnalyze(s, path, atext, orig);
                CompleteCtx ctx;
                ctx.line = line;
                ctx.character = col;
                ctx.prefix = prefix;
                CompleteOut out_;
                completeAt(&s.scratch, cast(Module)a.module_, &ctx, orig, a.syn, out_);
                sendComplete(fd, out_);
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
                if (built && !serverWouldHitAnalysis(s, path, orig, atext))
                {
                    sendNeedRespawn(fd);
                    continue;
                }
                auto a = serverAnalyze(s, path, atext, orig);
                CompleteCtx ctx;
                ctx.line = line;
                ctx.character = col;
                SignatureInfo si;
                signatureAt(&s.scratch, cast(Module)a.module_, &ctx, orig, a.syn, si);
                sendSignature(fd, si);
                built = true;
                continue;
            }
            sendNeedRespawn(fd); // unknown op
        }
    }
}

// ---------- parent side ----------
struct Worker
{
    pid_t pid = -1;
    int fd = -1;
    bool alive = false;
}

private bool workerExchange(ref Worker w, const(char)[] req, ref char[] resp)
{
    if (!w.alive)
        return false;
    return writeFrame(w.fd, req) && readFrame(w.fd, resp);
}

void workerKill(ref Worker w)
{
    version (Posix)
    {
        if (w.fd >= 0)
        {
            close(w.fd);
            w.fd = -1;
        }
        if (w.pid > 0)
        {
            waitpid(w.pid, null, 0);
            w.pid = -1;
        }
    }
    w.alive = false;
}

bool workerSpawn(ref Worker w, string[] imports, string[] strings, string[] flags)
{
    version (Posix)
    {
        import core.stdc.stdlib : getenv;
        import core.stdc.stdio : fprintf, stderr;
        if (getenv("DMD_LSP_TRACE_SPAWN"))
            fprintf(stderr, "dmd-lsp: spawn\n");
        int[2] sv;
        if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0)
            return false;
        auto pid = fork();
        if (pid < 0)
        {
            close(sv[0]);
            close(sv[1]);
            return false;
        }
        if (pid == 0)
        {
            // Child. Never touch the parent's LSP stdout channel.
            close(sv[0]);
            dup2(2, 1);
            workerLoop(sv[1]);
            _exit(0);
        }
        close(sv[1]);
        w.pid = pid;
        w.fd = sv[0];
        w.alive = true;

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
    else
        return false;
}

// Parse the plain-data results back into GC structs (outlive jtmp).

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
    ref WAnalysis out_)
{
    auto js = jmake();
    auto root = js.create_object();
    js.add_string_to_object(root, "op", zstr("analyze"));
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

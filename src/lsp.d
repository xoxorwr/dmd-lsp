module lsp;

// Minimal LSP/JSON-RPC structs + stdio transport. Struct-only.
// JSON via vendored `json` (no phobos).

import arena;
import json;
import core.stdc.stdio : stdin, stdout, fread, fwrite, fflush, fgetc, EOF, FILE;
import core.stdc.string : strlen;

struct LspCompletionItem
{
    const(char)[] label; // Arena slice
    ubyte kind = 0;      // LSP CompletionItemKind
    const(char)[] detail;
    const(char)[] documentation;
    const(char)[] sortText;
    const(char)[] labelDetail; // labelDetails.detail (e.g. "()")
    const(char)[] labelDesc;   // labelDetails.description (e.g. return type)
}

struct RawMsg
{
    string idJson; // raw JSON id ("1", "\"abc\"", or null="")
    bool hasId = false;
    string method;
    string paramsJson;
    bool ok = false;
}

// ---------- transport (single API: C stdio) ----------
private bool readLine(ref char[] buf)
{
    buf.length = 0;
    while (true)
    {
        int c = fgetc(stdin);
        if (c == EOF)
            return buf.length > 0;
        if (c == '\n')
            return true;
        if (c != '\r')
            buf ~= cast(char)c;
    }
}

bool lspRead(RawMsg* outm, ref string body_)
{
    char[] line;
    uint contentLength = 0;
    bool gotLen = false;
    while (readLine(line))
    {
        if (line.length == 0)
            break; // end of headers
        // Content-Length: N (case-insensitive prefix)
        if (line.length > 15)
        {
            bool match = true;
            static immutable char[] want = "content-length:";
            for (size_t i = 0; i < want.length; i++)
            {
                char a = line[i];
                if (a >= 'A' && a <= 'Z')
                    a = cast(char)(a + 32);
                if (a != want[i])
                {
                    match = false;
                    break;
                }
            }
            if (match)
            {
                size_t j = want.length;
                while (j < line.length && (line[j] == ' ' || line[j] == '\t'))
                    j++;
                uint v = 0;
                while (j < line.length && line[j] >= '0' && line[j] <= '9')
                {
                    v = v * 10 + cast(uint)(line[j] - '0');
                    j++;
                }
                contentLength = v;
                gotLen = true;
            }
        }
    }
    if (!gotLen || contentLength == 0 || contentLength > 64 * 1024 * 1024)
        return false;
    char[] bodyArr = new char[contentLength];
    size_t got = 0;
    while (got < contentLength)
    {
        size_t n = fread(bodyArr.ptr + got, 1, contentLength - got, stdin);
        if (n == 0)
            return false;
        got += n;
    }
    body_ = bodyArr.idup;
    jtmp.reset();
    auto js = jmake();
    JsonNode* root = js.parse(body_);
    if (!root || !js.is_object(root))
        return false;
    RawMsg m;
    if (auto id = jget(root, "id"))
    {
        m.hasId = true;
        m.idJson = printJsonStr(id);
    }
    if (auto mt = jget(root, "method"))
    {
        if ((mt.type & 0xFF) != JsonString || !mt.value_string)
            return false;
        auto sl = strlen(mt.value_string);
        m.method = mt.value_string[0 .. sl].idup;
    }
    else
        m.method = "";
    if (auto pr = jget(root, "params"))
        m.paramsJson = printJsonStr(pr);
    else
        m.paramsJson = "{}";
    m.ok = true;
    *outm = m;
    return true;
}

// ---------- transient message arena + JSON conveniences ----------
// Single-threaded daemon: one scratch arena per message, reset on read.
// Parsed trees and built responses live here; extracting code must dup
// anything that outlives the current message (session perm arena / idup).
__gshared Arena jtmp;
// The arena the helpers below use. The ops layer (ops.d) switches it to its
// own for the duration of a request, so the front end's in-flight JSON (the
// request it is sending, the result it is building) survives the op.
__gshared Arena* jcur = &jtmp;

Json jmake()
{
    return Json.create(Allocator(jcur));
}

// Parse a JSON document into jtmp (appends; null on failure).
JsonNode* jparse(const(char)[] text)
{
    if (!text.length)
        return null;
    auto js = jmake();
    return js.parse(text);
}

// NUL-terminated arena copy for C-string JSON APIs.
const(char)* zstr(const(char)[] s)
{
    char* p = cast(char*)jcur.alloc(s.length + 1);
    if (!p)
        return null;
    if (s.length)
        p[0 .. s.length] = s[];
    p[s.length] = 0;
    return p;
}

// Exact-match child lookup (null unless object with that key).
JsonNode* jget(JsonNode* o, const(char)* key)
{
    if (!o || (o.type & 0xFF) != JsonObject || !key)
        return null;
    for (auto c = o.child; c; c = c.next)
    {
        if (!c.key)
            continue;
        const(char)* a = c.key;
        const(char)* b = key;
        while (*a && *a == *b)
        {
            a++;
            b++;
        }
        if (*a == *b)
            return c;
    }
    return null;
}

// String value as slice (null iff missing/non-string; empty string is
// a non-null empty slice). Aliases jtmp: dup before next reset if kept.
const(char)[] jstr(JsonNode* n)
{
    if (!n || (n.type & 0xFF) != JsonString || !n.value_string)
        return null;
    auto sl = strlen(n.value_string);
    return n.value_string[0 .. sl];
}

long jint(JsonNode* n, long def = 0)
{
    if (!n || (n.type & 0xFF) != JsonNumber)
        return def;
    return n.value_integer;
}

bool jbool(JsonNode* n, bool def = false)
{
    if (!n)
        return def;
    if ((n.type & 0xFF) == JsonTrue)
        return true;
    if ((n.type & 0xFF) == JsonFalse)
        return false;
    return def;
}

version (Windows) // CRT low-level I/O (module scope, so they get C linkage)
{
    extern (C) int _dup(int) nothrow @nogc;
    extern (C) int _dup2(int, int) nothrow @nogc;
    extern (C) int _setmode(int, int) nothrow @nogc;
    extern (C) FILE* _fdopen(int, const(char)*) nothrow @nogc;
}

// The protocol stream. `lspTakeStdout` moves it to a private descriptor, so
// nothing else in the process can write into it.
__gshared FILE* lspOut;

// Once, before serving: keep a private copy of fd 1 for the protocol and point
// fd 1 at stderr. dmd prints to stdout in places (`pragma(msg)`, debug and
// diagnostic paths); all of that now lands in the log instead of corrupting
// the framing. Done once at startup, so no handle changes under anyone later
// (swapping fd 1 around each analysis is not stable on Windows).
void lspTakeStdout()
{
    fflush(stdout);
    version (Posix)
    {
        import core.sys.posix.unistd : dup, dup2;
        import core.sys.posix.stdio : fdopen;

        auto fd = dup(1);
        lspOut = fd >= 0 ? fdopen(fd, "wb") : null;
        if (lspOut !is null)
            dup2(2, 1);
    }
    else version (Windows)
    {
        enum _O_BINARY = 0x8000;

        auto fd = _dup(1);
        if (fd >= 0)
        {
            _setmode(fd, _O_BINARY); // no CRLF translation in the framing
            lspOut = _fdopen(fd, "wb");
        }
        if (lspOut !is null)
            _dup2(2, 1);
    }
    if (lspOut is null)
        lspOut = stdout; // keep serving; stray output is then possible
}

void lspWrite(string jsonBody)
{
    import core.stdc.stdio : fprintf;

    auto o = lspOut !is null ? lspOut : stdout;
    fprintf(o, "Content-Length: %u\r\n\r\n", cast(uint)jsonBody.length);
    if (jsonBody.length)
        fwrite(jsonBody.ptr, 1, jsonBody.length, o);
    fflush(o);
}

void lspRespond(string idJson, string resultJson)
{
    lspWrite(`{"jsonrpc":"2.0","id":` ~ idJson ~ `,"result":` ~ resultJson ~ `}`);
}

void lspRespondError(string idJson, int code, string message)
{
    auto js = jmake();
    auto e = js.create_object();
    js.add_number_to_object(e, "code", cast(double)code);
    js.add_string_to_object(e, "message", zstr(message));
    lspWrite(`{"jsonrpc":"2.0","id":` ~ idJson ~ `,"error":` ~ printJsonStr(e) ~ `}`);
}

void lspNotify(string method, string paramsJson)
{
    lspWrite(`{"jsonrpc":"2.0","method":` ~ method ~ `,"params":` ~ paramsJson ~ `}`);
}

// ---------- URI helpers ----------
string uriToPath(const(char)[] uri)
{
    string u = uri.idup;
    static immutable string pre = "file://";
    if (u.length > pre.length && u[0 .. pre.length] == pre)
        u = u[pre.length .. $];
    // percent-decode minimal (%XX)
    char[] out_;
    out_.reserve(u.length);
    for (size_t i = 0; i < u.length; i++)
    {
        if (u[i] == '%' && i + 2 < u.length && isHex(u[i + 1]) && isHex(u[i + 2]))
        {
            out_ ~= cast(char)(hexVal(u[i + 1]) * 16 + hexVal(u[i + 2]));
            i += 2;
        }
        else
            out_ ~= u[i];
    }
    version (Windows)
    {
        // A `file:///C:/...` URI decodes to a leading slash before the drive;
        // Windows expects `C:/...`.
        if (out_.length >= 3 && out_[0] == '/' &&
            ((out_[1] >= 'A' && out_[1] <= 'Z') ||
             (out_[1] >= 'a' && out_[1] <= 'z')) && out_[2] == ':')
            out_ = out_[1 .. $];
    }
    return out_.idup;
}

private bool isHex(char c) pure nothrow @nogc @safe
{
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

private uint hexVal(char c) pure nothrow @nogc @safe
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    return c - 'A' + 10;
}

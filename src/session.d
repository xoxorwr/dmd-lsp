module session;

// Per-open-document cache + dirty set. Struct-only.
// Doc text is malloc-managed and replaced on update, so memory does not
// grow with edits (the region GC never frees, so docs must live outside it).

import arena;
import core.stdc.stdlib : malloc, free;
import core.stdc.string : memcpy;

struct DocEntry
{
    string path; // malloc
    string text; // malloc
}

struct Session
{
    Arena perm; // analysis output pinned across requests (lint hits)
    DocEntry[] docs; // GC array (cold path only)
}

private string dmallocCopy(const(char)[] s)
{
    if (!s.length)
        return "";
    auto p = cast(char*)malloc(s.length);
    if (!p)
        return null;
    memcpy(p, s.ptr, s.length);
    return cast(string)(p[0 .. s.length]);
}

DocEntry* sessionFind(ref Session s, const(char)[] path)
{
    foreach (ref d; s.docs)
        if (d.path == path)
            return &d;
    return null;
}

DocEntry* sessionOpen(ref Session s, const(char)[] path, const(char)[] text)
{
    auto d = sessionFind(s, path);
    if (!d)
    {
        s.docs ~= DocEntry.init;
        d = &s.docs[$ - 1];
        d.path = dmallocCopy(path);
    }
    // Copy BEFORE freeing: callers (e.g. didSave without a `text` field)
    // may pass the session's own current buffer, which would otherwise be
    // read after free and handed to dmd as garbage.
    auto newText = dmallocCopy(text);
    if (d.text.ptr)
        free(cast(void*)d.text.ptr);
    d.text = newText;
    return sessionFind(s, path);
}

DocEntry* sessionUpdate(ref Session s, const(char)[] path, const(char)[] text)
{
    return sessionOpen(s, path, text);
}

// LSP ChangeRange positions are 0-based lines with the character offset in
// UTF-16 code units; our stored text is UTF-8 bytes. Convert to a byte
// offset (clamped). Needed because some clients send incremental changes
// even though we advertise full sync.
size_t lspPosToOffset(const(char)[] text, uint line, uint character)
{
    size_t i = 0;
    uint l = 0;
    while (i < text.length && l < line)
    {
        if (text[i] == '\n')
            l++;
        i++;
    }
    if (i >= text.length)
        return text.length;
    uint u = 0;
    while (i < text.length && text[i] != '\n' && u < character)
    {
        ubyte c = cast(ubyte)text[i];
        size_t adv = 1;
        uint units = 1;
        if (c < 0x80)
            adv = 1;
        else if ((c & 0xE0) == 0xC0)
            adv = 2;
        else if ((c & 0xF0) == 0xE0)
            adv = 3;
        else if ((c & 0xF8) == 0xF0)
        {
            adv = 4;
            units = 2; // supplementary plane: two UTF-16 code units
        }
        i += adv;
        u += units;
    }
    return i > text.length ? text.length : i;
}

// Apply one LSP content change to `base` and return the new full text.
// A change with no `range` replaces the whole document (full sync).
string applyChange(const(char)[] base, const(char)[] insert,
    bool hasRange, uint sl, uint sc, uint el, uint ec)
{
    if (!hasRange)
        return insert.idup;
    if (base is null)
        base = "";
    size_t so = lspPosToOffset(base, sl, sc);
    size_t eo = lspPosToOffset(base, el, ec);
    if (eo < so)
        eo = so;
    return (base[0 .. so] ~ insert ~ base[eo .. $]).idup;
}

void sessionClose(ref Session s, const(char)[] path)
{
    foreach (i, ref d; s.docs)
    {
        if (d.path == path)
        {
            if (d.path.ptr)
                free(cast(void*)d.path.ptr);
            if (d.text.ptr)
                free(cast(void*)d.text.ptr);
            s.docs[i] = s.docs[$ - 1];
            s.docs.length--;
            return;
        }
    }
}

// Read file from disk when not open in editor (didSave / --check path).
// Raw C stdio: no phobos, no diagnostic side effects.
string sessionReadDisk(const(char)[] path)
{
    import core.stdc.stdio : fopen, fread, fseek, ftell, rewind, fclose, SEEK_END;

    if (path.length + 1 >= 4096)
        return null;
    char[4096] zpath;
    zpath[0 .. path.length] = path[];
    zpath[path.length] = 0;
    auto f = fopen(zpath.ptr, "rb");
    if (!f)
        return null;
    scope (exit)
        fclose(f);
    if (fseek(f, 0, SEEK_END) != 0)
        return null;
    long n = ftell(f);
    if (n < 0)
        return null;
    rewind(f);
    char[] buf = new char[cast(size_t)n];
    size_t got = 0;
    while (got < buf.length)
    {
        auto k = fread(buf.ptr + got, 1, buf.length - got, f);
        if (k == 0)
            break;
        got += k;
    }
    return cast(string)buf[0 .. got];
}

bool fileExists(const(char)[] p)
{
    version (Posix)
    {
        import core.sys.posix.unistd : access, F_OK;

        if (p.length + 1 >= 4096)
            return false;
        char[4096] buf;
        buf[0 .. p.length] = p[];
        buf[p.length] = 0;
        return access(buf.ptr, F_OK) == 0;
    }
    else
        return true;
}

ulong fnv1a64(const(ubyte)[] data, ulong h = 14695981039346656037UL) pure nothrow @nogc
{
    foreach (b; data)
    {
        h ^= b;
        h *= 1099511628211UL;
    }
    return h;
}

bool hashFileDisk(const(char)[] path, out ulong h)
{
    import core.stdc.stdio : fopen, fread, fclose;

    if (path.length + 1 >= 4096)
        return false;
    char[4096] zpath;
    zpath[0 .. path.length] = path[];
    zpath[path.length] = 0;
    auto f = fopen(zpath.ptr, "rb");
    if (!f)
        return false;
    scope (exit)
        fclose(f);
    h = 14695981039346656037UL;
    ubyte[65536] chunk = void;
    for (;;)
    {
        auto k = fread(chunk.ptr, 1, chunk.length, f);
        if (k == 0)
            break;
        h = fnv1a64(chunk[0 .. k], h);
    }
    return true;
}

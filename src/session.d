module session;

// Per-open-document cache + dirty set. Struct-only.
// Doc text is malloc-managed and replaced on update, so memory does not
// grow with edits and never lives on a dmd memory level.

import core.stdc.stdlib : malloc, free;
import core.stdc.string : memcpy;

struct DocEntry
{
    string path; // malloc
    string text; // malloc
}

struct Session
{
    DocEntry[] docs; // GC array (cold path only)
}

private string dmallocCopy(const(char)[] s)
{
    // Empty text still gets its own block: the buffer is freed on the next
    // update, which must never free a literal.
    auto p = cast(char*)malloc(s.length ? s.length : 1);
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

// Make `text`, a malloc'd buffer (see applyChangeMalloc), the document's text.
// The session owns it from here.
DocEntry* sessionAdopt(ref Session s, const(char)[] path, char[] text)
{
    auto d = sessionFind(s, path);
    if (!d)
    {
        s.docs ~= DocEntry.init;
        d = &s.docs[$ - 1];
        d.path = dmallocCopy(path);
    }
    if (d.text.ptr)
        free(cast(void*)d.text.ptr);
    d.text = cast(string) text;
    return d;
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

// Apply one LSP content change to `base` and return the new full text, in a
// malloc'd buffer (null when out of memory). A change with no `range`
// replaces the whole document (full sync). An edit of a large document costs
// one copy and leaves no GC garbage: level-0 collections are expensive (they
// scan the dmd heaps), and GC copies per keystroke of a big file set them off.
char[] applyChangeMalloc(const(char)[] base, const(char)[] insert,
    bool hasRange, uint sl, uint sc, uint el, uint ec)
{
    const(char)[] head, tail;
    if (hasRange && base.length)
    {
        size_t so = lspPosToOffset(base, sl, sc);
        size_t eo = lspPosToOffset(base, el, ec);
        if (eo < so)
            eo = so;
        head = base[0 .. so];
        tail = base[eo .. $];
    }
    immutable n = head.length + insert.length + tail.length;
    auto p = cast(char*)malloc(n ? n : 1);
    if (!p)
        return null;
    memcpy(p, head.ptr, head.length);
    memcpy(p + head.length, insert.ptr, insert.length);
    memcpy(p + head.length + insert.length, tail.ptr, tail.length);
    return p[0 .. n];
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
    {
        import core.sys.windows.winbase : GetFileAttributesA;
        import core.sys.windows.winnt : DWORD, INVALID_FILE_ATTRIBUTES;

        if (p.length + 1 >= 4096)
            return false;
        char[4096] buf;
        buf[0 .. p.length] = p[];
        buf[p.length] = 0;
        // Like access(F_OK): files and directories both exist. Import paths
        // are directories, so excluding them here hides valid configs.
        return GetFileAttributesA(buf.ptr) != INVALID_FILE_ATTRIBUTES;
    }
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

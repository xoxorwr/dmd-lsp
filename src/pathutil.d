module pathutil;

// Pure path helpers shared by the dls.json config loader and the watched-file
// handler. No dmd/OS dependencies, so they carry their own unittests (run by
// `make unittest` without pulling the vendored frontend's tests).

// Directory portion of `path` including its trailing separator, or null when
// there is no separator (`a.d`, a bare filename).
string dirOf(const(char)[] path)
{
    size_t i = path.length;
    while (i > 0 && path[i - 1] != '/')
        i--;
    return i > 0 ? path[0 .. i].idup : null;
}

unittest
{
    assert(dirOf("/a/b/c.d") == "/a/b/");
    assert(dirOf("/a") == "/");
    assert(dirOf("a.d") is null);
    assert(dirOf("") is null);
}

// True when the basename is exactly `dls.json` (config, not D).
bool isDlsJson(const(char)[] path)
{
    size_t i = path.length;
    while (i > 0 && path[i - 1] != '/')
        i--;
    return path[i .. $] == "dls.json";
}

// True for a `.d` / `.di` source path.
bool isDFilePath(const(char)[] path)
{
    if (path.length >= 2 && path[$ - 1] == 'd' && path[$ - 2] == '.')
        return true; // .d
    if (path.length >= 3 && path[$ - 1] == 'i' && path[$ - 2] == 'd' &&
        path[$ - 3] == '.')
        return true; // .di
    return false;
}

unittest
{
    assert(isDFilePath("/a/b.d"));
    assert(isDFilePath("x.di"));
    assert(!isDFilePath("x.dc"));
    assert(!isDFilePath("dls.json"));
    assert(!isDFilePath("d"));
}

unittest
{
    assert(isDlsJson("/a/b/dls.json"));
    assert(isDlsJson("dls.json"));
    assert(!isDlsJson("/a/b/foo.d"));
    assert(!isDlsJson("dls.jsonc"));
    assert(!isDlsJson(""));
}

// Resolve a dls.json path: absolute stays, relative joins the file's dir.
string resolveCfgPath(const(char)[] root, const(char)[] p)
{
    if (!p.length)
        return null;
    if (p[0] == '/' || (p.length > 2 && p[1] == ':'))
        return p.idup;
    string r = root.idup;
    while (r.length && r[$ - 1] == '/')
        r = r[0 .. $ - 1];
    return r ~ "/" ~ p.idup;
}

unittest
{
    assert(resolveCfgPath("/r", "src/") == "/r/src/");
    assert(resolveCfgPath("/r/", "src/") == "/r/src/");
    assert(resolveCfgPath("/r", "/abs") == "/abs");
    assert(resolveCfgPath("/r", "C:/abs") == "C:/abs");
    assert(resolveCfgPath("/r", "") is null);
}

// Directory equality ignoring separator style and trailing slashes: both
// operands normally come from `uriToPath` (`/` everywhere), but the legacy
// `rootPath` fallback is a `\` path on Windows. Case-insensitive there too,
// since the filesystem is.
bool sameDir(const(char)[] a, const(char)[] b)
{
    bool isSep(char c) { return c == '/' || c == '\\'; }
    while (a.length && isSep(a[$ - 1]))
        a = a[0 .. $ - 1];
    while (b.length && isSep(b[$ - 1]))
        b = b[0 .. $ - 1];
    if (a.length != b.length)
        return false;
    foreach (i; 0 .. a.length)
    {
        char ca = isSep(a[i]) ? '/' : a[i];
        char cb = isSep(b[i]) ? '/' : b[i];
        version (Windows)
        {
            if (ca >= 'A' && ca <= 'Z') ca = cast(char)(ca + 32);
            if (cb >= 'A' && cb <= 'Z') cb = cast(char)(cb + 32);
        }
        if (ca != cb)
            return false;
    }
    return true;
}

unittest
{
    assert(sameDir("/a/b", "/a/b"));
    assert(sameDir("/a/b/", "/a/b"));
    assert(sameDir("/a/b", "/a/b/"));
    assert(sameDir("/a\\b", "/a/b")); // separator style (Windows rootPath)
    assert(!sameDir("/a/b", "/a/c"));
    assert(!sameDir("/a/b", "/a/b/c"));
    assert(!sameDir("/a/bc", "/a/b"));
    assert(!sameDir("", "/a"));
    assert(!sameDir("/a", ""));
    version (Windows)
        assert(sameDir("C:\\Foo\\", "c:/foo")); // separators + case
}

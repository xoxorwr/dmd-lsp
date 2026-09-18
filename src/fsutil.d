module fsutil;

// Recursive discovery of D source files for the workspace symbol index.
// No phobos: POSIX `dirent` + Windows `FindFirstFile`.

// `.d` / `.di` by extension.
private bool isDFile(const(char)[] name) pure nothrow @nogc @safe
{
    if (name.length >= 2 && name[$ - 1] == 'd' && name[$ - 2] == '.')
        return true; // .d
    return name.length >= 3 && name[$ - 1] == 'i' && name[$ - 2] == 'd' &&
        name[$ - 3] == '.'; // .di
}

// Skip dot-files and known big/irrelevant directories.
private bool skipName(const(char)[] n) pure nothrow @nogc @safe
{
    if (!n.length || n[0] == '.')
        return true;
    static immutable string[] skip = ["node_modules", "dub.selections.json"];
    foreach (s; skip)
        if (n == s)
            return true;
    return false;
}

string[] findDFiles(const(char)[] root, int maxDepth = 48)
{
    string[] out_;
    if (!root.length)
        return out_;
    string r = root.idup;
    while (r.length && (r[$ - 1] == '/' || r[$ - 1] == '\\'))
        r = r[0 .. $ - 1];
    version (Posix)
        walkPosix(r, 0, maxDepth, out_);
    else version (Windows)
        walkWindows(r, 0, maxDepth, out_);
    return out_;
}

version (Posix)
{
    private void walkPosix(string dir, int depth, int maxDepth,
        ref string[] out_)
    {
        import core.sys.posix.dirent : opendir, readdir, closedir;
        import core.sys.posix.sys.stat : stat, stat_t, S_ISDIR;
        import core.stdc.string : strlen;

        if (depth > maxDepth)
            return;
        char[4096] dbuf;
        if (dir.length + 1 >= dbuf.length)
            return;
        dbuf[0 .. dir.length] = dir[];
        dbuf[dir.length] = 0;
        auto d = opendir(dbuf.ptr);
        if (!d)
            return;
        scope (exit) closedir(d);
        while (true)
        {
            auto e = readdir(d);
            if (!e)
                break;
            auto nm = e.d_name[0 .. strlen(cast(const(char)*) e.d_name.ptr)];
            if (nm == "." || nm == ".." || skipName(nm))
                continue;
            char[4096] pbuf;
            size_t n = dir.length + 1 + nm.length;
            if (n + 1 >= pbuf.length)
                continue;
            pbuf[0 .. dir.length] = dir[];
            pbuf[dir.length] = '/';
            pbuf[dir.length + 1 .. n] = nm[];
            pbuf[n] = 0;
            stat_t st;
            if (stat(pbuf.ptr, &st) != 0)
                continue;
            string full = pbuf[0 .. n].idup;
            if (S_ISDIR(st.st_mode))
                walkPosix(full, depth + 1, maxDepth, out_);
            else if (isDFile(nm))
                out_ ~= full;
        }
    }
}
else version (Windows)
{
    private void walkWindows(string dir, int depth, int maxDepth,
        ref string[] out_)
    {
        import core.sys.windows.winbase;
        import core.sys.windows.windef;

        if (depth > maxDepth)
            return;
        char[4096] pat;
        size_t n = dir.length + 2;
        if (n + 1 >= pat.length)
            return;
        pat[0 .. dir.length] = dir[];
        pat[dir.length] = '\\';
        pat[dir.length + 1] = '*';
        pat[n] = 0;

        WIN32_FIND_DATAA fd;
        auto h = FindFirstFileA(pat.ptr, &fd);
        if (h == INVALID_HANDLE_VALUE)
            return;
        scope (exit) FindClose(h);
        do
        {
            auto nm = fd.cFileName[0 .. strlen(cast(const(char)*) fd.cFileName.ptr)];
            if (nm == "." || nm == ".." || skipName(nm))
                continue;
            char[4096] pbuf;
            size_t m = dir.length + 1 + nm.length;
            if (m + 1 >= pbuf.length)
                continue;
            pbuf[0 .. dir.length] = dir[];
            pbuf[dir.length] = '\\';
            pbuf[dir.length + 1 .. m] = nm[];
            pbuf[m] = 0;
            string full = pbuf[0 .. m].idup;
            if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)
                walkWindows(full, depth + 1, maxDepth, out_);
            else if (isDFile(nm))
                out_ ~= full;
        }
        while (FindNextFileA(h, &fd));
    }
}

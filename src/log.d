module log;

// printf-style server log line: stderr, which VS Code shows in the "dmd-lsp"
// output channel. `pragma(printf)` gives compile-time format-string checking.
// The linker name is prefixed so it can't clash with libm's `log`.
pragma(mangle, "dmd_lsp_log")
extern (C) pragma(printf)
void log(const(char)* fmt, ...)
{
    import core.stdc.stdio : fputs, fputc, vfprintf, fflush, stderr;
    import core.stdc.stdarg : va_list, va_start, va_end;

    fputs("dmd-lsp: ", stderr);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    // A redirected stderr may be fully buffered (Windows CRT): a line that
    // only shows up at exit is useless for diagnosing a hang.
    fflush(stderr);
}

// `debug:` lines, only when DMD_LSP_DEBUG is set: one per module the server
// parses or analyses (engine.d), far too many for the default log.
bool debugLogEnabled() nothrow @nogc
{
    import core.stdc.stdlib : getenv;

    __gshared int enabled = -1;
    if (enabled < 0)
        enabled = getenv("DMD_LSP_DEBUG") !is null;
    return enabled != 0;
}

pragma(mangle, "dmd_lsp_log_debug")
extern (C) pragma(printf)
void logDebug(const(char)* fmt, ...)
{
    import core.stdc.stdio : fputs, fputc, vfprintf, fflush, stderr;
    import core.stdc.stdarg : va_list, va_start, va_end;

    if (!debugLogEnabled())
        return;
    fputs("dmd-lsp: debug: ", stderr);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    fflush(stderr);
}

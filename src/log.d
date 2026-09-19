module log;

// printf-style server log line: stderr, which VS Code shows in the "dmd-lsp"
// output channel. `pragma(printf)` gives compile-time format-string checking.
// The linker name is prefixed so it can't clash with libm's `log`.
pragma(mangle, "dmd_lsp_log")
extern (C) pragma(printf)
void log(const(char)* fmt, ...)
{
    import core.stdc.stdio : fputs, fputc, vfprintf, stderr;
    import core.stdc.stdarg : va_list, va_start, va_end;

    fputs("dmd-lsp: ", stderr);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

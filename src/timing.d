module timing;

// Opt-in timing traces to stderr, enabled with `DMD_LSP_TIMING=1`. stderr is
// never part of the LSP framing, so this cannot corrupt the protocol. Used to
// attribute cost (discovery, parse, semantic, index, wide references) without
// ad-hoc harnesses.

import core.time : MonoTime;
import core.stdc.stdio : fprintf, stderr;
import core.stdc.stdlib : getenv;

private int g_enabled = -1;

bool timingEnabled() nothrow @nogc
{
    if (g_enabled < 0)
        g_enabled = getenv("DMD_LSP_TIMING") !is null ? 1 : 0;
    return g_enabled == 1;
}

ulong nowMs() nothrow @nogc
{
    // `ticksPerSecond` is platform-defined (nanoseconds on Linux), not fixed
    // hectonanoseconds; derive ticks-per-ms instead of assuming 10_000.
    return cast(ulong)(MonoTime.currTime.ticks / (MonoTime.ticksPerSecond / 1_000));
}

void traceMs(const(char)[] phase, ulong ms, const(char)[] extra = null) nothrow
{
    if (!timingEnabled())
        return;
    fprintf(stderr, "dmd-lsp[timing] %.*s: %llu ms",
        cast(int) phase.length, phase.ptr, cast(ulong) ms);
    if (extra.length)
        fprintf(stderr, " (%.*s)", cast(int) extra.length, extra.ptr);
    fprintf(stderr, "\n");
}

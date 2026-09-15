module lexutil;

// Minimal D identifier scanner for lint use-sets.
// Struct-only. Skips comments/strings/numbers. Bails (returns false)
// on token-string / heredoc / quote-delimited forms we don't model,
// so callers can conservatively skip the file instead of misreporting.

struct IdentHit
{
    const(char)[] name;
    uint line = 0;
    uint col = 0;
}

struct ScanOut
{
    IdentHit* hits = null; // Arena array
    size_t nhits = 0;
    size_t capHits = 0;
    bool ok = true;
    bool riskyMixin = false;   // mixin("...") string form seen
    bool riskyTraits = false;  // __traits(allMembers|derivedMembers|getMember|compiles)
}

private bool isIdentStart(char c) pure nothrow @nogc @safe
{
    return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

private bool isIdentChar(char c) pure nothrow @nogc @safe
{
    return isIdentStart(c) || (c >= '0' && c <= '9') || c == '$';
}

private void pushHit(ref ScanOut o, Arena* a, const(char)[] name, uint line, uint col)
{
    if (o.nhits == o.capHits)
    {
        size_t ncap = o.capHits == 0 ? 256 : o.capHits * 2;
        IdentHit* p = cast(IdentHit*)a.alloc(ncap * IdentHit.sizeof);
        if (!p)
        {
            o.ok = false;
            return;
        }
        for (size_t i = 0; i < o.nhits; i++)
            p[i] = o.hits[i];
        o.hits = p;
        o.capHits = ncap;
    }
    o.hits[o.nhits++] = IdentHit(name, line, col);
}

import arena;

// Scan identifiers in `src` (full text or sub-range starting at baseLine).
// Lines reported as baseLine + internal offset.
bool scanIdents(Arena* arena, const(char)[] src, uint baseLine, ref ScanOut out_)
{
    out_.ok = true;
    size_t i = 0;
    uint line = baseLine;
    uint col = 1;
    const n = src.length;

    // helper to peek identifier ahead without emitting (for mixin/__traits checks)
    while (i < n)
    {
        char c = src[i];
        // newlines
        if (c == '\n')
        {
            i++;
            line++;
            col = 1;
            continue;
        }
        if (c == '\r')
        {
            i++;
            continue;
        }
        // whitespace
        if (c == ' ' || c == '\t' || c == '\v' || c == '\f')
        {
            i++;
            col++;
            continue;
        }
        // line comment
        if (c == '/' && i + 1 < n && src[i + 1] == '/')
        {
            i += 2;
            col += 2;
            while (i < n && src[i] != '\n')
            {
                i++;
                col++;
            }
            continue;
        }
        // block /+ +/ nested comment
        if (c == '/' && i + 1 < n && src[i + 1] == '+')
        {
            i += 2;
            col += 2;
            uint depth = 1;
            while (i < n && depth > 0)
            {
                if (src[i] == '\n')
                {
                    i++;
                    line++;
                    col = 1;
                    continue;
                }
                if (src[i] == '/' && i + 1 < n && src[i + 1] == '+')
                {
                    depth++;
                    i += 2;
                    col += 2;
                    continue;
                }
                if (src[i] == '+' && i + 1 < n && src[i + 1] == '/')
                {
                    depth--;
                    i += 2;
                    col += 2;
                    continue;
                }
                i++;
                col++;
            }
            continue;
        }
        // block /* */ comment
        if (c == '/' && i + 1 < n && src[i + 1] == '*')
        {
            i += 2;
            col += 2;
            while (i + 1 < n && !(src[i] == '*' && src[i + 1] == '/'))
            {
                if (src[i] == '\n')
                {
                    line++;
                    col = 1;
                }
                else
                    col++;
                i++;
            }
            if (i + 1 < n)
            {
                i += 2;
                col += 2;
            }
            continue;
        }
        // wysiwyg r"..." and alternate W"..."? only r prefix: r"..."
        if ((c == 'r' || c == 'R') && i + 1 < n && src[i + 1] == '"')
        {
            i += 2;
            col += 2;
            while (i < n && src[i] != '"')
            {
                if (src[i] == '\n')
                {
                    line++;
                    col = 1;
                }
                else
                    col++;
                i++;
            }
            if (i < n)
            {
                i++;
                col++;
            }
            // trailing postfix like "c"? skip one ident char run? keep simple:
            continue;
        }
        // plain double-quoted string
        if (c == '"')
        {
            i++;
            col++;
            while (i < n && src[i] != '"' && src[i] != '\n')
            {
                if (src[i] == '\\' && i + 1 < n)
                {
                    i += 2;
                    col += 2;
                    continue;
                }
                i++;
                col++;
            }
            if (i < n && src[i] == '"')
            {
                i++;
                col++;
            }
            // string postfix (c,w,d)? skip attached ident chars
            while (i < n && (src[i] == 'c' || src[i] == 'w' || src[i] == 'd') && !isIdentChar(i + 1 < n ? src[i + 1] : 0))
                break; // only single-char postfix; keep simple: do nothing
            continue;
        }
        // char literal
        if (c == '\'')
        {
            i++;
            col++;
            if (i < n && src[i] == '\\')
            {
                i += 2;
                col += 2;
            }
            while (i < n && src[i] != '\'' && src[i] != '\n')
            {
                i++;
                col++;
            }
            if (i < n && src[i] == '\'')
            {
                i++;
                col++;
            }
            continue;
        }
        // backtick strings / token strings / delimited strings: bail (conservative)
        if (c == '`')
        {
            out_.ok = false;
            return false;
        }
        // numbers (incl. hexfloat): skip alnum run + dots
        if (c >= '0' && c <= '9')
        {
            while (i < n && (isIdentChar(src[i]) || src[i] == '.' || src[i] == '_'))
            {
                i++;
                col++;
            }
            continue;
        }
        // identifiers / keywords
        if (isIdentStart(c))
        {
            size_t s = i;
            uint scol = col;
            while (i < n && isIdentChar(src[i]))
            {
                i++;
                col++;
            }
            auto name = src[s .. i];
            // token-string / delimited-string opener: q{ q( q[ q< q" -> bail
            if ((name == "q" || name == "Q") && i < n &&
                (src[i] == '{' || src[i] == '(' || src[i] == '[' || src[i] == '<' || src[i] == '"'))
            {
                out_.ok = false;
                return false;
            }
            pushHit(out_, arena, name, line, scol);
            if (!out_.ok)
                return false;
            // mixin("...") risk: mixin keyword followed by ( " — check ahead
            if (name == "mixin")
            {
                size_t j = i;
                while (j < n && (src[j] == ' ' || src[j] == '\t' || src[j] == '\n' || src[j] == '\r'))
                    j++;
                if (j < n && src[j] == '(')
                {
                    j++;
                    while (j < n && (src[j] == ' ' || src[j] == '\t' || src[j] == '\n' || src[j] == '\r'))
                        j++;
                    if (j < n && (src[j] == '"' || src[j] == '`' ||
                            ((src[j] == 'q' || src[j] == 'Q') && j + 1 < n)))
                        out_.riskyMixin = true;
                }
            }
            if (name == "__traits")
            {
                size_t j = i;
                while (j < n && (src[j] == ' ' || src[j] == '\t' || src[j] == '\n' || src[j] == '\r'))
                    j++;
                if (j < n && src[j] == '(')
                {
                    j++;
                    while (j < n && (src[j] == ' ' || src[j] == '\t' || src[j] == '\n' || src[j] == '\r'))
                        j++;
                    size_t k = j;
                    while (k < n && isIdentChar(src[k]))
                        k++;
                    auto inner = src[j .. k];
                    if (inner == "allMembers" || inner == "derivedMembers" ||
                        inner == "getMember" || inner == "compiles")
                        out_.riskyTraits = true;
                }
            }
            continue;
        }
        // anything else
        i++;
        col++;
    }
    return true;
}

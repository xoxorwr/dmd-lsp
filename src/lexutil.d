module lexutil;

// Identifier scanner for lint use-sets, backed by dmd's own `Lexer` (comments,
// strings, token strings and raw strings are the frontend's problem, not ours).
// `ok` is false only if the arena could not grow.

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
    out_.hits = null;
    out_.nhits = 0;
    out_.capHits = 0;
    out_.ok = true;
    out_.riskyMixin = false;
    out_.riskyTraits = false;
    if (!src.length)
        return true;

    // Use dmd's own lexer: it handles comments, strings, token strings and
    // raw strings correctly, so no tolerant hand-rolled scanner is needed.
    import dmd.lexer : Lexer;
    import dmd.tokens : Token, TOK;
    import dmd.globals : global;

    auto buf = src.dup ~ '\0';
    scope lex = new Lexer(null, cast(char*) buf.ptr, 0, buf.length - 1,
        false, false, global.errorSinkNull, &global.compileEnv);

    // Tokenise once so the risky-construct checks can look ahead.
    Token[] toks;
    while (true)
    {
        Token t;
        lex.scan(&t);
        if (t.value == TOK.endOfFile)
            break;
        toks ~= t;
    }

    foreach (i, t; toks)
    {
        if (t.value == TOK.identifier)
        {
            uint line = baseLine + t.loc.linnum() - 1;
            pushHit(out_, arena, t.ident.toString(), line, t.loc.charnum());
            if (!out_.ok)
                return false;
        }
        else if (t.value == TOK.mixin_ && i + 2 < toks.length &&
            toks[i + 1].value == TOK.leftParenthesis &&
            toks[i + 2].value == TOK.string_)
            out_.riskyMixin = true; // mixin("...") string mixin
        else if (t.value == TOK.traits && i + 2 < toks.length &&
            toks[i + 1].value == TOK.leftParenthesis &&
            toks[i + 2].value == TOK.identifier)
        {
            auto tr = toks[i + 2].ident.toString();
            if (tr == "allMembers" || tr == "derivedMembers" ||
                tr == "getMember" || tr == "compiles")
                out_.riskyTraits = true;
        }
    }
    return true;
}

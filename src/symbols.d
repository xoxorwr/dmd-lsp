module symbols;

// textDocument/documentSymbol: walk the semantic module's declaration tree
// into an LSP-shaped hierarchy. Traversal uses dmd's own semantic transitive
// visitor (a class, like the compiler's other visitors) rather than a
// hand-rolled declaration walk.

import dmd.dmodule : Module;
import dmd.dsymbol : Dsymbol;
import dmd.arraytypes : Dsymbols;
import dmd.declaration : VarDeclaration, AliasDeclaration;
import dmd.denum : EnumDeclaration, EnumMember;
import dmd.dtemplate : TemplateDeclaration;
import dmd.func : FuncDeclaration, CtorDeclaration, DtorDeclaration,
    PostBlitDeclaration, StaticCtorDeclaration, StaticDtorDeclaration,
    InvariantDeclaration, UnitTestDeclaration;
import dmd.dstruct : StructDeclaration, UnionDeclaration;
import dmd.dclass : ClassDeclaration, InterfaceDeclaration;
import dmd.visitor : SemanticTimeTransitiveVisitor;
import dmd.dsymbolsem : toAlias;
import dmd.expression : Expression, CallExp, StructLiteralExp;
import dmd.identifier : Identifier;
import dmd.astenums : STC, TY;

// LSP SymbolKind subset (see the LSP spec).
enum : ubyte
{
    SymModule = 2,
    SymClass = 5,
    SymMethod = 6,
    SymField = 8,
    SymConstructor = 9,
    SymEnum = 10,
    SymInterface = 11,
    SymFunction = 12,
    SymVariable = 13,
    SymEnumMember = 22,
    SymStruct = 23,
}

// One outline entry. All positions are 0-based (LSP-ready).
struct DocSymbol
{
    const(char)[] name;
    const(char)[] detail;
    ubyte kind;
    uint line, col;       // range start
    uint endLine, endCol; // range end
    uint selLine, selCol, selEndLine, selEndCol; // selectionRange
    DocSymbol[] children;
}

// ---------- inlay hints ----------

// One hint at a 0-based position. `auto` type hints are `paddingLeft`; call
// parameter-name hints are `paddingRight`.
struct InlayHint
{
    uint line;
    uint col;
    const(char)[] label;
    bool paddingLeft;
    bool paddingRight;
}

// True when showing a parameter name for `arg` would be noise: the argument is
// a literal, or an identifier that already spells the parameter name.
private bool obviousArg(Expression arg, Identifier pname)
{
    if (!arg)
        return true;
    if (arg.isIdentifierExp())
        return pname && arg.isIdentifierExp().ident is pname;
    if (arg.isVarExp())
    {
        auto v = arg.isVarExp().var;
        return v && v.ident && pname && v.ident is pname;
    }
    if (arg.isIntegerExp() || arg.isRealExp() || arg.isStringExp() ||
        arg.isNullExp())
        return true;
    return false;
}

private bool wordAt(const(char)[] hay, const(char)[] word, size_t i)
{
    if (i + word.length > hay.length)
        return false;
    foreach (k; 0 .. word.length)
        if (hay[i + k] != word[k])
            return false;
    if (i > 0 && identChar(hay[i - 1]))
        return false;
    if (i + word.length < hay.length && identChar(hay[i + word.length]))
        return false;
    return true;
}

private bool containsWord(const(char)[] hay, const(char)[] word)
{
    if (!word.length || hay.length < word.length)
        return false;
    foreach (i; 0 .. hay.length - word.length + 1)
        if (wordAt(hay, word, i))
            return true;
    return false;
}

extern (C++) final class HintWalker : SemanticTimeTransitiveVisitor
{
    alias visit = SemanticTimeTransitiveVisitor.visit;

    const(char)[] text;
    size_t[] lineStarts;
    InlayHint[] out_;

    // `auto` is cleared from `storage_class` during semantic, so detect it from
    // the source text before the declared name.
    private bool isAutoDecl(VarDeclaration d)
    {
        if (!d.ident)
            return false;
        uint line = d.loc.linnum();
        uint col = d.loc.charnum();
        if (line == 0 || line > lineStarts.length || col == 0)
            return false;
        size_t s = lineStarts[line - 1];
        size_t e = line < lineStarts.length ? lineStarts[line] : text.length;
        size_t nameOff = s + col - 1;
        if (nameOff > e)
            return false;
        return containsWord(text[s .. nameOff], "auto");
    }

    // `auto` declaration: show the resolved type after the name.
    override void visit(VarDeclaration d)
    {
        if (isAutoDecl(d))
            if (d.type && d.type.ty != TY.Terror)
            {
                import core.stdc.string : strlen;
                const(char)* tp = d.type.toChars();
                if (tp)
                {
                    auto name = d.ident.toString();
                    out_ ~= InlayHint(d.loc.linnum() - 1,
                        cast(uint) d.loc.charnum() + cast(uint) name.length - 1,
                        cast(const(char)[]) (": " ~ tp[0 .. strlen(tp)]),
                        true, false);
                }
            }
        super.visit(d);
    }

    // Start of a call argument. `CallExp` keeps its callee (`e1`), whose loc is
    // the expression's start. `StructLiteralExp` does not keep the type-use loc
    // (its `loc` is the `(`), so lex the line up to the `(` with dmd's Lexer.
    private void argStart(Expression arg, out uint line, out uint col)
    {
        if (auto ce = arg.isCallExp())
            if (ce.e1)
            {
                line = ce.e1.loc.linnum() - 1;
                col = cast(uint) ce.e1.loc.charnum() - 1;
                return;
            }
        if (auto sl = arg.isStructLiteralExp())
        {
            structLitStart(sl, line, col);
            return;
        }
        line = arg.loc.linnum() - 1;
        col = cast(uint) arg.loc.charnum() - 1;
    }

    private void structLitStart(StructLiteralExp e, out uint line, out uint col)
    {
        line = e.loc.linnum() - 1;
        col = cast(uint) e.loc.charnum() - 1;
        if (line >= lineStarts.length)
            return;
        size_t ls = lineStarts[line];
        size_t le = line + 1 < lineStarts.length ? lineStarts[line + 1]
            : text.length;
        while (le > ls && (text[le - 1] == '\n' || text[le - 1] == '\r'))
            le--;
        auto lt = text[ls .. le];
        size_t off = col; // 0-based offset of `(` within the line
        if (off >= lt.length || lt[off] != '(')
            return;

        import dmd.lexer : Lexer;
        import dmd.tokens : Token, TOK;
        import dmd.globals : global;
        auto buf = lt.dup ~ '\0';
        scope lex = new Lexer(null, cast(char*) buf.ptr, 0, buf.length - 1,
            false, false, global.errorSinkNull, &global.compileEnv);
        Token[] toks;
        while (true)
        {
            Token tok;
            lex.scan(&tok);
            if (tok.value == TOK.endOfFile)
                break;
            if (cast(size_t)(tok.loc.charnum() - 1) >= off)
                break;
            toks ~= tok;
        }
        // Walk back over the type name: identifiers, dots, `!`, and balanced
        // template-argument parens (`Box!int()`, `pkg.Box!(int)()`). A `(` at
        // depth 0 is the enclosing call, so stop there.
        size_t i = toks.length;
        size_t start = off;
        int depth = 0;
        while (i > 0)
        {
            auto tok = toks[i - 1];
            uint to = cast(uint)(tok.loc.charnum() - 1);
            if (tok.value == TOK.rightParenthesis)
                depth++;
            else if (tok.value == TOK.leftParenthesis)
            {
                if (depth == 0)
                    break;
                depth--;
            }
            else if (depth == 0)
            {
                // A name-like token (identifier or keyword, e.g. `int` in
                // `Box!int`); punctuation ends the type name.
                if (to >= lt.length)
                    break;
                char c0 = lt[to];
                if (!(identChar(c0) || c0 == '!' || c0 == '.'))
                    break;
            }
            i--;
            start = to;
        }
        if (start < off)
            col = cast(uint) start;
    }

    // Call argument names, when not obvious.
    override void visit(CallExp e)
    {
        auto fd = e.f ? e.f.isFuncDeclaration() : null;
        auto tf = fd && fd.type ? fd.type.isTypeFunction() : null;
        if (tf && tf.parameterList.parameters && e.arguments)
        {
            size_t nparam = (*tf.parameterList.parameters).length;
            size_t startArg = e.isUfcsRewrite ? 1 : 0; // skip the receiver
            foreach (i, arg; *e.arguments)
            {
                if (i < startArg || !arg)
                    continue;
                if (i >= nparam)
                    break;
                auto p = (*tf.parameterList.parameters)[i];
                if (!p || !p.ident || obviousArg(arg, p.ident))
                    continue;
                uint aline, acol;
                argStart(arg, aline, acol);
                out_ ~= InlayHint(aline, acol,
                    cast(const(char)[]) (p.ident.toString() ~ ":"),
                    false, true);
            }
        }
        super.visit(e);
    }
}

InlayHint[] inlayHints(Module mod, const(char)[] text)
{
    if (!mod || !mod.members)
        return null;
    size_t[] starts = [0];
    foreach (i, c; text)
        if (c == '\n')
            starts ~= i + 1;
    scope HintWalker w = new HintWalker();
    w.text = text;
    w.lineStarts = starts;
    foreach (i; 0 .. (*mod.members).length)
        (*mod.members)[i].accept(w);
    return w.out_;
}

// ---------- folding ----------

struct FoldRange
{
    uint startLine; // 0-based
    uint endLine;   // 0-based
    const(char)[] kind; // "region" | "comment" | "imports"
}

// Lexer-based folding: brace pairs, plus runs of `//` comments and `import`
// lines. Lexing (not semantic) is enough, so this is cheap and works on
// broken/unanalyzable buffers.
FoldRange[] foldingRanges(const(char)[] text)
{
    FoldRange[] out_;
    if (!text.length)
        return out_;
    {
        import dmd.lexer : Lexer;
        import dmd.tokens : Token, TOK;
        import dmd.globals : global;
        auto buf = text.dup ~ '\0';
        scope lex = new Lexer(null, cast(char*) buf.ptr, 0, buf.length - 1,
            false, false, global.errorSinkNull, &global.compileEnv);
        uint[] open;
        while (true)
        {
            Token tok;
            lex.scan(&tok);
            if (tok.value == TOK.endOfFile)
                break;
            if (tok.value == TOK.leftCurly)
                open ~= tok.loc.linnum();
            else if (tok.value == TOK.rightCurly && open.length)
            {
                uint ol = open[$ - 1];
                open.length--;
                uint cl = tok.loc.linnum();
                if (cl > ol)
                    out_ ~= FoldRange(ol - 1, cl - 1, "region");
            }
        }
    }

    // Consecutive `//` comment lines and `import` lines.
    uint nlines = 1;
    foreach (c; text)
        if (c == '\n')
            nlines++;
    int runKind = 0;
    uint runStart = 0;
    size_t i = 0;
    foreach (lineNo; 0 .. nlines)
    {
        size_t e = i;
        while (e < text.length && text[e] != '\n')
            e++;
        auto ln = text[i .. e];
        size_t s = 0;
        while (s < ln.length && (ln[s] == ' ' || ln[s] == '\t'))
            s++;
        auto t = ln[s .. $];
        int kind = 0;
        if (t.length >= 2 && t[0] == '/' && t[1] == '/')
            kind = 1;
        else if (t.length >= 6 && t[0 .. 6] == "import")
        {
            if (t.length == 6 || !identChar(t[6]))
                kind = 2;
        }
        if (kind != runKind)
        {
            if (runKind != 0 && lineNo - runStart >= 2)
                out_ ~= FoldRange(runStart, lineNo - 1,
                    runKind == 1 ? "comment" : "imports");
            runKind = kind;
            runStart = lineNo;
        }
        if (e >= text.length)
            break;
        i = e + 1;
    }
    if (runKind != 0 && nlines - runStart >= 2)
        out_ ~= FoldRange(runStart, nlines - 1,
            runKind == 1 ? "comment" : "imports");
    return out_;
}

private bool identChar(char c) pure nothrow @nogc @safe
{
    return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9');
}

// Top-level symbols of a module, in source order, with nested members.
// `text` is used only to point `selectionRange` at the identifier (dmd's
// aggregate `loc` is the declaration keyword, not the name).
DocSymbol[] documentSymbols(Module mod, const(char)[] text)
{
    if (!mod || !mod.members)
        return null;
    scope DocWalker w = new DocWalker();
    w.text = text;
    w.inAggregate = false;
    foreach (i; 0 .. (*mod.members).length)
        (*mod.members)[i].accept(w);
    return w.out_;
}

// Emits an outline node for each declaration. Aggregate/template/enum members
// are visited with a fresh child walker; function bodies are not descended
// (locals are not outline material).
extern (C++) final class DocWalker : SemanticTimeTransitiveVisitor
{
    alias visit = SemanticTimeTransitiveVisitor.visit;

    const(char)[] text;
    bool inAggregate;
    DocSymbol[] out_;

    private void emit(Dsymbol s, Dsymbols* members, bool childIsMember)
    {
        if (!s.ident)
        {
            // Anonymous aggregate/enum: descend in place, emit no node.
            if (members)
            {
                bool saved = inAggregate;
                inAggregate = true;
                foreach (m; *members)
                    if (m)
                        m.accept(this);
                inAggregate = saved;
            }
            return;
        }
        const(char)[] nm = s.ident.toString();
        if (nm == "__dmd_lsp_ph")
            return; // our own completion placeholder
        if (s.isCtorDeclaration())
            nm = "this"; // dmd names constructors `__ctor`
        if (s.loc.linnum() < 1)
            return; // synthetic symbol with no source span

        DocSymbol d;
        d.name = nm;
        d.kind = lspSymbolKind(s, inAggregate);
        d.detail = detailOf(s);
        d.line = s.loc.linnum() - 1;
        d.col = s.loc.charnum() - 1;
        d.selLine = d.line;
        d.selCol = identCol(text, d.line, d.col, nm);
        d.selEndLine = d.line;
        d.selEndCol = d.selCol + cast(uint) nm.length;
        d.endLine = d.selEndLine;
        d.endCol = d.selEndCol;

        if (members)
        {
            scope DocWalker sub = new DocWalker();
            sub.text = text;
            sub.inAggregate = childIsMember;
            foreach (m; *members)
                if (m)
                    m.accept(sub);
            d.children = sub.out_;
        }

        // A function's `endloc` is the closing brace: the best range end.
        if (auto fd = s.isFuncDeclaration())
            if (fd.endloc.linnum() > 0)
            {
                d.endLine = fd.endloc.linnum() - 1;
                d.endCol = fd.endloc.charnum() - 1;
            }
        if (d.children.length)
        {
            auto last = d.children[$ - 1];
            if (last.endLine > d.endLine ||
                (last.endLine == d.endLine && last.endCol > d.endCol))
            {
                d.endLine = last.endLine;
                d.endCol = last.endCol;
            }
        }
        out_ ~= d;
    }

    override void visit(StructDeclaration s) { emit(s, s.members, true); }
    override void visit(UnionDeclaration s) { emit(s, s.members, true); }
    override void visit(ClassDeclaration s) { emit(s, s.members, true); }
    override void visit(InterfaceDeclaration s) { emit(s, s.members, true); }
    override void visit(EnumDeclaration s) { emit(s, s.members, true); }
    override void visit(TemplateDeclaration s) { emit(s, s.members, false); }
    override void visit(VarDeclaration s) { emit(s, null, false); }
    override void visit(AliasDeclaration s) { emit(s, null, false); }

    // The transitive visitor dispatches these more-specific function kinds to
    // its own walkers, so each must be handled here to appear in the outline.
    override void visit(FuncDeclaration s) { emit(s, null, false); }
    override void visit(CtorDeclaration s) { emit(s, null, false); }
    override void visit(DtorDeclaration s) { emit(s, null, false); }
    override void visit(PostBlitDeclaration s) { emit(s, null, false); }
    override void visit(StaticCtorDeclaration s) { emit(s, null, false); }
    override void visit(StaticDtorDeclaration s) { emit(s, null, false); }
    override void visit(InvariantDeclaration s) { emit(s, null, false); }
    override void visit(UnitTestDeclaration s) { emit(s, null, false); }
    override void visit(EnumMember s) { emit(s, null, false); }
}

// Column (0-based) of `name` as a whole word on `line0`, search starting at
// `col0`. dmd's aggregate `loc` is the keyword (`struct Foo`), so the name is
// the first word match; for funcs/vars `loc` is already the name.
private uint identCol(const(char)[] text, uint line0, uint col0,
    const(char)[] name)
{
    if (!name.length)
        return col0;
    size_t i = 0;
    uint l = 0;
    while (i < text.length && l < line0)
    {
        if (text[i] == '\n')
            l++;
        i++;
    }
    size_t ls = i;
    while (i < text.length && text[i] != '\n')
        i++;
    auto lt = text[ls .. i];
    size_t s = col0;
    if (s > lt.length)
        s = lt.length;
    if (name.length <= lt.length)
        foreach (k; s .. lt.length - name.length + 1)
        {
            if (lt[k .. k + name.length] != name)
                continue;
            if (k > 0 && isIdentChar(lt[k - 1]))
                continue;
            if (k + name.length < lt.length && isIdentChar(lt[k + name.length]))
                continue;
            return cast(uint) k;
        }
    return col0;
}

private bool isIdentChar(char c) pure nothrow @nogc @safe
{
    return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9');
}

private ubyte lspSymbolKind(Dsymbol s, bool inAggregate)
{
    if (s.isInterfaceDeclaration())
        return SymInterface;
    if (s.isClassDeclaration()) // also true for interfaces (checked above)
        return SymClass;
    if (s.isStructDeclaration()) // struct or union
        return SymStruct;
    if (s.isEnumDeclaration())
        return SymEnum;
    if (s.isEnumMember())
        return SymEnumMember;
    if (auto fd = s.isFuncDeclaration())
        return fd.isCtorDeclaration() ? SymConstructor
            : (inAggregate ? SymMethod : SymFunction);
    if (s.isVarDeclaration())
        return inAggregate ? SymField : SymVariable;
    if (auto al = s.isAliasDeclaration())
    {
        auto t = al.toAlias();
        if (t && t !is s)
            return lspSymbolKind(t, inAggregate);
        return inAggregate ? SymField : SymVariable;
    }
    if (auto td = s.isTemplateDeclaration())
    {
        // Function templates present as functions; aggregate templates as their
        // single member's kind.
        if (td.onemember)
            return lspSymbolKind(td.onemember, inAggregate);
        return inAggregate ? SymMethod : SymFunction;
    }
    return SymVariable;
}

// Cheap `detail`: the declared type for variables, else null.
private const(char)[] detailOf(Dsymbol s)
{
    import core.stdc.string : strlen;
    if (auto vd = s.isVarDeclaration())
    {
        if (vd.type)
        {
            const(char)* p = vd.type.toChars();
            if (p)
                return p[0 .. strlen(p)];
        }
    }
    return null;
}

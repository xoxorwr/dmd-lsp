module semantic;

// Semantic highlighting (LSP textDocument/semanticTokens/full).
//
// A lexical scan collects identifier occurrences (comments, strings and
// numbers skipped); each is resolved through the same symbol machinery as
// goto-definition/hover (complete.resolveSymbolsBatch, which hoists module
// flattening and per-function locals). The resolved Dsymbol decides the LSP
// token type. Non-identifier syntax is left to the editor's TextMate grammar;
// semantic tokens only refine what it cannot know.
//
// Struct-only. Runs on the post-semantic universe.

import complete : SynMod, resolveSymbolsBatch, appendScopeSubs;

import dmd.dmodule : Module;
import dmd.dsymbol : Dsymbol;
import dmd.declaration : VarDeclaration;
import dmd.func : FuncDeclaration;
import dmd.aggregate : AggregateDeclaration;
import dmd.dclass : ClassDeclaration, InterfaceDeclaration;
import dmd.dstruct : StructDeclaration;
import dmd.denum : EnumDeclaration, EnumMember;
import dmd.dtemplate : TemplateDeclaration, TemplateParameter;
import dmd.mtype : Type, TypePointer, TypeFunction, TypeDelegate;
import dmd.typesem : toBasetype, nextOf;
import dmd.astenums : STC;

import core.stdc.string : strlen;

// LSP legend, standard order. Wire values in SemTok are indices into these.
enum tokenTypes = [
    "namespace", "type", "class", "enum", "interface", "struct",
    "typeParameter", "parameter", "variable", "property", "enumMember",
    "event", "function", "method", "macro", "keyword", "modifier",
    "comment", "string", "number", "regexp", "operator", "decorator",
];

enum tokenModifiers = [
    "declaration", "definition", "readonly", "static", "deprecated",
    "abstract", "async", "modification", "documentation", "defaultLibrary",
];

private enum ubyte TT_NAMESPACE = 0;
private enum ubyte TT_TYPE = 1;
private enum ubyte TT_CLASS = 2;
private enum ubyte TT_ENUM = 3;
private enum ubyte TT_INTERFACE = 4;
private enum ubyte TT_STRUCT = 5;
private enum ubyte TT_TYPE_PARAMETER = 6;
private enum ubyte TT_PARAMETER = 7;
private enum ubyte TT_VARIABLE = 8;
private enum ubyte TT_PROPERTY = 9;
private enum ubyte TT_ENUM_MEMBER = 10;
private enum ubyte TT_FUNCTION = 12;
private enum ubyte TT_METHOD = 13;
private enum ubyte TT_MODIFIER = 16;
private enum ubyte TT_DECORATOR = 22;
private enum ubyte HINT_NONE = 0xFF;

private enum uint TM_STATIC = 1u << 3;          // tokenModifiers[3]
private enum uint TM_DEPRECATED = 1u << 4;      // tokenModifiers[4]
private enum uint TM_DEFAULT_LIBRARY = 1u << 9; // tokenModifiers[9]

struct SemTok
{
    uint line = 0; // 0-based
    uint col = 0;  // 0-based
    uint len = 0;
    ubyte type = 0;
    uint mods = 0;
}

// ---------- identifier scan ----------

private struct IdentHit
{
    const(char)[] name; // aliases the source text
    uint line = 0;      // 1-based
    uint col = 0;       // 1-based
    ubyte hint = HINT_NONE; // lexical token type when resolution can't help
    bool called = false;    // followed by `(` — a call site
}

// Lexical context for identifier hints. `Stmt` tracks import/module
// statements so their path segments can be marked `namespace` without
// resolution (the resolver has no use for a bare `std.conv` path).
private enum ScanStmt : ubyte
{
    none,
    modulePath,
    importPath,
    selective,
}

private bool isBuiltinAttr(const(char)[] w) pure nothrow @nogc @safe
{
    static immutable string[] attrs = [
        "safe", "trusted", "system", "nogc", "property", "disable", "live",
    ];
    foreach (a; attrs)
        if (a == w)
            return true;
    return false;
}

private void scanIdents(const(char)[] src, ref IdentHit[] hits)
{
    if (!src.length)
        return;

    // dmd's own lexer handles comments, strings (r""/`/x""/q{}), keywords and
    // numbers; the scanner only classifies identifier tokens.
    import dmd.lexer : Lexer;
    import dmd.tokens : Token, TOK;
    import dmd.globals : global;

    auto buf = src.dup ~ '\0';
    scope lex = new Lexer(null, cast(char*) buf.ptr, 0, buf.length - 1,
        false, false, global.errorSinkNull, &global.compileEnv);

    Token[] toks;
    while (true)
    {
        Token t;
        lex.scan(&t);
        if (t.value == TOK.endOfFile)
            break;
        toks ~= t;
    }

    ScanStmt stmt = ScanStmt.none;
    foreach (i, t; toks)
    {
        switch (t.value)
        {
        case TOK.semicolon:
        case TOK.leftCurly:
        case TOK.rightCurly:
            stmt = ScanStmt.none;
            continue;
        case TOK.colon:
            if (stmt == ScanStmt.importPath)
                stmt = ScanStmt.selective;
            continue;
        case TOK.module_:
            stmt = ScanStmt.modulePath;
            continue;
        case TOK.import_:
            // `import("file")` is the string-import expression, not a path.
            stmt = (i + 1 < toks.length &&
                toks[i + 1].value == TOK.leftParenthesis)
                ? ScanStmt.none : ScanStmt.importPath;
            continue;
        case TOK.identifier:
            break;
        default:
            continue;
        }

        auto name = t.ident.toString();
        ubyte hint = HINT_NONE;
        if (stmt == ScanStmt.modulePath || stmt == ScanStmt.importPath)
            hint = TT_NAMESPACE; // module paths need no resolution
        else if (i > 0 && toks[i - 1].value == TOK.at)
            hint = isBuiltinAttr(name) ? TT_MODIFIER : TT_DECORATOR;
        bool called = false;
        if (hint == HINT_NONE)
            called = i + 1 < toks.length &&
                toks[i + 1].value == TOK.leftParenthesis;
        hits ~= IdentHit(name, t.loc.linnum(), t.loc.charnum(), hint, called);
    }
}

// ---------- classification ----------

// A variable whose type is a function pointer or delegate: calling it reads
// as a function/method, not a property/variable.
private bool isCallableType(Type t)
{
    if (!t)
        return false;
    auto tb = t.toBasetype();
    if (tb.isTypeFunction() || tb.isTypeDelegate())
        return true;
    if (auto tp = tb.isTypePointer())
    {
        auto n = tp.nextOf();
        if (n && n.toBasetype().isTypeFunction())
            return true;
    }
    return false;
}

private bool classify(Dsymbol s, const(char)[] curFile, ref ubyte type,
    ref uint mods, bool called = false)
{
    uint m = 0;
    if (s.isDeprecated())
        m |= TM_DEPRECATED;
    if (auto f = s.loc.filename())
    {
        auto fn = f[0 .. strlen(f)];
        if (curFile.length && fn != curFile)
            m |= TM_DEFAULT_LIBRARY; // declared in another file
    }

    if (s.isEnumMember())
    {
        type = TT_ENUM_MEMBER;
        mods = m;
        return true;
    }
    if (auto vd = s.isVarDeclaration())
    {
        if ((vd.storage_class & STC.static_) != 0)
            m |= TM_STATIC;
        if (called && isCallableType(vd.type))
            type = vd.isField() || vd.isMember() !is null ? TT_METHOD : TT_FUNCTION;
        else if (vd.isParameter())
            type = TT_PARAMETER;
        else if (vd.isField())
            type = TT_PROPERTY;
        else
            type = TT_VARIABLE;
        mods = m;
        return true;
    }
    if (auto fd = s.isFuncDeclaration())
    {
        if ((fd.storage_class & STC.static_) != 0)
            m |= TM_STATIC;
        if (fd.isMember() !is null || fd.isCtorDeclaration() !is null ||
            fd.isDtorDeclaration() !is null)
            type = TT_METHOD;
        else
            type = TT_FUNCTION;
        mods = m;
        return true;
    }
    if (s.isEnumDeclaration())
    {
        type = TT_ENUM;
        mods = m;
        return true;
    }
    if (auto cd = s.isClassDeclaration())
    {
        type = cd.isInterfaceDeclaration() ? TT_INTERFACE : TT_CLASS;
        mods = m;
        return true;
    }
    if (s.isStructDeclaration() || s.isAggregateDeclaration())
    {
        type = TT_STRUCT;
        mods = m;
        return true;
    }
    if (auto td = s.isTemplateDeclaration())
    {
        // A function template is a TemplateDeclaration, not a
        // FuncDeclaration, so test its member (or overload root) first;
        // otherwise `save`, `empty`, `popFront`, ... all render as types.
        auto fd = td.onemember ? td.onemember.isFuncDeclaration() : null;
        if (!fd && td.funcroot)
            fd = td.funcroot;
        if (fd)
        {
            if ((fd.storage_class & STC.static_) != 0)
                m |= TM_STATIC;
            if (fd.isMember() !is null || fd.isCtorDeclaration() !is null ||
                fd.isDtorDeclaration() !is null)
                type = TT_METHOD;
            else
                type = TT_FUNCTION;
        }
        else
            type = TT_TYPE;
        mods = m;
        return true;
    }
    if (s.isTemplateInstance() || s.isAliasDeclaration())
    {
        type = TT_TYPE;
        mods = m;
        return true;
    }
    if (s.isModule() || s.isImport() || s.isPackage() || s.isNspace())
    {
        type = TT_NAMESPACE;
        mods = m;
        return true;
    }
    return false;
}

// Line starts of the text `semanticTokens` is working on (see locIsName).
private __gshared size_t[] g_lineStarts;

// True when `text` at 1-based (line, col) spells `name`. O(1) to the line.
private bool locIsName(const(char)[] text, uint line, uint col,
    const(char)[] name)
{
    if (line < 1 || line > g_lineStarts.length)
        return false;
    size_t i = g_lineStarts[line - 1];
    for (uint c = 1; c < col && i < text.length && text[i] != '\n'; c++)
        i++;
    if (i + name.length > text.length)
        return false;
    return text[i .. i + name.length] == name;
}

// Emit a token for a declaration's name, when it lives in this document.
private void emitDecl(Dsymbol s, const(char)[] text, const(char)[] curFile,
    ref SemTok[] out_)
{
    if (!s.ident)
        return;
    auto f = s.loc.filename();
    if (!f)
        return;
    if (f[0 .. strlen(f)] != curFile)
        return; // declared elsewhere (imports, mixins)
    uint line = s.loc.linnum();
    uint col = s.loc.charnum();
    if (line == 0 || col == 0)
        return;
    auto name = s.ident.toString();
    // Synthetic names (`__ctor`, `__dtor`, ...) don't match the source; nor
    // do keyword-located nodes (`struct`, `enum`, `import`).
    if (!locIsName(text, line, col, name))
        return;
    ubyte tt;
    uint mods;
    if (!classify(s, curFile, tt, mods))
        return;
    out_ ~= SemTok(line - 1, col - 1, cast(uint)name.length, tt, mods);
}

// Template parameter names, so references to them (which the resolver
// cannot find — they are not members) classify as `typeParameter`.
private void collectTemplateParams(Dsymbol s, ref bool[const(char)[]] out_)
{
    if (!s)
        return;
    if (auto td = s.isTemplateDeclaration())
        if (td.parameters)
            foreach (i; 0 .. td.parameters.length)
            {
                auto p = (*td.parameters)[i];
                if (p && p.ident)
                    out_[p.ident.toString()] = true;
            }
    Dsymbol[] subs;
    appendScopeSubs(s, subs);
    foreach (m; subs)
        collectTemplateParams(m, out_);
}

private void emitTemplateParams(Dsymbol s, const(char)[] text,
    const(char)[] curFile, ref SemTok[] out_)
{
    auto td = s.isTemplateDeclaration();
    if (!td || !td.parameters)
        return;
    foreach (i; 0 .. td.parameters.length)
    {
        auto p = (*td.parameters)[i];
        if (!p || !p.ident)
            continue;
        auto f = p.loc.filename();
        if (!f || f[0 .. strlen(f)] != curFile)
            continue;
        uint ln = p.loc.linnum();
        uint cl = p.loc.charnum();
        if (ln == 0 || cl == 0)
            continue;
        auto nm = p.ident.toString();
        if (!locIsName(text, ln, cl, nm))
            continue;
        out_ ~= SemTok(ln - 1, cl - 1, cast(uint)nm.length, TT_TYPE_PARAMETER, 0);
    }
}

// Declarations the use-resolution pass cannot reach (aggregate fields,
// enum members, nested types): walk the symbol tree and emit their names.
private void declWalk(Dsymbol s, const(char)[] text, const(char)[] curFile,
    ref SemTok[] out_)
{
    if (!s)
        return;
    emitDecl(s, text, curFile, out_);
    emitTemplateParams(s, text, curFile, out_);
    Dsymbol[] subs;
    appendScopeSubs(s, subs);
    if (auto ed = s.isEnumDeclaration())
        if (ed.members)
            foreach (i; 0 .. (*ed.members).length)
                subs ~= (*ed.members)[i];
    foreach (m; subs)
        declWalk(m, text, curFile, out_);
}

private bool beforeTok(const ref SemTok a, const ref SemTok b) pure nothrow @nogc @safe
{
    if (a.line != b.line)
        return a.line < b.line;
    return a.col < b.col;
}

// The document's token occurrences, 0-based, in source order.
void semanticTokens(Module mod, const ref SynMod syn, const(char)[] text,
    ref SemTok[] out_)
{
    if (!mod || text.length == 0)
        return;
    g_lineStarts = [size_t(0)];
    foreach (i, c; text)
        if (c == '\n')
            g_lineStarts ~= i + 1;
    scope (exit)
        g_lineStarts = null;
    IdentHit[] ids;
    scanIdents(text, ids);

    const(char)[] curFile = mod.srcfile.toString();

    // Uses (scanner order) and declarations (tree order) each arrive sorted.
    SemTok[] uses;
    if (ids.length)
    {
        uint[] lines;
        uint[] cols;
        lines.reserve(ids.length);
        cols.reserve(ids.length);
        foreach (ref id; ids)
        {
            lines ~= id.line;
            cols ~= id.col;
        }

        Dsymbol[] syms;
        resolveSymbolsBatch(mod, syn, text, lines, cols, syms);

        // Names the pre-semantic snapshot saw as locals/params. A syntax
        // error collapses the function body (dmd replaces it with
        // ErrorStatement), so semantic slots vanish and resolution fails for
        // declarations inside the body. Fall back to the snapshot so the
        // real universe highlights the same locals the completion
        // placeholder's surviving body does — otherwise the token set would
        // depend on which universe is live, and flicker.
        bool[const(char)[]] synParams;
        bool[const(char)[]] synVars;
        foreach (ref fn; syn.funcs)
        {
            foreach (p; fn.params)
                if (p.length)
                    synParams[p] = true;
            foreach (ref v; fn.vars)
                if (v.name.length)
                    synVars[v.name] = true;
        }
        bool[const(char)[]] tmplParams;
        if (mod.members)
            foreach (i; 0 .. (*mod.members).length)
                collectTemplateParams((*mod.members)[i], tmplParams);

        foreach (i, ref id; ids)
        {
            ubyte tt;
            uint mods;
            if (id.hint != HINT_NONE)
                tt = id.hint; // lexical: import path / @-attribute
            else if (auto s = syms[i])
            {
                if (!classify(s, curFile, tt, mods, id.called))
                    continue;
            }
            else if (id.name in synParams)
                tt = TT_PARAMETER;
            else if (id.name in tmplParams)
                tt = TT_TYPE_PARAMETER;
            else if (id.name in synVars)
                tt = TT_VARIABLE;
            else
                continue;
            uses ~= SemTok(id.line - 1, id.col - 1, cast(uint)id.name.length, tt, mods);
        }
    }

    SemTok[] decls;
    if (mod.members)
        foreach (i; 0 .. (*mod.members).length)
            declWalk((*mod.members)[i], text, curFile, decls);

    // Linear merge; a declaration and the use at its own site collide, keep
    // the declaration's classification. Overlaps are dropped by position.
    out_.reserve(uses.length + decls.length);
    size_t i = 0;
    size_t j = 0;
    while (i < uses.length || j < decls.length)
    {
        SemTok t;
        if (i >= uses.length)
            t = decls[j++];
        else if (j >= decls.length)
            t = uses[i++];
        else if (beforeTok(uses[i], decls[j]))
            t = uses[i++];
        else
            t = decls[j++];
        if (out_.length && out_[$ - 1].line == t.line &&
            out_[$ - 1].col == t.col)
            continue;
        out_ ~= t;
    }
}

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
// Struct-only. Runs in the worker on the post-semantic universe.

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

private bool isIdentStart(char c) pure nothrow @nogc @safe
{
    return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

private bool isIdentChar(char c) pure nothrow @nogc @safe
{
    return isIdentStart(c) || (c >= '0' && c <= '9');
}

// Skip a quoted literal starting at `i`. raw = no backslash escapes
// (backtick strings and the r"..." / q"..." forms).
private void skipQuoted(const(char)[] src, ref size_t i, ref uint line,
    ref uint col, bool raw)
{
    char q = src[i];
    i++;
    col++;
    while (i < src.length && src[i] != q && src[i] != '\n')
    {
        if (!raw && src[i] == '\\' && i + 1 < src.length)
        {
            if (src[i + 1] == '\n')
            {
                i += 2;
                line++;
                col = 1;
                continue;
            }
            i += 2;
            col += 2;
            continue;
        }
        i++;
        col++;
    }
    if (i < src.length && src[i] == q)
    {
        i++;
        col++;
    }
}

// Skip a q{...} token string (balanced braces), `i` at the opening '{'.
private void skipTokenString(const(char)[] src, ref size_t i, ref uint line,
    ref uint col)
{
    int depth = 0;
    while (i < src.length)
    {
        char c = src[i];
        if (c == '\n')
        {
            i++;
            line++;
            col = 1;
            continue;
        }
        if (c == '{')
            depth++;
        else if (c == '}')
        {
            depth--;
            if (depth == 0)
            {
                i++;
                col++;
                return;
            }
        }
        i++;
        col++;
    }
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

// True when the identifier at `s` is preceded (modulo spaces) by `@`.
private bool precededByAt(const(char)[] src, size_t s) pure nothrow @nogc @safe
{
    while (s > 0 && (src[s - 1] == ' ' || src[s - 1] == '\t'))
        s--;
    return s > 0 && src[s - 1] == '@';
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
    size_t i = 0;
    uint line = 1;
    uint col = 1;
    const n = src.length;
    ScanStmt stmt = ScanStmt.none;
    while (i < n)
    {
        char c = src[i];
        if (c == ';' || c == '{' || c == '}')
        {
            stmt = ScanStmt.none;
            i++;
            col++;
            continue;
        }
        if (c == ':' && stmt == ScanStmt.importPath)
        {
            stmt = ScanStmt.selective;
            i++;
            col++;
            continue;
        }
        if (c == '\n')
        {
            i++;
            line++;
            col = 1;
            continue;
        }
        if (c == ' ' || c == '\t' || c == '\r' || c == '\v' || c == '\f')
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
        // nested /+ +/ comment
        if (c == '/' && i + 1 < n && src[i + 1] == '+')
        {
            i += 2;
            col += 2;
            int depth = 1;
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
        // /* */ comment
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
        // string / char / backtick literal
        if (c == '"' || c == '\'' || c == '`')
        {
            skipQuoted(src, i, line, col, c == '`');
            continue;
        }
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
            // String prefixes bind to the literal with no space: r".." x".."
            // q".." i".." and the q{..} token string. Don't report the prefix.
            if (name.length == 1 && i < n &&
                (name[0] == 'r' || name[0] == 'R' || name[0] == 'x' ||
                 name[0] == 'X' || name[0] == 'q' || name[0] == 'Q' ||
                 name[0] == 'i' || name[0] == 'I'))
            {
                if (src[i] == '{' && (name[0] == 'q' || name[0] == 'Q'))
                {
                    skipTokenString(src, i, line, col);
                    continue;
                }
                if (src[i] == '"')
                {
                    skipQuoted(src, i, line, col, true);
                    continue;
                }
            }
            if (name == "module")
                stmt = ScanStmt.modulePath;
            else if (name == "import")
            {
                size_t j = i;
                while (j < n && (src[j] == ' ' || src[j] == '\t'))
                    j++;
                // `import("file")` is the string-import expression.
                if (!(j < n && src[j] == '('))
                    stmt = ScanStmt.importPath;
            }
            if (!isKeyword(name))
            {
                ubyte hint = HINT_NONE;
                if (stmt == ScanStmt.modulePath || stmt == ScanStmt.importPath)
                    hint = TT_NAMESPACE;
                else if (precededByAt(src, s))
                    hint = isBuiltinAttr(name) ? TT_MODIFIER : TT_DECORATOR;
                bool called = false;
                if (hint == HINT_NONE)
                {
                    size_t j = i;
                    while (j < n && (src[j] == ' ' || src[j] == '\t'))
                        j++;
                    called = j < n && src[j] == '(';
                }
                hits ~= IdentHit(name, line, scol, hint, called);
            }
            continue;
        }
        // number literal (digits, hex, exponent, `_` separators)
        if (c >= '0' && c <= '9')
        {
            while (i < n && (isIdentChar(src[i]) || src[i] == '.'))
            {
                i++;
                col++;
            }
            continue;
        }
        i++;
        col++;
    }
}

private bool isKeyword(const(char)[] w) pure nothrow @nogc @safe
{
    static immutable string[] kw = [
        "abstract", "alias", "align", "asm", "assert", "auto", "body", "bool",
        "break", "byte", "case", "cast", "catch", "cdouble", "cent", "cfloat",
        "char", "class", "const", "continue", "creal", "dchar", "debug",
        "default", "delegate", "delete", "deprecated", "do", "double", "else",
        "enum", "export", "extern", "false", "final", "finally", "float",
        "for", "foreach", "foreach_reverse", "function", "goto", "idouble",
        "if", "ifloat", "immutable", "import", "in", "inout", "int",
        "interface", "invariant", "ireal", "is", "lazy", "long", "macro",
        "mixin", "module", "new", "nothrow", "null", "out", "override",
        "package", "pragma", "private", "protected", "public", "pure", "real",
        "ref", "return", "scope", "shared", "short", "static", "struct",
        "super", "switch", "synchronized", "template", "this", "throw", "true",
        "try", "typeid", "typeof", "ubyte", "ucent", "uint", "ulong", "union",
        "unittest", "ushort", "version", "void", "wchar", "while", "with",
        "__gshared", "__traits", "__vector", "__parameters",
    ];
    foreach (k; kw)
        if (k == w)
            return true;
    return false;
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

// True when the source at 1-based (line, col) spells `name`.
private bool locIsName(const(char)[] text, uint line, uint col,
    const(char)[] name)
{
    size_t i = 0;
    uint l = 1;
    while (i < text.length && l < line)
    {
        if (text[i] == '\n')
            l++;
        i++;
    }
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

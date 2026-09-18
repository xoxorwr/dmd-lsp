module symbols;

// textDocument/documentSymbol: walk the semantic module's declaration tree
// into an LSP-shaped hierarchy. Pure dmd reads (public `members`/`loc`), no
// frontend changes.

import dmd.dmodule : Module;
import dmd.dsymbol : Dsymbol;
import dmd.declaration : VarDeclaration;
import dmd.denum : EnumDeclaration;
import dmd.dtemplate : TemplateDeclaration;
import dmd.dsymbolsem : toAlias;
import complete : appendScopeSubs;

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

// Top-level symbols of a module, in source order, with nested members.
// `text` is used only to point `selectionRange` at the identifier (dmd's
// aggregate `loc` is the declaration keyword, not the name).
DocSymbol[] documentSymbols(Module mod, const(char)[] text)
{
    DocSymbol[] out_;
    if (!mod || !mod.members)
        return out_;
    Dsymbol[] members;
    foreach (i; 0 .. (*mod.members).length)
        members ~= (*mod.members)[i];
    collect(members, false, text, out_);
    return out_;
}

private void collect(Dsymbol[] members, bool inAggregate, const(char)[] text,
    ref DocSymbol[] out_)
{
    foreach (s; members)
    {
        if (!s)
            continue;
        if (s.isImport() || s.isModule())
            continue; // not outline material
        if (s.isAttribDeclaration())
        {
            // version/static if/private:... blocks: descend with the same
            // aggregate context so their members still nest correctly.
            Dsymbol[] subs;
            appendScopeSubs(s, subs);
            collect(subs, inAggregate, text, out_);
            continue;
        }
        if (!s.ident)
        {
            // Anonymous aggregate/enum: descend, emit no node.
            Dsymbol[] subs = childMembers(s);
            if (subs.length)
                collect(subs, true, text, out_);
            continue;
        }
        const(char)[] nm = s.ident.toString();
        if (nm == "__dmd_lsp_ph")
            continue; // our own completion placeholder
        if (s.isCtorDeclaration())
            nm = "this"; // dmd names constructors `__ctor`
        if (s.loc.linnum() < 1)
            continue; // synthetic symbol with no source span

        DocSymbol d;
        d.name = nm;
        d.kind = lspSymbolKind(s, inAggregate);
        d.detail = detailOf(s);
        d.line = s.loc.linnum() - 1;
        d.col = s.loc.charnum() - 1;
        d.selLine = d.line;
        d.selCol = identCol(text, d.line, d.col, nm);
        d.selEndLine = d.line;
        d.selEndCol = d.selCol + cast(uint)nm.length;
        d.endLine = d.selEndLine;
        d.endCol = d.selEndCol;

        bool childIsMember = s.isAggregateDeclaration() || s.isEnumDeclaration();
        DocSymbol[] kids;
        Dsymbol[] subs = childMembers(s);
        if (subs.length)
            collect(subs, childIsMember, text, kids);

        // A function's `endloc` is the closing brace: the best range end.
        if (auto fd = s.isFuncDeclaration())
            if (fd.endloc.linnum() > 0)
            {
                d.endLine = fd.endloc.linnum() - 1;
                d.endCol = fd.endloc.charnum() - 1;
            }
        if (kids.length)
        {
            auto last = kids[$ - 1];
            if (last.endLine > d.endLine ||
                (last.endLine == d.endLine && last.endCol > d.endCol))
            {
                d.endLine = last.endLine;
                d.endCol = last.endCol;
            }
        }
        d.children = kids;
        out_ ~= d;
    }
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
            return cast(uint)k;
        }
    return col0;
}

private bool isIdentChar(char c) pure nothrow @nogc @safe
{
    return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9');
}

// Children worth nesting under `s`: aggregate/template/namespace members via
// the shared attrib-expanding walker, plus enum members (which it does not know).
private Dsymbol[] childMembers(Dsymbol s)
{
    Dsymbol[] r;
    if (auto ed = s.isEnumDeclaration())
    {
        if (ed.members)
            foreach (i; 0 .. (*ed.members).length)
                r ~= (*ed.members)[i];
        return r;
    }
    appendScopeSubs(s, r);
    return r;
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

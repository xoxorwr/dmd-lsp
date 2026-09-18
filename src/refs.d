module refs;

// Cross-universe declaration identity for references/rename (PLAN.md Phase A).
//
// DMD's resolved AST is the source of truth. A `DeclKey` describes a
// declaration independently of the live pointer/universe it was resolved in,
// so a use resolved in one worker universe can be matched against a target
// resolved in another (importers analysed per module). The old
// pointer-and-ad-hoc-fold `sameTarget` is reproduced by `keyMatches`.
//
// Struct-only, no phobos.

import dmd.dsymbol : Dsymbol;
import dmd.dmodule : Module;
import dmd.declaration : Declaration;
import dmd.func : FuncDeclaration;
import dmd.dtemplate : TemplateDeclaration, TemplateInstance;
import dmd.identifier : Identifier;
import dmd.dsymbolsem : toAlias;
import core.stdc.string : strlen;

// Coarse declaration class. Two callables with the same name+scope form an
// overload group (references/rename operate on the name, not one overload).
enum DeclKind : ubyte
{
    other = 0,
    func,
    template_,
    variable,
    aggregate,
    enum_,
}

struct DeclKey
{
    string moduleFQN; // declaring module, e.g. "a.b"
    string parentFQN; // fully-qualified enclosing scope (module for top level)
    string name;      // identifier
    uint declLine;    // 1-based; disambiguates overloads/members
    DeclKind kind = DeclKind.other;
    bool valid;
}

private bool isCallable(DeclKind k) pure nothrow @nogc @safe
{
    return k == DeclKind.func || k == DeclKind.template_;
}

private DeclKind kindTag(Dsymbol d)
{
    import dmd.aggregate : AggregateDeclaration;
    import dmd.denum : EnumDeclaration;

    if (d.isFuncDeclaration())
        return DeclKind.func;
    if (d.isTemplateDeclaration())
        return DeclKind.template_;
    if (d.isVarDeclaration())
        return DeclKind.variable;
    if (d.isAggregateDeclaration())
        return DeclKind.aggregate;
    if (d.isEnumDeclaration())
        return DeclKind.enum_;
    return DeclKind.other;
}

private Module moduleOf(Dsymbol d)
{
    for (Dsymbol p = d; p; p = p.parent)
        if (auto m = p.isModule())
            return m;
    return null;
}

private string ptrToString(const(char)* p)
{
    if (!p)
        return null;
    return p[0 .. strlen(p)].idup;
}

// Fully-qualified name of a scope symbol, including its declaring module.
private string qualifiedName(Dsymbol d)
{
    string[] parts;
    for (Dsymbol p = d; p && !p.isModule(); p = p.parent)
        if (p.ident)
            parts ~= p.ident.toString().idup;
    auto mod = moduleOf(d);
    string s = mod ? ptrToString(mod.toPrettyChars()) : "";
    foreach_reverse (part; parts)
    {
        if (s.length)
            s ~= ".";
        s ~= part;
    }
    return s;
}

// Collapse instance/wrapper layers to the declaration a rename would target.
// Mirrors the folds the old `sameTarget` applied: template instances and
// instantiated members map back to their template, and a function that is a
// template's single same-named member stands in for the template itself.
private Dsymbol fold(Dsymbol d)
{
    foreach (_; 0 .. 8)
    {
        if (!d)
            return null;
        if (auto ti = d.isTemplateInstance())
        {
            if (!ti.tempdecl)
                return d;
            d = ti.tempdecl;
            continue;
        }
        if (auto ti = d.isInstantiated())
        {
            if (!ti.tempdecl)
                return d;
            d = ti.tempdecl;
            continue;
        }
        if (d.isFuncDeclaration() && d.parent &&
            d.parent.isTemplateDeclaration() && d.ident && d.parent.ident &&
            d.ident is d.parent.ident)
        {
            d = d.parent;
            continue;
        }
        break;
    }
    return d;
}

DeclKey declKey(Dsymbol d)
{
    DeclKey k;
    d = fold(d);
    if (!d)
        return k;
    auto mod = moduleOf(d);
    k.moduleFQN = mod ? ptrToString(mod.toPrettyChars()) : "";
    k.parentFQN = d.parent ? (d.parent.isModule()
        ? ptrToString(d.parent.toPrettyChars()) : qualifiedName(d.parent)) : "";
    k.name = d.ident ? d.ident.toString().idup : "";
    k.declLine = d.loc.linnum();
    k.kind = kindTag(d);
    k.valid = k.name.length != 0;
    return k;
}

// True when a use resolved to `a` and a target resolved to `b` denote the same
// renameable declaration. Callables sharing name+scope are one overload group.
bool keyMatches(DeclKey a, DeclKey b)
{
    if (!a.valid || !b.valid)
        return false;
    if (a.moduleFQN != b.moduleFQN)
        return false;
    if (a.name != b.name)
        return false;
    if (a.parentFQN != b.parentFQN)
        return false;
    if (isCallable(a.kind) && isCallable(b.kind))
        return true;
    return a.kind == b.kind && a.declLine == b.declLine;
}

// Same as `keyMatches(declKey(a), declKey(b))` but short-circuits pointer
// identity so the common single-universe case stays cheap.
bool sameTarget(Dsymbol a, Dsymbol b)
{
    if (!a || !b)
        return false;
    if (a is b)
        return true;
    return keyMatches(declKey(a), declKey(b));
}

// A declaration a rename can rewrite in place: has an identifier, a real
// source span, and a declaring module inside the workspace.
bool isRenameable(Dsymbol d)
{
    if (!d || !d.ident)
        return false;
    d = fold(d);
    if (!d || !d.ident || d.loc.linnum() < 1 || d.loc.charnum() < 1)
        return false;
    return moduleOf(d) !is null;
}

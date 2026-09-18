module references;

// textDocument/references: find uses of a declaration across the loaded
// closure. Matching is by resolved declaration identity (pointers in the live
// universe), so it is shadowing-correct. Aggregates/aliases walk via
// `appendScopeSubs`; bodies are walked statement-by-statement.

import dmd.dmodule : Module;
import dmd.dsymbol : Dsymbol;
import dmd.dimport : Import;
import dmd.declaration : Declaration, VarDeclaration;
import dmd.func : FuncDeclaration;
import dmd.aggregate : AggregateDeclaration;
import dmd.denum : EnumDeclaration;
import dmd.dtemplate : TemplateDeclaration, TemplateInstance;
import dmd.statement : Statement;
import dmd.expression : Expression;
import dmd.mtype : Type;
import dmd.init : Initializer;
import dmd.identifier : Identifier;
import dmd.location : Loc;
import dmd.dsymbolsem : toAlias;
import dmd.typesem : toBasetype;
import complete : appendScopeSubs;

struct RefLoc
{
    string file;
    uint line; // 1-based
    uint col;  // 1-based
    uint len;
}

// Uses of `target` reachable from `root`. Only modules that (transitively)
// import the target's declaring module can reference it, so the walk is
// narrowed to those plus the declaring module.
RefLoc[] findReferences(Module root, Dsymbol target, bool includeDeclaration)
{
    RefLoc[] out_;
    if (!root || !target)
        return out_;
    Module declMod = moduleOf(target);
    if (!declMod)
        declMod = root;

    Module[] closure = importClosure(root);
    // Reachable-by-import set: a module can see declMod when some import chain
    // leads to it. Fixpoint over the closure (small: one universe).
    bool[Module] canSee;
    canSee[declMod] = true;
    bool changed = true;
    while (changed)
    {
        changed = false;
        foreach (m; closure)
        {
            if (m in canSee)
                continue;
            if (importsAny(m, canSee))
            {
                canSee[m] = true;
                changed = true;
            }
        }
    }
    canSee[root] = true;

    foreach (m; closure)
        if (m in canSee)
            walkModule(m, target, includeDeclaration, out_);
    dedupe(out_);
    return out_;
}

// Same identifier can be reached twice (e.g. a call's callee via both the
// CallExp and its `e1`); keep one location per (file, line, col).
private void dedupe(ref RefLoc[] refs)
{
    bool[string] seen;
    size_t w = 0;
    foreach (r; refs)
    {
        auto k = r.file ~ "#" ~ udec(r.line) ~ ":" ~ udec(r.col);
        if (k in seen)
            continue;
        seen[k] = true;
        refs[w++] = r;
    }
    refs.length = w;
}

private string udec(uint v)
{
    char[12] b = void;
    size_t n = b.length;
    do
    {
        b[--n] = cast(char)('0' + v % 10);
        v /= 10;
    }
    while (v);
    return b[n .. $].idup;
}

private Module moduleOf(Dsymbol d)
{
    for (Dsymbol p = d; p; p = p.parent)
        if (auto m = p.isModule())
            return m;
    return null;
}

// Declaring module of a symbol.
Module symbolModule(Dsymbol d) => moduleOf(d);

// True for a symbol whose parent chain crosses a function (local/param), i.e.
// not something another module could reference.
bool isLocalDsymbol(Dsymbol d)
{
    for (Dsymbol p = d ? d.parent : null; p; p = p.parent)
        if (p.isFuncDeclaration())
            return true;
    return false;
}

private Module[] importClosure(Module root)
{
    Module[] out_;
    bool[Module] seen;
    Module[] stack = [root];
    seen[root] = true;
    while (stack.length)
    {
        auto m = stack[$ - 1];
        stack.length--;
        out_ ~= m;
        if (!m.members)
            continue;
        foreach (i; 0 .. (*m.members).length)
        {
            auto s = (*m.members)[i];
            auto imp = s.isImport();
            if (imp && imp.mod && !(imp.mod in seen))
            {
                seen[imp.mod] = true;
                stack ~= imp.mod;
            }
        }
    }
    return out_;
}

// True when `m` directly imports any module already in `set`.
private bool importsAny(Module m, bool[Module] set)
{
    if (!m.members)
        return false;
    foreach (i; 0 .. (*m.members).length)
    {
        auto imp = (*m.members)[i].isImport();
        if (imp && imp.mod && imp.mod in set)
            return true;
    }
    return false;
}

private void walkModule(Module m, Dsymbol target, bool includeDecl, ref RefLoc[] out_)
{
    if (!m.members)
        return;
    foreach (i; 0 .. (*m.members).length)
        walkDecl((*m.members)[i], target, includeDecl, out_);
}

private void walkDecl(Dsymbol d, Dsymbol target, bool includeDecl, ref RefLoc[] out_)
{
    if (!d)
        return;
    if (d.isImport())
        return;
    if (d.isAttribDeclaration())
    {
        Dsymbol[] subs;
        appendScopeSubs(d, subs);
        foreach (s; subs)
            walkDecl(s, target, includeDecl, out_);
        return;
    }
    if (includeDecl && d.ident && sameTarget(d, target))
        record(d.loc, d.ident, out_);

    if (auto ad = d.isAggregateDeclaration())
    {
        if (ad.members)
            foreach (i; 0 .. (*ad.members).length)
                walkDecl((*ad.members)[i], target, includeDecl, out_);
        return;
    }
    if (auto ed = d.isEnumDeclaration())
    {
        if (ed.members)
            foreach (i; 0 .. (*ed.members).length)
                walkDecl((*ed.members)[i], target, includeDecl, out_);
        return;
    }
    if (auto td = d.isTemplateDeclaration())
    {
        if (td.members)
            foreach (i; 0 .. (*td.members).length)
                walkDecl((*td.members)[i], target, includeDecl, out_);
        return;
    }
    if (auto fd = d.isFuncDeclaration())
    {
        if (fd.parameters)
            foreach (p; *fd.parameters)
            {
                if (!p)
                    continue;
                if (includeDecl && p.ident && sameTarget(p, target))
                    record(p.loc, p.ident, out_);
                if (p.type) // parameter default values
                    walkInit(p._init, target, out_);
            }
        if (fd.fbody)
            walkStmt(fd.fbody, target, out_);
        return;
    }
    if (auto vd = d.isVarDeclaration())
    {
        walkInit(vd._init, target, out_);
        return;
    }
}

private void walkInit(Initializer init, Dsymbol target, ref RefLoc[] out_)
{
    if (!init)
        return;
    if (auto ei = init.isExpInitializer())
        if (ei.exp)
            walkExpr(ei.exp, target, out_);
}

private void walkStmt(Statement s, Dsymbol target, ref RefLoc[] out_)
{
    if (!s)
        return;
    if (auto es = s.isExpStatement())
    {
        if (es.exp)
        {
            if (auto de = es.exp.isDeclarationExp())
                walkDecl(de.declaration, target, true, out_);
            else
                walkExpr(es.exp, target, out_);
        }
        return;
    }
    if (auto cs = s.isCompoundStatement())
    {
        foreach (st; cs.statements)
            walkStmt(st, target, out_);
        return;
    }
    if (auto ss = s.isScopeStatement())
    {
        walkStmt(ss.statement, target, out_);
        return;
    }
    if (auto is_ = s.isIfStatement())
    {
        walkExpr(is_.condition, target, out_);
        if (is_.ifbody)
            walkStmt(is_.ifbody, target, out_);
        if (is_.elsebody)
            walkStmt(is_.elsebody, target, out_);
        return;
    }
    if (auto ws = s.isWhileStatement())
    {
        walkExpr(ws.condition, target, out_);
        if (ws._body)
            walkStmt(ws._body, target, out_);
        return;
    }
    if (auto ds = s.isDoStatement())
    {
        if (ds._body)
            walkStmt(ds._body, target, out_);
        walkExpr(ds.condition, target, out_);
        return;
    }
    if (auto fs = s.isForStatement())
    {
        walkStmt(fs._init, target, out_);
        walkExpr(fs.condition, target, out_);
        walkExpr(fs.increment, target, out_);
        if (fs._body)
            walkStmt(fs._body, target, out_);
        return;
    }
    if (auto fes = s.isForeachStatement())
    {
        walkExpr(fes.aggr, target, out_);
        if (fes._body)
            walkStmt(fes._body, target, out_);
        return;
    }
    if (auto frs = s.isForeachRangeStatement())
    {
        walkExpr(frs.lwr, target, out_);
        walkExpr(frs.upr, target, out_);
        if (frs._body)
            walkStmt(frs._body, target, out_);
        return;
    }
    if (auto sw = s.isSwitchStatement())
    {
        walkExpr(sw.condition, target, out_);
        if (sw._body)
            walkStmt(sw._body, target, out_);
        return;
    }
    if (auto cs = s.isCaseStatement())
    {
        walkExpr(cs.exp, target, out_);
        if (cs.statement)
            walkStmt(cs.statement, target, out_);
        return;
    }
    if (auto rs = s.isReturnStatement())
    {
        walkExpr(rs.exp, target, out_);
        return;
    }
    if (auto ws = s.isWithStatement())
    {
        walkExpr(ws.exp, target, out_);
        if (ws._body)
            walkStmt(ws._body, target, out_);
        return;
    }
    if (auto ts = s.isThrowStatement())
    {
        walkExpr(ts.exp, target, out_);
        return;
    }
    if (auto ts = s.isSynchronizedStatement())
    {
        walkExpr(ts.exp, target, out_);
        if (ts._body)
            walkStmt(ts._body, target, out_);
        return;
    }
    if (auto ts = s.isTryCatchStatement())
    {
        if (ts._body)
            walkStmt(ts._body, target, out_);
        if (ts.catches)
            foreach (c; *ts.catches)
                if (c && c.handler)
                    walkStmt(c.handler, target, out_);
        return;
    }
    if (auto ts = s.isTryFinallyStatement())
    {
        if (ts._body)
            walkStmt(ts._body, target, out_);
        if (ts.finalbody)
            walkStmt(ts.finalbody, target, out_);
        return;
    }
    if (auto ls = s.isLabelStatement())
    {
        if (ls.statement)
            walkStmt(ls.statement, target, out_);
        return;
    }
}

private void walkExpr(Expression e, Dsymbol target, ref RefLoc[] out_)
{
    if (!e)
        return;
    Identifier name = target.ident;
    if (auto ve = e.isVarExp())
    {
        if (sameTarget(ve.var, target))
            record(e.loc, name, out_);
    }
    else if (auto dv = e.isDotVarExp())
    {
        if (sameTarget(dv.var, target))
            record(e.loc, name, out_);
    }
    else if (auto so = e.isSymOffExp())
    {
        if (sameTarget(so.var, target))
            record(e.loc, name, out_);
    }
    else if (auto ca = e.isCallExp())
    {
        // The callee is `e1` (walked below); some calls carry the resolved
        // function only in `ca.f` (templates/qualified), so record at the
        // callee identifier too. Dedupe folds the two paths.
        if (ca.f && ca.e1 && sameTarget(ca.f, target))
            record(ca.e1.loc, name, out_);
        walkExpr(ca.e1, target, out_);
        if (ca.arguments)
            foreach (a; *ca.arguments)
                walkExpr(a, target, out_);
        return;
    }
    else if (auto ae = e.isArrayExp())
    {
        walkExpr(ae.e1, target, out_);
        if (ae.arguments)
            foreach (a; *ae.arguments)
                walkExpr(a, target, out_);
        return;
    }
    else if (auto ne = e.isNewExp())
    {
        if (sameType(ne.newtype, target))
            record(e.loc, name, out_);
        if (ne.arguments)
            foreach (a; *ne.arguments)
                walkExpr(a, target, out_);
        return;
    }
    else if (auto te = e.isTypeExp())
    {
        if (sameType(te.type, target))
            record(e.loc, name, out_);
    }
    else if (auto se = e.isScopeExp())
    {
        if (sameTarget(se.sds, target))
            record(e.loc, name, out_);
    }
    else if (auto fe = e.isFuncExp())
    {
        if (sameTarget(fe.fd, target) || sameTarget(fe.td, target))
            record(e.loc, name, out_);
    }
    else if (auto te = e.isTemplateExp())
    {
        if (sameTarget(te.td, target))
            record(e.loc, name, out_);
    }
    else if (auto dte = e.isDotTemplateExp())
    {
        if (sameTarget(dte.td, target))
            record(e.loc, name, out_);
        walkExpr(dte.e1, target, out_);
        return;
    }
    else if (auto dti = e.isDotTemplateInstanceExp())
    {
        if (dti.ti && sameTarget(dti.ti.tempdecl, target))
            record(e.loc, name, out_);
        walkExpr(dti.e1, target, out_);
        return;
    }
    else if (auto th = e.isThisExp())
    {
        if (sameTarget(th.var, target))
            record(e.loc, name, out_);
    }

    if (auto c = e.isCondExp())
    {
        walkExpr(c.econd, target, out_);
        walkExpr(c.e1, target, out_);
        walkExpr(c.e2, target, out_);
        return;
    }
    if (auto tup = e.isTupleExp())
    {
        if (tup.exps)
            foreach (a; *tup.exps)
                walkExpr(a, target, out_);
        return;
    }
    // Binary ops are flagged `unary | binary` in dmd's table, so this must
    // come before the UnaExp branch or the right operand is skipped.
    if (auto b = e.isBinExp())
    {
        walkExpr(b.e1, target, out_);
        walkExpr(b.e2, target, out_);
        return;
    }
    if (auto u = e.isUnaExp())
    {
        walkExpr(u.e1, target, out_);
        return;
    }
}

private bool sameTarget(Dsymbol a, Dsymbol b)
{
    if (!a || !b)
        return false;
    if (a is b)
        return true;
    if (auto ti = a.isTemplateInstance())
        if (ti.tempdecl)
            return sameTarget(ti.tempdecl, b);
    if (auto ti = b.isTemplateInstance())
        if (ti.tempdecl)
            return sameTarget(ti.tempdecl, a);
    // A template function instance resolves back to its template.
    if (auto ti = a.isInstantiated())
        if (ti.tempdecl)
            return sameTarget(ti.tempdecl, b);
    if (auto ti = b.isInstantiated())
        if (ti.tempdecl)
            return sameTarget(ti.tempdecl, a);
    // A function that is a template's single member stands in for the template.
    if (a.parent is b && b.isTemplateDeclaration() && a.isFuncDeclaration())
        return true;
    if (b.parent is a && a.isTemplateDeclaration() && b.isFuncDeclaration())
        return true;
    // Overload group: same name in the same scope (a call picks one overload,
    // but references/rename operate on the name).
    if (a.ident && b.ident && a.ident is b.ident && a.parent && a.parent is b.parent)
        if ((a.isFuncDeclaration() || a.isTemplateDeclaration()) &&
            (b.isFuncDeclaration() || b.isTemplateDeclaration()))
            return true;
    return false;
}

private bool sameType(Type t, Dsymbol target)
{
    if (!t)
        return false;
    Type b = t.toBasetype();
    if (!b)
        return false;
    if (auto ts = b.isTypeStruct())
        return ts.sym is target;
    if (auto tc = b.isTypeClass())
        return tc.sym is target;
    if (auto te = b.isTypeEnum())
        return te.sym is target;
    if (auto ti = b.isTypeInstance())
        if (ti.tempinst)
            return sameTarget(ti.tempinst.tempdecl, target);
    return false;
}

private void record(Loc loc, Identifier ident, ref RefLoc[] out_)
{
    if (loc.linnum() < 1)
        return;
    const(char)* f = loc.filename();
    if (!f)
        return;
    import core.stdc.string : strlen;
    uint len = ident ? cast(uint) ident.toString().length : 0;
    out_ ~= RefLoc(f[0 .. strlen(f)].idup, loc.linnum(), loc.charnum(), len);
}

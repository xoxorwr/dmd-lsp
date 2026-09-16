module complete;

// Scope-aware completion over the cached semantic universe. Struct-only.
// Covers: function params + block locals (loose: declared before cursor),
// module members, imported exported names, and dotted chains
// (`mod.member`, `var.member`, `Alias.member`) via LHS type resolution.
// Out of scope v1: UFCS candidates, template-constraint filtering,
// incremental reparse (full-file reparse per request).

import lsp;
import arena;

import dmd.dimport : Import;
import dmd.dmodule : Module;
import dmd.dsymbol : Dsymbol, Visibility;
import dmd.func : FuncDeclaration;
import dmd.declaration : VarDeclaration;
import dmd.aggregate : AggregateDeclaration;
import dmd.dtemplate : TemplateDeclaration, TemplateInstance;
import dmd.statement : Statement;
import dmd.arraytypes : Dsymbols;
import dmd.attrib : ConditionalDeclaration;
import dmd.dsymbol : DSYM;
import dmd.mtype : Type, TypePointer, TypeFunction;
import dmd.astenums : TY, VarArg;
import dmd.typesem : nextOf, toBasetype;
import dmd.dsymbolsem : toAlias;
import dmd.init : Initializer;
import dmd.expression : Expression, CallExp, NewExp, IdentifierExp, TypeExp,
    DotIdExp, DotTemplateInstanceExp, ScopeExp, TemplateExp;
import dmd.rootobject : DYNCAST;

struct CompleteCtx
{
    uint line = 0;      // 1-based
    uint character = 0; // 1-based col
    const(char)[] prefix;
}

struct CompleteOut
{
    LspCompletionItem* items = null; // Arena array
    size_t nitems = 0;
    size_t capItems = 0;
    bool incomplete = false;
}

// ---------- item sink ----------
// labelDetails for any symbol: functions split into "(params)" + return
// type; values/fields describe their type; other declarations their kind.
private void itemParts(Arena* a, Dsymbol s, ref const(char)[] labelDetail,
    ref const(char)[] labelDesc)
{
    if (auto fd = s.isFuncDeclaration())
    {
        funcParts(a, s, labelDetail, labelDesc);
        return;
    }
    if (auto vd = s.isVarDeclaration())
    {
        labelDesc = typeDetail(vd.type); // caller arena-dups
        if (labelDesc.length)
            return;
    }
    const(char)* k = s.kind();
    if (k)
    {
        import core.stdc.string : strlen;
        labelDesc = k[0 .. strlen(k)];
    }
}

private void pushItem(Arena* a, ref CompleteOut o, const(char)[] label, ubyte kind,
    const(char)[] detail, const(char)[] doc, const(char)[] sortPrefix,
    ref bool[const(char)[]] seen,
    Dsymbol sym = null, const(char)[] desc = null)
{
    if (label.length == 0 || label in seen)
        return;
    seen[label] = true;
    char* lp = cast(char*)a.alloc(label.length + 1);
    if (!lp)
        return;
    lp[0 .. label.length] = label[];
    lp[label.length] = 0;
    const(char)[] ls = lp[0 .. label.length];
    const(char)[] ds = arenaDupStr(a, detail);
    const(char)[] dc = arenaDupStr(a, doc);
    const(char)[] ld = null;
    const(char)[] lx = null;
    if (sym)
        itemParts(a, sym, ld, lx);
    else if (desc.length)
        lx = desc;
    ld = arenaDupStr(a, ld);
    lx = arenaDupStr(a, lx);
    string sort = (cast(string)sortPrefix ~ label.idup);
    char* sp = cast(char*)a.alloc(sort.length + 1);
    const(char)[] ss = null;
    if (sp)
    {
        sp[0 .. sort.length] = sort[];
        sp[sort.length] = 0;
        ss = sp[0 .. sort.length];
    }
    if (o.nitems == o.capItems)
    {
        size_t ncap = o.capItems == 0 ? 128 : o.capItems * 2;
        LspCompletionItem* p = cast(LspCompletionItem*)a.alloc(ncap * LspCompletionItem.sizeof);
        if (!p)
            return;
        for (size_t i = 0; i < o.nitems; i++)
            p[i] = o.items[i];
        o.items = p;
        o.capItems = ncap;
    }
    o.items[o.nitems++] = LspCompletionItem(ls, kind, ds, dc, ss, ld, lx);
}

private const(char)[] arenaDupStr(Arena* a, const(char)[] s)
{
    if (!s.length)
        return null;
    char* p = cast(char*)a.alloc(s.length + 1);
    if (!p)
        return null;
    p[0 .. s.length] = s[];
    p[s.length] = 0;
    return p[0 .. s.length];
}

private ubyte kindOf(Dsymbol s)
{
    if (s.isFuncDeclaration())
        return 3;
    if (s.isVarDeclaration())
        return 6;
    if (s.isAggregateDeclaration())
        return 7;
    if (s.isEnumDeclaration())
        return 20; // EnumMember-ish; enums themselves fall through below
    if (s.isModule())
        return 9;
    if (s.isAliasDeclaration())
        return 1;
    if (s.isTemplateDeclaration())
        return 1;
    return 1;
}

private bool hasPrefix(const(char)[] name, const(char)[] prefix)
{
    if (prefix.length > name.length)
        return false;
    return name[0 .. prefix.length] == prefix;
}

private const(char)[] typeDetail(Type t)
{
    if (!t)
        return null;
    const(char)* p = t.toChars();
    if (!p)
        return null;
    import core.stdc.string : strlen;
    return p[0 .. strlen(p)];
}

private const(char)[] docOf(Dsymbol s)
{
    const(char)* c = s.comment;
    if (!c)
        return null;
    import core.stdc.string : strlen;
    size_t n = strlen(c);
    // Trim leading comment decoration (///, /**, //) lightly: first 240 chars.
    size_t start = 0;
    while (start < n && (c[start] == '/' || c[start] == '*' || c[start] == ' ' || c[start] == '\t'))
        start++;
    size_t end = start + 240 < n ? start + 240 : n;
    return c[start .. end];
}

// ---------- member enumeration ----------
private void addMembers(Arena* a, Dsymbol[] members, const(char)[] prefix,
    const(char)[] sortPrefix, ref CompleteOut o, ref bool[const(char)[]] seen)
{
    foreach (s; members)
    {
        if (!s.ident)
            continue;
        // Never surface our own trailing-dot placeholder template.
        if (s.ident.toString() == "__dmd_lsp_ph")
            continue;
        if (s.visible().kind == Visibility.Kind.private_)
            continue;
        const(char)[] nm = s.ident.toString();
        if (!hasPrefix(nm, prefix))
            continue;
        pushItem(a, o, nm, kindOf(s), typeDetail(symType(s)), docOf(s), sortPrefix, seen, s);
        if (o.nitems >= 500)
            return;
    }
}

private Type symType(Dsymbol s)
{
    if (auto vd = s.isVarDeclaration())
        return vd.type;
    if (auto fd = s.isFuncDeclaration())
        return fd.type;
    return null;
}

// Function label parts for LSP 3.17 `labelDetails`: the parameter list
// (e.g. "(int, string)") and the return type. Empty for non-functions.
private const(char)[] funcParamList(Arena* a, TypeFunction tf, bool withNames)
{
    import core.stdc.string : strlen;
    string buf = "(";
    bool first = true;
    if (tf.parameterList.parameters)
        foreach (i; 0 .. (*tf.parameterList.parameters).length)
        {
            auto p = (*tf.parameterList.parameters)[i];
            if (!p)
                continue;
            if (!first)
                buf ~= ", ";
            first = false;
            const(char)* ts = p.type ? p.type.toChars() : null;
            buf ~= ts ? ts[0 .. strlen(ts)] : "?";
            if (withNames && p.ident)
            {
                buf ~= " ";
                buf ~= p.ident.toString();
            }
        }
    if (tf.parameterList.varargs != VarArg.none)
    {
        if (!first)
            buf ~= ", ";
        buf ~= "...";
    }
    buf ~= ")";
    return arenaDupStr(a, buf);
}

private void funcParts(Arena* a, Dsymbol s, ref const(char)[] labelDetail,
    ref const(char)[] labelDesc)
{
    auto fd = s.isFuncDeclaration();
    if (!fd || !fd.type)
        return;
    auto tf = fd.type.isTypeFunction();
    if (!tf)
        return;
    labelDetail = funcParamList(a, tf, false);
    labelDesc = arenaDupStr(a, typeDetail(tf.next));
}

private Dsymbol[] scopeMembers(Dsymbol scope_)
{
    Dsymbol[] r;
    if (auto ad = scope_.isAggregateDeclaration())
    {
        flattenMembers(ad.members, r);
        return r;
    }
    if (auto ed = scope_.isEnumDeclaration())
    {
        flattenMembers(ed.members, r);
        return r;
    }
    if (auto m = scope_.isModule())
    {
        flattenMembers(m.members, r);
        return r;
    }
    return r;
}

// ---------- enclosing function + locals ----------
// Child scopes to descend when walking members. Attribute blocks
// (`private:`, `@safe:`, `extern(C++):`, ...) hide declarations inside
// them in real-world code — missing this drops most members.
// Public so semantic highlighting can walk declarations too.
void appendScopeSubs(Dsymbol s, ref Dsymbol[] out_)
{
    if (auto ad = s.isAggregateDeclaration())
    {
        if (ad.members)
            foreach (i; 0 .. (*ad.members).length)
                out_ ~= (*ad.members)[i];
    }
    else if (auto td = s.isTemplateDeclaration())
    {
        if (td.members)
            foreach (i; 0 .. (*td.members).length)
                out_ ~= (*td.members)[i];
    }
    else if (auto ns = s.isNspace())
    {
        if (ns.members)
            foreach (i; 0 .. (*ns.members).length)
                out_ ~= (*ns.members)[i];
    }
    else if (auto at = s.isAttribDeclaration())
    {
        if (at.decl)
            foreach (i; 0 .. (*at.decl).length)
                out_ ~= (*at.decl)[i];
        // NOTE: never D-cast dmd AST nodes (extern(C++) classes have no
        // runtime type check; a bogus cast reads wrong field offsets).
        // Tag-check first, then the cast is safe.
        if (at.dsym == DSYM.conditionalDeclaration)
        {
            auto cd = cast(ConditionalDeclaration)at;
            if (cd.elsedecl)
                foreach (i; 0 .. (*cd.elsedecl).length)
                    out_ ~= (*cd.elsedecl)[i];
        }
    }
}

// Flat member list with attribute blocks expanded recursively (for name
// lookup and completion; aggregates stay intact for scopeMembers/stepInto).
private void flattenMembers(Dsymbols* mem, ref Dsymbol[] out_)
{
    if (!mem)
        return;
    Dsymbol[] direct;
    foreach (i; 0 .. (*mem).length)
        direct ~= (*mem)[i];
    flattenArray(direct, out_);
}

private void flattenArray(Dsymbol[] arr, ref Dsymbol[] out_)
{
    foreach (s; arr)
    {
        if (!s)
            continue;
        if (s.isAttribDeclaration())
        {
            Dsymbol[] subs;
            appendScopeSubs(s, subs);
            flattenArray(subs, out_);
        }
        else
            out_ ~= s;
    }
}

private void findFuncRec(Dsymbol s, uint line, ref FuncDeclaration best, ref uint bestDepth, uint depth)
{
    Dsymbol[] subs = null;
    appendScopeSubs(s, subs);
    foreach (m; subs)
    {
        if (auto fd = m.isFuncDeclaration())
        {
            uint sl = fd.loc.linnum();
            uint el = fd.endloc.linnum();
            if (sl >= 1 && sl <= line && (el == 0 || line <= el) && depth >= bestDepth)
            {
                best = fd;
                bestDepth = depth;
            }
        }
        findFuncRec(m, line, best, bestDepth, depth + 1);
    }
}

// One pass collection of function ranges (mirrors findEnclosingFunc's
// selection) so batch callers don't re-walk the whole symbol tree per line.
private struct FuncRange
{
    uint start = 0;
    uint end = 0;
    uint depth = 0;
    FuncDeclaration fd;
}

private void collectFuncRanges(Dsymbol s, uint depth, ref FuncRange[] out_)
{
    Dsymbol[] subs;
    appendScopeSubs(s, subs);
    foreach (m; subs)
    {
        if (auto fd = m.isFuncDeclaration())
        {
            uint sl = fd.loc.linnum();
            if (sl >= 1)
                out_ ~= FuncRange(sl, fd.endloc.linnum(), depth, fd);
        }
        collectFuncRanges(m, depth + 1, out_);
    }
}

private FuncDeclaration enclosingFunc(FuncRange[] rs, uint line)
{
    FuncDeclaration best = null;
    uint bestDepth = 0;
    foreach (ref r; rs)
        if (r.start >= 1 && r.start <= line && (r.end == 0 || line <= r.end) &&
            r.depth >= bestDepth)
        {
            best = r.fd;
            bestDepth = r.depth;
        }
    return best;
}

private FuncDeclaration findEnclosingFunc(Module mod, uint line)
{
    FuncDeclaration best = null;
    uint bestDepth = 0;
    if (!mod || !mod.members)
        return null;
    foreach (i; 0 .. (*mod.members).length)
    {
        auto s = (*mod.members)[i];
        if (auto fd = s.isFuncDeclaration())
        {
            uint sl = fd.loc.linnum();
            uint el = fd.endloc.linnum();
            if (sl >= 1 && sl <= line && (el == 0 || line <= el))
            {
                best = fd;
                bestDepth = 0;
            }
        }
        findFuncRec(s, line, best, bestDepth, 1);
    }
    return best;
}

// ---------- pre-semantic snapshot ----------
// Post-semantic bodies are lossy (failed statements propagate
// ErrorStatement up to fbody), so structure (function ranges, local
// names) is snapshotted from the fresh parse BEFORE semantic runs.
// Only plain data is retained (names idup'd); no dmd pointers escape.
struct SynLocal
{
    string name;
    uint line = 0;
    string typeName; // unresolved (pre-semantic) type ident, if simple
    string typeText; // full pre-semantic type spelling for display (`Event*`)
}

// Full pre-semantic type spelling, for describing a local in completion.
private string typeTextOf(Type t)
{
    if (!t)
        return null;
    const(char)* p = t.toChars();
    if (!p)
        return null;
    import core.stdc.string : strlen;
    return p[0 .. strlen(p)].idup;
}

// SynLocal with both the resolution ident and the display spelling.
private SynLocal synVar(const(char)[] name, uint line, Type t)
{
    return SynLocal(name.idup, line, identTypeName(t), typeTextOf(t));
}

// Best-effort pre-semantic type ident from a declaration's type: a
// TypeIdentifier, or a pointer/qualifier over one (`Event* ev` -> `Event`),
// so member access survives a collapsed body.
private string identTypeName(Type t)
{
    if (!t)
        return null;
    if (auto ti = t.isTypeIdentifier())
    {
        if (ti.ident)
            return ti.ident.toString().idup;
    }
    if (auto tp = t.isTypePointer())
        return identTypeName(tp.nextOf());
    return null;
}

// First template argument as a type name (`create!(State)` -> `State`), a
// common factory shape whose result type is the argument.
private string firstTemplateArgName(TemplateInstance ti)
{
    if (!ti || !ti.tiargs || (*ti.tiargs).length == 0)
        return null;
    auto ro = (*ti.tiargs)[0];
    if (!ro)
        return null;
    if (ro.dyncast() == DYNCAST.type)
        return identTypeName(cast(Type)ro);
    if (ro.dyncast() == DYNCAST.expression)
    {
        auto ex = cast(Expression)ro;
        if (auto ie = ex.isIdentifierExp())
        {
            if (ie.ident)
                return ie.ident.toString().idup;
        }
        else if (auto te = ex.isTypeExp())
            return identTypeName(te.type);
    }
    return null;
}

// Pre-semantic type name of what an `auto` initializer constructs:
// `Type(...)`, `new Type(...)`, `pkg.Type(...)`, `factory!(Type)(...)`. When
// an unrelated error collapses a body, this is all that is left to resolve
// members on the local (`auto q = Point(...); q.x`).
private string initTypeName(Initializer init)
{
    if (!init)
        return null;
    auto ei = init.isExpInitializer();
    if (!ei || !ei.exp)
        return null;
    auto e = ei.exp;
    if (auto ce = e.isCallExp())
    {
        auto callee = ce.e1;
        if (auto ie = callee.isIdentifierExp())
        {
            if (ie.ident)
                return ie.ident.toString().idup;
        }
        else if (auto te = callee.isTypeExp())
            return identTypeName(te.type);
        else if (auto de = callee.isDotIdExp())
        {
            if (de.ident)
                return de.ident.toString().idup;
        }
        else if (auto dti = callee.isDotTemplateInstanceExp())
            return firstTemplateArgName(dti.ti);
        else if (auto se = callee.isScopeExp())
        {
            if (auto ti = se.sds.isTemplateInstance())
                return firstTemplateArgName(ti);
        }
        else if (auto te = callee.isTemplateExp())
        {
            if (te.td && te.td.onemember)
                if (auto ti = te.td.onemember.isTemplateInstance())
                    return firstTemplateArgName(ti);
        }
        return null;
    }
    if (auto ne = e.isNewExp())
        return identTypeName(ne.newtype);
    if (auto te = e.isTypeExp())
        return identTypeName(te.type);
    return null;
}

struct SynFunc
{
    string name; // null for literals
    uint startLine = 0;
    uint endLine = 0; // 0 = unknown/open
    uint depth = 0;
    SynLocal[] vars;   // body vars (names + decl lines + type idents)
    string[] params;   // param names from the type (no locs)
    string[] paramTypes; // parallel unresolved type idents (may be null)
    string[] paramTypeTexts; // parallel full type spelling for display
}

struct SynMod
{
    SynFunc[] funcs;
}

private void synWalkBody(Statement s, uint funcEnd, ref SynFunc fn)
{
    if (!s)
        return;
    if (auto es = s.isExpStatement())
    {
        if (es.exp)
        {
            if (auto de = es.exp.isDeclarationExp())
            {
                if (auto vd = de.declaration.isVarDeclaration())
                {
                    if (vd.ident)
                    {
                        auto tn = identTypeName(vd.type);
                        if (!tn.length)
                            tn = initTypeName(vd._init);
                        fn.vars ~= SynLocal(vd.ident.toString().idup,
                            vd.loc.linnum(), tn, typeTextOf(vd.type));
                    }
                }
                else if (auto nfd = de.declaration.isFuncDeclaration())
                    synFunc(nfd, fn.depth + 1);
            }
        }
        return;
    }
    if (auto cs = s.isCompoundStatement())
    {
        for (size_t i = 0; i < cs.statements.length; i++)
            synWalkBody(cs.statements[i], funcEnd, fn);
        return;
    }
    if (auto ss = s.isScopeStatement())
    {
        synWalkBody(ss.statement, funcEnd, fn);
        return;
    }
    if (auto is_ = s.isIfStatement())
    {
        if (is_.param && is_.param.ident)
            fn.vars ~= synVar(is_.param.ident.toString(), is_.loc.linnum(), is_.param.type);
        synWalkBody(is_.ifbody, funcEnd, fn);
        synWalkBody(is_.elsebody, funcEnd, fn);
        return;
    }
    if (auto ws = s.isWhileStatement())
    {
        if (ws.param && ws.param.ident)
            fn.vars ~= synVar(ws.param.ident.toString(), ws.loc.linnum(), ws.param.type);
        synWalkBody(ws._body, funcEnd, fn);
        return;
    }
    if (auto ds = s.isDoStatement())
    {
        synWalkBody(ds._body, funcEnd, fn);
        return;
    }
    if (auto fs = s.isForStatement())
    {
        synWalkBody(fs._init, funcEnd, fn);
        synWalkBody(fs._body, funcEnd, fn);
        return;
    }
    if (auto fes = s.isForeachStatement())
    {
        if (fes.parameters)
            foreach (i; 0 .. fes.parameters.length)
            {
                auto p = (*fes.parameters)[i];
                if (p && p.ident)
                    fn.vars ~= synVar(p.ident.toString(), fes.loc.linnum(), p.type);
            }
        if (fes.key && fes.key.ident)
            fn.vars ~= synVar(fes.key.ident.toString(), fes.key.loc.linnum(), fes.key.type);
        if (fes.value && fes.value.ident)
            fn.vars ~= synVar(fes.value.ident.toString(), fes.value.loc.linnum(), fes.value.type);
        synWalkBody(fes._body, funcEnd, fn);
        return;
    }
    if (auto sw = s.isSwitchStatement())
    {
        if (sw.param && sw.param.ident)
            fn.vars ~= synVar(sw.param.ident.toString(), sw.loc.linnum(), sw.param.type);
        synWalkBody(sw._body, funcEnd, fn);
        return;
    }
    if (auto c1 = s.isCaseStatement())
    {
        synWalkBody(c1.statement, funcEnd, fn);
        return;
    }
    if (auto d1 = s.isDefaultStatement())
    {
        synWalkBody(d1.statement, funcEnd, fn);
        return;
    }
    if (auto lb = s.isLabelStatement())
    {
        synWalkBody(lb.statement, funcEnd, fn);
        return;
    }
    if (auto tc = s.isTryCatchStatement())
    {
        synWalkBody(tc._body, funcEnd, fn);
        if (tc.catches)
            foreach (i; 0 .. (*tc.catches).length)
            {
                auto c = (*tc.catches)[i];
                if (c.ident)
                    fn.vars ~= synVar(c.ident.toString(), c.loc.linnum, c.type);
                synWalkBody(c.handler, funcEnd, fn);
            }
        return;
    }
    if (auto tf = s.isTryFinallyStatement())
    {
        synWalkBody(tf._body, funcEnd, fn);
        synWalkBody(tf.finalbody, funcEnd, fn);
        return;
    }
    if (auto w = s.isWithStatement())
    {
        if (w.prm && w.prm.ident)
            fn.vars ~= synVar(w.prm.ident.toString(), w.loc.linnum(), w.prm.type);
        synWalkBody(w._body, funcEnd, fn);
        return;
    }
    if (auto sy = s.isSynchronizedStatement())
    {
        synWalkBody(sy._body, funcEnd, fn);
        return;
    }
}

// Accumulates into g_synFuncs (file-static scratch, reset per snapshot).
// Each function is built in a stack local and appended once, so nested
// appends can never invalidate anything being walked.
private SynFunc[] g_synFuncs;

private void synFunc(FuncDeclaration fd, uint depth)
{
    if (!fd)
        return;
    SynFunc fn;
    fn.name = fd.ident ? fd.ident.toString().idup : null;
    fn.startLine = fd.loc.linnum();
    fn.endLine = fd.endloc.linnum();
    fn.depth = depth;
    if (fd.type)
    {
        if (auto tf = fd.type.isTypeFunction())
        {
            if (tf.parameterList.parameters)
                foreach (i; 0 .. (*tf.parameterList.parameters).length)
                {
                    auto p = (*tf.parameterList.parameters)[i];
                    if (p && p.ident)
                    {
                        fn.params ~= p.ident.toString().idup;
                        fn.paramTypes ~= identTypeName(p.type);
                        fn.paramTypeTexts ~= typeTextOf(p.type);
                    }
                }
        }
    }
    if (fd.fbody)
        synWalkBody(fd.fbody, fn.endLine, fn);
    g_synFuncs ~= fn;
}

private void synMembers(Dsymbol[] members, uint depth)
{
    foreach (s; members)
    {
        if (auto fd = s.isFuncDeclaration())
            synFunc(fd, depth);
        Dsymbol[] subs = null;
        appendScopeSubs(s, subs);
        if (subs.length)
            synMembers(subs, depth + 1);
    }
}

// Snapshot structure from a FRESH parse (pre-semantic). Call once per
// request before semantic rewrites bodies. Plain data only.
SynMod snapshotModule(Module mod)
{
    SynMod m;
    if (!mod || !mod.members)
        return m;
    g_synFuncs = null;
    Dsymbol[] members;
    foreach (i; 0 .. (*mod.members).length)
        members ~= (*mod.members)[i];
    synMembers(members, 0);
    m.funcs = g_synFuncs;
    g_synFuncs = null;
    return m;
}

// Innermost snapshot function containing line (deepest match wins).
const(SynFunc)* synFuncAt(const ref SynMod m, uint line)
{
    const(SynFunc)* best = null;
    foreach (ref fn; m.funcs)
    {
        if (fn.startLine < 1 || fn.startLine > line)
            continue;
        if (fn.endLine != 0 && line > fn.endLine)
            continue;
        if (!best || fn.depth >= best.depth)
            best = &fn;
    }
    return best;
}

private void addLocal(Arena* a, ref CompleteOut o, ref bool[const(char)[]] seen,
    VarDeclaration vd, uint cursorLine, const(char)[] prefix)
{
    if (!vd || !vd.ident)
        return;
    if (vd.loc.linnum() > cursorLine)
        return;
    const(char)[] nm = vd.ident.toString();
    if (!hasPrefix(nm, prefix))
        return;
    if (nm == "this" || nm == "super" || nm == "_")
        return;
    pushItem(a, o, nm, 6, typeDetail(vd.type), docOf(vd), "0", seen, vd);
}

private void walkStmt(Statement s, FuncDeclaration cur, uint cursorLine, const(char)[] prefix,
    Arena* a, ref CompleteOut o, ref bool[const(char)[]] seen)
{
    if (!s || s.loc.linnum() > cursorLine)
        return;
    if (auto es = s.isExpStatement())
    {
        if (es.exp)
        {
            if (auto de = es.exp.isDeclarationExp())
            {
                if (auto vd = de.declaration.isVarDeclaration())
                    addLocal(a, o, seen, vd, cursorLine, prefix);
                else if (auto fd = de.declaration.isFuncDeclaration())
                {
                    // Nested function: offer it; descend if cursor inside.
                    if (fd.ident && fd.loc.linnum() <= cursorLine)
                    {
                        const(char)[] nm = fd.ident.toString();
                        if (hasPrefix(nm, prefix))
                        {
                            pushItem(a, o, nm, 3, typeDetail(fd.type), docOf(fd), "0", seen, fd);
                        }
                        uint el = fd.endloc.linnum();
                        if (fd.loc.linnum() <= cursorLine && (el == 0 || cursorLine <= el))
                            collectInFunc(fd, cursorLine, prefix, a, o, seen);
                    }
                }
            }
        }
        return;
    }
    if (auto cs = s.isCompoundStatement())
    {
        for (size_t i = 0; i < cs.statements.length; i++)
            walkStmt(cs.statements[i], cur, cursorLine, prefix, a, o, seen);
        return;
    }
    if (auto ss = s.isScopeStatement())
    {
        walkStmt(ss.statement, cur, cursorLine, prefix, a, o, seen);
        return;
    }
    if (auto is_ = s.isIfStatement())
    {
        if (is_.param && is_.param.ident)
        {
            const(char)[] inm = is_.param.ident.toString();
            if (hasPrefix(inm, prefix))
                pushItem(a, o, inm, 6, typeDetail(is_.param.type), null, "0", seen, null, typeDetail(is_.param.type));
        }
        if (is_.match)
            addLocal(a, o, seen, is_.match, cursorLine, prefix);
        walkStmt(is_.ifbody, cur, cursorLine, prefix, a, o, seen);
        walkStmt(is_.elsebody, cur, cursorLine, prefix, a, o, seen);
        return;
    }
    if (auto ws = s.isWhileStatement())
    {
        if (ws.param && ws.param.ident)
        {
            const(char)[] wnm = ws.param.ident.toString();
            if (hasPrefix(wnm, prefix))
                pushItem(a, o, wnm, 6, typeDetail(ws.param.type), null, "0", seen, null, typeDetail(ws.param.type));
        }
        walkStmt(ws._body, cur, cursorLine, prefix, a, o, seen);
        return;
    }
    if (auto ds = s.isDoStatement())
    {
        walkStmt(ds._body, cur, cursorLine, prefix, a, o, seen);
        return;
    }
    if (auto fs = s.isForStatement())
    {
        walkStmt(fs._init, cur, cursorLine, prefix, a, o, seen);
        walkStmt(fs._body, cur, cursorLine, prefix, a, o, seen);
        return;
    }
    if (auto fes = s.isForeachStatement())
    {
        if (fes.parameters)
            foreach (i; 0 .. fes.parameters.length)
            {
                auto fp = (*fes.parameters)[i];
                if (fp && fp.ident)
                {
                    const(char)[] fnm = fp.ident.toString();
                    if (hasPrefix(fnm, prefix))
                        pushItem(a, o, fnm, 6, typeDetail(fp.type), null, "0", seen, null, typeDetail(fp.type));
                }
            }
        if (fes.key)
            addLocal(a, o, seen, fes.key, cursorLine, prefix);
        if (fes.value)
            addLocal(a, o, seen, fes.value, cursorLine, prefix);
        walkStmt(fes._body, cur, cursorLine, prefix, a, o, seen);
        return;
    }
    if (auto sw = s.isSwitchStatement())
    {
        if (sw.param && sw.param.ident)
        {
            const(char)[] snm = sw.param.ident.toString();
            if (hasPrefix(snm, prefix))
                pushItem(a, o, snm, 6, typeDetail(sw.param.type), null, "0", seen, null, typeDetail(sw.param.type));
        }
        walkStmt(sw._body, cur, cursorLine, prefix, a, o, seen);
        return;
    }
    if (auto c1 = s.isCaseStatement())
    {
        walkStmt(c1.statement, cur, cursorLine, prefix, a, o, seen);
        return;
    }
    if (auto d1 = s.isDefaultStatement())
    {
        walkStmt(d1.statement, cur, cursorLine, prefix, a, o, seen);
        return;
    }
    if (auto lb = s.isLabelStatement())
    {
        walkStmt(lb.statement, cur, cursorLine, prefix, a, o, seen);
        return;
    }
    if (auto tc = s.isTryCatchStatement())
    {
        walkStmt(tc._body, cur, cursorLine, prefix, a, o, seen);
        if (tc.catches)
            foreach (i; 0 .. (*tc.catches).length)
            {
                auto c = (*tc.catches)[i];
                if (c.var)
                    addLocal(a, o, seen, c.var, cursorLine, prefix);
                walkStmt(c.handler, cur, cursorLine, prefix, a, o, seen);
            }
        return;
    }
    if (auto tf = s.isTryFinallyStatement())
    {
        walkStmt(tf._body, cur, cursorLine, prefix, a, o, seen);
        walkStmt(tf.finalbody, cur, cursorLine, prefix, a, o, seen);
        return;
    }
    if (auto w = s.isWithStatement())
    {
        if (w.prm && w.prm.ident)
        {
            const(char)[] wnm = w.prm.ident.toString();
            if (hasPrefix(wnm, prefix))
                pushItem(a, o, wnm, 6, typeDetail(w.prm.type), null, "0", seen, null, typeDetail(w.prm.type));
        }
        walkStmt(w._body, cur, cursorLine, prefix, a, o, seen);
        return;
    }
    if (auto sy = s.isSynchronizedStatement())
    {
        walkStmt(sy._body, cur, cursorLine, prefix, a, o, seen);
        return;
    }
    // Other statements: no locals.
}

private void collectInFunc(FuncDeclaration fd, uint cursorLine, const(char)[] prefix,
    Arena* a, ref CompleteOut o, ref bool[const(char)[]] seen)
{
    if (!fd)
        return;
    if (fd.parameters)
        foreach (i; 0 .. fd.parameters.length)
        {
            VarDeclaration v = (*fd.parameters)[i];
            addLocal(a, o, seen, v, cursorLine, prefix);
        }
    if (fd.fbody)
        walkStmt(fd.fbody, fd, cursorLine, prefix, a, o, seen);
}

// ---------- dotted chains ----------
private bool isChainChar(char c) pure nothrow @nogc @safe
{
    return c == '_' || c == '.' || c == '[' || c == ']' ||
        (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
}

// Segment name without an index suffix: `hate_table[0]` -> `hate_table`.
private const(char)[] baseName(const(char)[] seg) pure nothrow @nogc @safe
{
    size_t i = 0;
    while (i < seg.length && seg[i] != '[')
        i++;
    return seg[0 .. i];
}

// Returns full chain ending at cursor (e.g. "foo.bar.ba"), or null.
const(char)[] extractChain(const(char)[] text, uint line, uint col)
{
    size_t i = 0;
    uint l = 1;
    while (i < text.length && l < line)
    {
        if (text[i] == '\n')
            l++;
        i++;
    }
    size_t lineStart = i;
    while (i < text.length && text[i] != '\n')
        i++;
    auto lineText = text[lineStart .. i];
    size_t e = col - 1;
    if (e > lineText.length) // clamp overlong columns (e.g. past EOL)
        e = lineText.length;
    size_t s = e;
    while (s > 0 && isChainChar(lineText[s - 1]))
        s--;
    auto chain = lineText[s .. e];
    if (!chain.length)
        return null;
    // Must contain at least one ident char (not just dots).
    foreach (c; chain)
        if (c != '.')
            return chain;
    return null;
}

private Dsymbol[] followTypeDepth(Type t, Module root, Dsymbol[] rootMembers, int depth)
{
    if (!t || depth > 4)
        return null;
    // Unresolved (pre-semantic or failed) single-identifier type:
    // look the name up in scope instead of touching semantic tables.
    // Depth is threaded (not reset) so alias cycles still terminate.
    if (auto ti = t.isTypeIdentifier())
    {
        if (ti.ident)
        {
            const(char)[] nm = ti.ident.toString();
            auto m = findMember(rootMembers, nm);
            if (!m)
                m = findImportMember(root, nm);
            if (m)
                return stepInto(m, depth + 1, root, rootMembers);
        }
        return null;
    }
    Type tb = t.toBasetype();
    if (!tb)
        return null;
    // Transparent pointer dereference (D auto-derefs, e.g. Scope*).
    if (tb.ty == TY.Tpointer)
    {
        auto tp = cast(TypePointer)tb;
        if (tp && tp.next)
            return followTypeDepth(tp.next, root, rootMembers, depth + 1);
        return null;
    }
    // Array element access (`arr[0].`): complete on the element type.
    if (tb.ty == TY.Tsarray || tb.ty == TY.Tarray || tb.ty == TY.Taarray)
    {
        auto nxt = tb.nextOf();
        if (nxt)
            return followTypeDepth(nxt, root, rootMembers, depth + 1);
        return null;
    }
    if (auto ts = tb.isTypeStruct())
    {
        if (ts.sym)
            return scopeMembers(ts.sym);
    }
    else if (auto tc = tb.isTypeClass())
    {
        if (tc.sym)
            return scopeMembers(tc.sym);
    }
    else if (auto te = tb.isTypeEnum())
    {
        if (te.sym)
            return scopeMembers(te.sym);
    }
    return null;
}

private Dsymbol findMember(Dsymbol[] members, const(char)[] name)
{
    foreach (m; members)
    {
        if (m.ident && m.ident.toString() == name)
            return m;
    }
    return null;
}

// A visible local/param name with an optional resolved type.
struct NameType
{
    const(char)[] name;
    Type type; // null when unknown (e.g. body rewritten by errors)
    const(char)[] typeName; // unresolved (pre-semantic) type ident
    Dsymbol sym; // declaring symbol when semantic (goto-definition)
}

// Resolve the scope denoted by `lhs` chain segments.
private Dsymbol[] resolveLhs(Module root, const(char)[][] segs,
    Dsymbol[] rootMembers, NameType[] locals, int depth = 0)
{
    if (!segs.length)
        return null;
    // First segment: local/param (shadows everything), else module member,
    // import alias, or module name.
    Dsymbol[] curMembers = null;
    bool shadowed = false;
    foreach (v; locals)
    {
        if (v.name == baseName(segs[0]))
        {
            shadowed = true;
            curMembers = followTypeDepth(v.type, root, rootMembers, depth + 1);
            if (!curMembers.length && v.typeName.length)
            {
                // Unresolved (pre-semantic) type name: scope lookup.
                auto m = findMember(rootMembers, v.typeName);
                if (!m)
                    m = findImportMember(root, v.typeName);
                if (m)
                    curMembers = stepInto(m, depth + 1, root, rootMembers);
            }
            break;
        }
    }
    if (!shadowed)
    {
        // Module-level lookup (members + import aliases + module names +
        // names visible through imports, e.g. `EventType.` for an imported
        // enum — hover already resolves these; completion must too).
        Dsymbol cur = findMember(rootMembers, baseName(segs[0]));
        if (!cur)
            cur = findImportScope(root, baseName(segs[0]));
        if (!cur)
            cur = findImportMember(root, baseName(segs[0]));
        if (!cur)
            return null;
        curMembers = stepInto(cur, depth + 1, root, rootMembers);
        if (!curMembers.length)
            return null;
    }
    else if (!curMembers.length)
        return null;
    // Walk remaining segments (depth grows per step to bound cycles).
    foreach (k; 1 .. segs.length)
    {
        auto m = findMember(curMembers, baseName(segs[k]));
        if (!m)
            return null;
        curMembers = stepInto(m, depth + 1, root, rootMembers);
        if (k + 1 < segs.length && !curMembers.length)
            return null;
    }
    return curMembers;
}

private Dsymbol[] stepInto(Dsymbol s, int depth, Module root, Dsymbol[] rootMembers)
{
    if (!s || depth > 8)
        return null;
    if (auto ad = s.isAggregateDeclaration())
        return scopeMembers(ad);
    if (auto ed = s.isEnumDeclaration())
        return scopeMembers(ed);
    if (auto m = s.isModule())
        return scopeMembers(m);
    if (auto vd = s.isVarDeclaration())
        return followTypeDepth(vd.type, root, rootMembers, depth + 1);
    if (auto fd = s.isFuncDeclaration())
    {
        // Complete on call results: follow return type.
        if (fd.type)
            return followTypeDepth(fd.type.nextOf(), root, rootMembers, depth + 1);
        return null;
    }
    if (auto al = s.isAliasDeclaration())
    {
        auto t = al.toAlias();
        if (t && t !is s)
            return stepInto(t, depth + 1, root, rootMembers);
        return null;
    }
    if (auto imp = s.isImport())
    {
        if (imp.mod)
            return scopeMembers(imp.mod);
        return null;
    }
    return null;
}

// Find a member by name in directly imported modules (one transitive
// public level, mirroring walkImports).
private Dsymbol findImportMember(Module root, const(char)[] name)
{
    if (!root || !root.members)
        return null;
    Dsymbol[] flat;
    flattenMembers(root.members, flat);
    foreach (s; flat)
    {
        auto imp = s.isImport();
        if (!imp || !imp.mod || imp.isstatic)
            continue;
        // The root can see the imported module's whole public interface
        // regardless of this import's own visibility.
        auto r = findInModuleInterface(imp.mod, name, 0);
        if (r)
            return r;
    }
    return null;
}

// Search `m`'s own members, then (recursively) what it `public import`s.
private Dsymbol findInModuleInterface(Module m, const(char)[] name, int depth)
{
    if (!m || !m.members || depth > 4)
        return null;
    Dsymbol[] flat;
    flattenMembers(m.members, flat);
    foreach (s; flat)
    {
        if (s.ident && s.ident.toString() == name)
            return s;
        auto imp = s.isImport();
        if (!imp || !imp.mod || !imp.mod.members || imp.isstatic)
            continue;
        auto vk = imp.visibility.kind;
        if (vk == Visibility.Kind.public_ || vk == Visibility.Kind.export_)
        {
            auto r = findInModuleInterface(imp.mod, name, depth + 1);
            if (r)
                return r;
        }
    }
    return null;
}

// Name -> symbol reachable through direct imports and their public
// re-exports. Built once so per-token lookups don't re-flatten the module.
private void indexImportInterfaces(Module root, ref Dsymbol[const(char)[]] map)
{
    if (!root || !root.members)
        return;
    Dsymbol[] flat;
    flattenMembers(root.members, flat);
    foreach (s; flat)
    {
        auto imp = s.isImport();
        if (!imp || !imp.mod || imp.isstatic)
            continue;
        indexModuleInterface(imp.mod, map, 0);
    }
}

private void indexModuleInterface(Module m, ref Dsymbol[const(char)[]] map,
    int depth)
{
    if (!m || !m.members || depth > 4)
        return;
    Dsymbol[] flat;
    flattenMembers(m.members, flat);
    foreach (s; flat)
    {
        if (s.ident)
        {
            auto id = s.ident.toString();
            if (id !in map)
                map[id] = s;
        }
        auto imp = s.isImport();
        if (!imp || !imp.mod || !imp.mod.members || imp.isstatic)
            continue;
        auto vk = imp.visibility.kind;
        if (vk == Visibility.Kind.public_ || vk == Visibility.Kind.export_)
            indexModuleInterface(imp.mod, map, depth + 1);
    }
}

// Find an import-derived scope by local name: aliasId, static name, or id.
private Dsymbol findImportScope(Module root, const(char)[] name)
{
    if (!root || !root.members)
        return null;
    Dsymbol[] flat;
    flattenMembers(root.members, flat);
    foreach (s; flat)
    {
        auto imp = s.isImport();
        if (!imp || !imp.mod)
            continue;
        if (imp.aliasId && imp.aliasId.toString() == name)
            return imp.mod;
        if (imp.isstatic)
        {
            if (imp.id && imp.id.toString() == name)
                return imp.mod;
            if (imp.packages.length > 0 && imp.packages[0].toString() == name)
                return imp.mod;
        }
    }
    return null;
}

// Semantic-tree slot collection: surviving VarDeclarations plus
// condition variables (`if (auto x = ...)`, `while`, `switch`, `with`,
// `foreach`), which live in statement/parameter nodes rather than bodies.
private void collectSemSlots(Statement s, uint cursorLine, ref NameType[] r)
{
    if (!s || s.loc.linnum() > cursorLine)
        return;
    if (auto es = s.isExpStatement())
    {
        if (es.exp)
        {
            if (auto de = es.exp.isDeclarationExp())
            {
                if (auto vd = de.declaration.isVarDeclaration())
                {
                    if (vd.ident && vd.loc.linnum() <= cursorLine)
                        r ~= NameType(vd.ident.toString(), vd.type, null, vd);
                }
            }
        }
        return;
    }
    if (auto cs = s.isCompoundStatement())
    {
        for (size_t i = 0; i < cs.statements.length; i++)
            collectSemSlots(cs.statements[i], cursorLine, r);
        return;
    }
    if (auto ss = s.isScopeStatement())
    {
        collectSemSlots(ss.statement, cursorLine, r);
        return;
    }
    if (auto is_ = s.isIfStatement())
    {
        if (is_.param && is_.param.ident)
            r ~= NameType(is_.param.ident.toString(), is_.param.type, null, null);
        collectSemSlots(is_.ifbody, cursorLine, r);
        collectSemSlots(is_.elsebody, cursorLine, r);
        return;
    }
    if (auto ws = s.isWhileStatement())
    {
        if (ws.param && ws.param.ident)
            r ~= NameType(ws.param.ident.toString(), ws.param.type, null, null);
        collectSemSlots(ws._body, cursorLine, r);
        return;
    }
    if (auto ds = s.isDoStatement())
    {
        collectSemSlots(ds._body, cursorLine, r);
        return;
    }
    if (auto fs = s.isForStatement())
    {
        collectSemSlots(fs._init, cursorLine, r);
        collectSemSlots(fs._body, cursorLine, r);
        return;
    }
    if (auto fes = s.isForeachStatement())
    {
        if (fes.parameters)
            foreach (i; 0 .. fes.parameters.length)
            {
                auto fp = (*fes.parameters)[i];
                if (fp && fp.ident)
                    r ~= NameType(fp.ident.toString(), fp.type, null, null);
            }
        if (fes.key && fes.key.ident)
            r ~= NameType(fes.key.ident.toString(), fes.key.type, null, fes.key);
        if (fes.value && fes.value.ident)
            r ~= NameType(fes.value.ident.toString(), fes.value.type, null, fes.value);
        collectSemSlots(fes._body, cursorLine, r);
        return;
    }
    if (auto sw = s.isSwitchStatement())
    {
        if (sw.param && sw.param.ident)
            r ~= NameType(sw.param.ident.toString(), sw.param.type, null, null);
        collectSemSlots(sw._body, cursorLine, r);
        return;
    }
    if (auto tf = s.isTryFinallyStatement())
    {
        collectSemSlots(tf._body, cursorLine, r);
        collectSemSlots(tf.finalbody, cursorLine, r);
        return;
    }
    if (auto tc = s.isTryCatchStatement())
    {
        collectSemSlots(tc._body, cursorLine, r);
        if (tc.catches)
            foreach (i; 0 .. (*tc.catches).length)
            {
                auto c = (*tc.catches)[i];
                if (c.var && c.var.ident)
                    r ~= NameType(c.var.ident.toString(), c.var.type, null, c.var);
                collectSemSlots(c.handler, cursorLine, r);
            }
        return;
    }
    if (auto w = s.isWithStatement())
    {
        if (w.prm && w.prm.ident)
            r ~= NameType(w.prm.ident.toString(), w.prm.type, null, null);
        collectSemSlots(w._body, cursorLine, r);
        return;
    }
    if (auto sy = s.isSynchronizedStatement())
    {
        collectSemSlots(sy._body, cursorLine, r);
        return;
    }
}

// In-scope names for dotted LHS resolution: semantic params + surviving
// body vars (typed), then pre-semantic snapshot names (untyped) as fill.
private void collectSlots(Module mod, const ref SynMod syn, uint line,
    FuncDeclaration fd, ref NameType[] slots)
{
    bool has(const(char)[] n)
    {
        foreach (ref sl; slots)
            if (sl.name == n)
                return true;
        return false;
    }
    if (fd && fd.parameters)
        foreach (i; 0 .. fd.parameters.length)
        {
            VarDeclaration v = (*fd.parameters)[i];
            if (!v || !v.ident)
                continue;
            if (v.loc.linnum() > line)
                continue;
            const(char)[] nm = v.ident.toString();
            if (has(nm))
                continue;
            slots ~= NameType(nm, v.type, null, v);
        }
    if (fd && fd.fbody)
    {
        NameType[] surv;
        collectSemSlots(fd.fbody, line, surv);
        foreach (ref sl; surv)
        {
            if (has(sl.name))
                continue;
            slots ~= sl;
        }
    }
    auto sfn = synFuncAt(syn, line);
    if (sfn)
    {
        foreach (pi, pn; sfn.params)
        {
            if (has(pn))
                continue;
            string tn = pi < sfn.paramTypes.length ? sfn.paramTypes[pi] : null;
            slots ~= NameType(pn, null, tn, null);
        }
        foreach (ref vl; sfn.vars)
        {
            if (vl.line > line || has(vl.name))
                continue;
            slots ~= NameType(vl.name, null, vl.typeName, null);
        }
    }
}

// ---------- signature help ----------
struct SigParam
{
    const(char)[] label; // substring of the signature label
    uint start = 0;      // offset of label within the signature label
    uint end = 0;
    const(char)[] doc;
}

struct SignatureInfo
{
    bool found = false;
    const(char)[] label; // e.g. "int dist(Point p, int extra)"
    const(char)[] doc;
    SigParam[] params;
    int activeParameter = 0;
}

private bool isCalleeChar(char c) pure nothrow @nogc @safe
{
    return c == '_' || c == '.' || c == '!' || (c >= 'a' && c <= 'z') ||
        (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
}

// Byte offset of a 1-based (line, col) position.
private size_t lineColToOffset(const(char)[] text, uint line, uint col)
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
    return i;
}

private void buildFuncSignature(Arena* a, FuncDeclaration fd, ref SignatureInfo si)
{
    auto tf = fd.type ? fd.type.isTypeFunction() : null;
    if (!tf)
        return;
    import core.stdc.string : strlen;
    char[] buf;
    if (tf.next)
    {
        const(char)* rt = tf.next.toChars();
        if (rt)
        {
            buf ~= rt[0 .. strlen(rt)];
            buf ~= " ";
        }
    }
    if (fd.ident)
        buf ~= fd.ident.toString();
    buf ~= "(";
    if (tf.parameterList.parameters)
        foreach (i; 0 .. (*tf.parameterList.parameters).length)
        {
            auto p = (*tf.parameterList.parameters)[i];
            if (!p)
                continue;
            if (si.params.length)
                buf ~= ", ";
            uint start = cast(uint)buf.length;
            if (p.type)
            {
                const(char)* ts = p.type.toChars();
                if (ts)
                    buf ~= ts[0 .. strlen(ts)];
            }
            if (p.ident)
            {
                buf ~= " ";
                buf ~= p.ident.toString();
            }
            uint end = cast(uint)buf.length;
            si.params ~= SigParam(arenaDupStr(a, buf[start .. end]), start, end, null);
        }
    if (tf.parameterList.varargs != VarArg.none)
    {
        if (si.params.length)
            buf ~= ", ";
        buf ~= "...";
    }
    buf ~= ")";
    si.label = arenaDupStr(a, buf);
    si.doc = docOf(fd);
    si.found = true;
}

private void buildStructSignature(Arena* a, AggregateDeclaration ad, ref SignatureInfo si)
{
    if (ad.ctor)
        if (auto cf = ad.ctor.isFuncDeclaration())
        {
            buildFuncSignature(a, cf, si);
            if (si.found)
                return;
        }
    import core.stdc.string : strlen;
    char[] buf;
    if (ad.ident)
        buf ~= ad.ident.toString();
    buf ~= "(";
    foreach (i; 0 .. ad.fields.length)
    {
        auto vd = ad.fields[i];
        if (!vd || !vd.ident)
            continue;
        if (si.params.length)
            buf ~= ", ";
        uint start = cast(uint)buf.length;
        if (vd.type)
        {
            const(char)* ts = vd.type.toChars();
            if (ts)
                buf ~= ts[0 .. strlen(ts)];
        }
        buf ~= " ";
        buf ~= vd.ident.toString();
        uint end = cast(uint)buf.length;
        si.params ~= SigParam(arenaDupStr(a, buf[start .. end]), start, end, docOf(vd));
    }
    buf ~= ")";
    si.label = arenaDupStr(a, buf);
    si.doc = docOf(ad);
    si.found = true;
}

// Resolve the callee chain (no index/template args) to its declaration.
private Dsymbol resolveCallee(Module root, const(char)[][] segs, Dsymbol[] rootMembers,
    NameType[] locals)
{
    if (!segs.length)
        return null;
    if (segs.length == 1)
    {
        foreach (v; locals)
            if (v.name == segs[0])
                return null; // local function pointer: not resolved (v1)
        auto m = findMember(rootMembers, segs[0]);
        if (!m)
            m = findImportMember(root, segs[0]);
        return m;
    }
    Dsymbol[] scope_ = resolveLhs(root, segs[0 .. $ - 1], rootMembers, locals);
    if (!scope_.length)
        return null;
    return findMember(scope_, segs[$ - 1]);
}

// Signature help for the call/struct-literal argument list at the cursor.
void signatureAt(Arena* arena, Module mod, const CompleteCtx* ctx,
    const(char)[] text, const ref SynMod syn, ref SignatureInfo out_)
{
    if (!mod || !mod.members)
        return;
    if (!posInCode(text, ctx.line, ctx.character))
        return;
    size_t cursor = lineColToOffset(text, ctx.line, ctx.character);
    if (cursor > text.length)
        cursor = text.length;

    // Scan to the cursor tracking the innermost open argument list, and
    // count top-level commas for the active parameter.
    struct Frame
    {
        size_t pos;
        uint commas;
    }
    Frame[64] stk;
    size_t sp = 0;
    size_t i = 0;
    while (i < cursor)
    {
        char c = text[i];
        if (c == '/' && i + 1 < cursor && text[i + 1] == '/')
        {
            while (i < cursor && text[i] != '\n')
                i++;
            continue;
        }
        if (c == '/' && i + 1 < cursor && text[i + 1] == '*')
        {
            i += 2;
            while (i + 1 < cursor && !(text[i] == '*' && text[i + 1] == '/'))
                i++;
            i += 2;
            continue;
        }
        if (c == '"' || c == '\'' || c == '`')
        {
            char q = c;
            i++;
            while (i < cursor && text[i] != q)
            {
                if (text[i] == '\\' && q != '`')
                    i++;
                i++;
            }
            i++;
            continue;
        }
        if (c == '(')
        {
            if (sp < stk.length)
            {
                stk[sp] = Frame(i, 0);
                sp++;
            }
        }
        else if (c == ')')
        {
            if (sp)
                sp--;
        }
        else if (c == ',' && sp)
            stk[sp - 1].commas++;
        i++;
    }
    if (!sp)
        return; // cursor not inside a call argument list
    auto frame = stk[sp - 1];
    out_.activeParameter = cast(int)frame.commas;

    // Callee text immediately before the '('.
    size_t e = frame.pos;
    while (e > 0 && (text[e - 1] == ' ' || text[e - 1] == '\t' || text[e - 1] == '\n'))
        e--;
    size_t s = e;
    while (s > 0 && isCalleeChar(text[s - 1]))
        s--;
    auto callee = text[s .. e];
    if (!callee.length)
        return;
    // Drop template arguments (`foo!int` -> `foo`).
    size_t bang = callee.length;
    foreach (k, ch; callee)
        if (ch == '!')
        {
            bang = k;
            break;
        }
    callee = callee[0 .. bang];
    if (!callee.length)
        return;
    const(char)[][] segs;
    size_t ss = 0;
    foreach (k; 0 .. callee.length + 1)
    {
        if (k == callee.length || callee[k] == '.')
        {
            if (k > ss)
                segs ~= callee[ss .. k];
            ss = k + 1;
        }
    }
    if (!segs.length)
        return;

    Dsymbol[] rootMembers;
    flattenMembers(mod.members, rootMembers);
    NameType[] slots;
    collectSlots(mod, syn, ctx.line, findEnclosingFunc(mod, ctx.line), slots);
    auto sym = resolveCallee(mod, segs, rootMembers, slots);
    if (!sym)
        return;
    if (auto fd = sym.isFuncDeclaration())
        buildFuncSignature(arena, fd, out_);
    else if (auto ad = sym.isAggregateDeclaration())
        buildStructSignature(arena, ad, out_);
    else if (auto td = sym.isTemplateDeclaration())
    {
        // Best effort: first function member of the template.
        if (td.members)
            foreach (k; 0 .. (*td.members).length)
                if (auto fd = (*td.members)[k].isFuncDeclaration())
                {
                    buildFuncSignature(arena, fd, out_);
                    break;
                }
    }
}

// ---------- goto definition ----------
struct DefLoc
{
    bool found = false;
    const(char)[] file; // absolute path (arena)
    uint line = 0;      // 1-based
    uint col = 0;       // 1-based
    size_t len = 0;     // identifier length at the definition (for the range)
}

// Slice of `text` for 1-based `line`, without its trailing newline. `starts`
// is the line-start offset table (starts[0] == 0).
private const(char)[] lineSlice(const(char)[] text, const(size_t)[] starts,
    uint line)
{
    if (line == 0 || line > starts.length)
        return null;
    size_t s = starts[line - 1];
    size_t e = line < starts.length ? starts[line] : text.length;
    if (e > s && text[e - 1] == '\n')
        e--;
    if (e > s && text[e - 1] == '\r')
        e--;
    return text[s .. e];
}

// Full chain ending at the identifier at 1-based `col` within `lt` (a single
// line). The cursor's own segment is found by expanding over identifier
// chars only (so hovering `allocator` in `allocator.create` targets
// `allocator`, not `create`); the prefix is then extended back over the chain.
private const(char)[] chainInLine(const(char)[] lt, uint col)
{
    size_t e = col - 1;
    if (e > lt.length)
        e = lt.length;
    size_t segS = e;
    while (segS > 0 && isPc(lt[segS - 1]))
        segS--;
    size_t segE = e;
    while (segE < lt.length && isPc(lt[segE]))
        segE++;
    if (segE == segS)
        return null; // cursor is not on an identifier
    size_t s = segS;
    while (s > 0 && isChainChar(lt[s - 1]))
        s--;
    return lt[s .. segE];
}

private const(char)[] chainUnderCursor(const(char)[] text, uint line, uint col)
{
    size_t i = 0;
    uint l = 1;
    while (i < text.length && l < line)
    {
        if (text[i] == '\n')
            l++;
        i++;
    }
    size_t ls = i;
    while (i < text.length && text[i] != '\n')
        i++;
    return chainInLine(text[ls .. i], col);
}

// Name -> first member, for O(1) single-segment lookups (the common case
// when highlighting every identifier).
private void indexMembers(Dsymbol[] members, ref Dsymbol[const(char)[]] map)
{
    foreach (m; members)
    {
        if (!m || !m.ident)
            continue;
        auto id = m.ident.toString();
        if (id !in map)
            map[id] = m;
    }
}

// Resolve a dotted chain against hoisted module members and in-scope locals.
// Split out of resolveSymbolAt so callers resolving many positions (semantic
// highlighting) can flatten the module / collect locals once.
private Dsymbol resolveChain(Module mod, const(char)[] chain, Dsymbol[] rootMembers,
    Dsymbol[const(char)[]] rootByName, Dsymbol[const(char)[]] importByName,
    NameType[] locals, FuncDeclaration fd)
{
    if (!chain.length)
        return null;

    const(char)[][] segs;
    size_t s = 0;
    foreach (k; 0 .. chain.length + 1)
    {
        if (k == chain.length || chain[k] == '.')
        {
            auto bn = baseName(chain[s .. k]);
            if (bn.length)
                segs ~= bn;
            s = k + 1;
        }
    }
    if (!segs.length)
        return null;

    Dsymbol sym = null;
    if (segs.length == 1)
    {
        foreach (v; locals)
            if (v.sym && v.name == segs[0])
            {
                sym = v.sym;
                break;
            }
        if (!sym && fd && fd.ident && fd.ident.toString() == segs[0])
            sym = fd; // recursive call
        if (!sym)
        {
            if (auto p = segs[0] in rootByName)
                sym = *p;
            else
                sym = findMember(rootMembers, segs[0]);
        }
        if (!sym)
            if (auto p = segs[0] in importByName)
                sym = *p;
    }
    else
    {
        Dsymbol[] scope_ = resolveLhs(mod, segs[0 .. $ - 1], rootMembers, locals);
        if (scope_.length)
            sym = findMember(scope_, segs[$ - 1]);
    }
    if (!sym)
        return null;

    auto t = sym.toAlias();
    if (t && t !is sym)
        sym = t;
    return sym;
}

// Jump target for the symbol under the cursor: locals/params, module
// members, imported names, or members of a resolved dotted chain.
// Resolve the symbol under the cursor: locals/params, module members,
// imported names (incl. public re-exports), or members of a dotted chain.
// Aliases are followed to their target.
private Dsymbol resolveSymbolAt(Module mod, const ref SynMod syn, uint line,
    uint character, const(char)[] text)
{
    if (!mod || !mod.members)
        return null;
    if (!posInCode(text, line, character))
        return null;
    auto chain = chainUnderCursor(text, line, character);
    if (!chain.length)
        return null;

    Dsymbol[] rootMembers;
    flattenMembers(mod.members, rootMembers);
    Dsymbol[const(char)[]] rootByName;
    indexMembers(rootMembers, rootByName);
    Dsymbol[const(char)[]] importByName;
    indexImportInterfaces(mod, importByName);
    NameType[] locals;
    auto fd = findEnclosingFunc(mod, line);
    collectSlots(mod, syn, line, fd, locals);
    return resolveChain(mod, chain, rootMembers, rootByName, importByName, locals, fd);
}

// Batch resolution for semantic highlighting: one Dsymbol per 1-based
// (lines[i], cols[i]) position, null where unresolved. Assumes every
// position is real code (the caller's scanner skips comments/strings), so
// the per-position posInCode scan is skipped; module flattening is hoisted
// and locals are recomputed only when the line changes.
void resolveSymbolsBatch(Module mod, const ref SynMod syn, const(char)[] text,
    const(uint)[] lines, const(uint)[] cols, ref Dsymbol[] out_)
{
    out_.length = lines.length;
    if (!mod || !mod.members)
        return;
    Dsymbol[] rootMembers;
    flattenMembers(mod.members, rootMembers);
    Dsymbol[const(char)[]] rootByName;
    indexMembers(rootMembers, rootByName);
    Dsymbol[const(char)[]] importByName;
    indexImportInterfaces(mod, importByName);
    // Line-start offsets so each position maps to its line in O(1) instead
    // of rescanning the document from the top (O(tokens * size)).
    size_t[] lineStart = [size_t(0)];
    foreach (k, ch; text)
        if (ch == '\n')
            lineStart ~= k + 1;
    // Function ranges once, so line -> enclosing function is a flat scan.
    FuncRange[] funcs;
    foreach (i; 0 .. (*mod.members).length)
    {
        auto m = (*mod.members)[i];
        if (auto fd = m.isFuncDeclaration())
        {
            uint sl = fd.loc.linnum();
            if (sl >= 1)
                funcs ~= FuncRange(sl, fd.endloc.linnum(), 0, fd);
        }
        collectFuncRanges(m, 1, funcs);
    }
    uint lastLine = uint.max;
    FuncDeclaration fd;
    FuncDeclaration cachedFd;
    bool haveCached = false;
    NameType[] locals;
    foreach (i; 0 .. lines.length)
    {
        auto chain = chainInLine(lineSlice(text, lineStart, lines[i]), cols[i]);
        if (!chain.length)
            continue;
        if (lines[i] != lastLine)
        {
            lastLine = lines[i];
            fd = enclosingFunc(funcs, lines[i]);
        }
        // Locals depend on position; recompute only when the enclosing
        // function changes (at its end line, i.e. the full local set).
        if (!haveCached || fd !is cachedFd)
        {
            haveCached = true;
            cachedFd = fd;
            locals = null;
            uint slotLine = lines[i];
            if (fd)
            {
                uint el = fd.endloc.linnum();
                if (el >= slotLine)
                    slotLine = el;
            }
            collectSlots(mod, syn, slotLine, fd, locals);
        }
        out_[i] = resolveChain(mod, chain, rootMembers, rootByName, importByName,
            locals, fd);
    }
}

private size_t lastSegLen(const(char)[] chain)
{
    size_t s = chain.length;
    while (s > 0 && chain[s - 1] != '.')
        s--;
    return baseName(chain[s .. $]).length;
}

void definitionAt(Arena* arena, Module mod, const CompleteCtx* ctx,
    const(char)[] text, const ref SynMod syn, ref DefLoc out_)
{
    auto sym = resolveSymbolAt(mod, syn, ctx.line, ctx.character, text);
    if (!sym)
        return;
    auto loc = sym.loc;
    const(char)* f = loc.filename();
    if (!f)
        return;
    import core.stdc.string : strlen;
    out_.found = true;
    out_.file = arenaDupStr(arena, f[0 .. strlen(f)]);
    out_.line = loc.linnum();
    out_.col = loc.charnum();
    out_.len = lastSegLen(chainUnderCursor(text, ctx.line, ctx.character));
}

// ---------- hover ----------
struct HoverInfo
{
    bool found = false;
    const(char)[] detail; // declaration line for a ```d block
    const(char)[] doc;    // doc comment, if any
}

private const(char)[] declLine(Arena* a, Dsymbol sym)
{
    import core.stdc.string : strlen;
    char[] buf;
    if (auto vd = sym.isVarDeclaration())
    {
        if (vd.type)
        {
            const(char)* t = vd.type.toChars();
            if (t)
            {
                buf ~= t[0 .. strlen(t)];
                buf ~= " ";
            }
        }
        if (sym.ident)
            buf ~= sym.ident.toString();
    }
    else if (auto fd = sym.isFuncDeclaration())
    {
        auto tf = fd.type ? fd.type.isTypeFunction() : null;
        if (tf)
        {
            if (tf.next)
            {
                const(char)* rt = tf.next.toChars();
                if (rt)
                {
                    buf ~= rt[0 .. strlen(rt)];
                    buf ~= " ";
                }
            }
            if (sym.ident)
                buf ~= sym.ident.toString();
            buf ~= funcParamList(a, tf, true);
        }
        else if (fd.type)
        {
            const(char)* t = fd.type.toChars();
            if (t)
                buf ~= t[0 .. strlen(t)];
        }
    }
    else if (sym.ident)
    {
        const(char)* k = sym.kind();
        if (k)
            buf ~= k[0 .. strlen(k)];
        buf ~= " ";
        buf ~= sym.ident.toString();
    }
    else
    {
        const(char)* k = sym.kind();
        if (k)
            buf ~= k[0 .. strlen(k)];
    }
    return arenaDupStr(a, buf);
}

// Full declaration rendered by dmd itself (hdrgen) — no source reading or
// brace-matching needed; works for any symbol.
private const(char)[] hdrgenDecl(Arena* a, Dsymbol sym)
{
    import dmd.hdrgen : toCBuffer, HdrGenState;
    import dmd.common.outbuffer : OutBuffer;

    HdrGenState hgs;
    hgs.hdrgen = true;
    hgs.doFuncBodies = false;
    OutBuffer buf;
    buf.doindent = 1;
    buf.spaces = true;
    toCBuffer(sym, buf, hgs);
    return arenaDupStr(a, buf.opSlice());
}

void hoverAt(Arena* arena, Module mod, const CompleteCtx* ctx,
    const(char)[] text, const ref SynMod syn, ref HoverInfo out_)
{
    auto sym = resolveSymbolAt(mod, syn, ctx.line, ctx.character, text);
    if (!sym)
        return;
    // Prefer dmd's own declaration renderer for functions/types/templates/
    // aliases. Not for variables (hdrgen is header form: `extern int gval;`,
    // and locals become `extern S s;`) nor Module (it would dump the file).
    out_.detail = declLine(arena, sym);
    if (!sym.isVarDeclaration() && !sym.isModule())
    {
        if (auto hd = hdrgenDecl(arena, sym))
            if (hd.length)
                out_.detail = hd;
    }
    out_.doc = arenaDupStr(arena, docOf(sym));
    out_.found = out_.detail.length > 0 || out_.doc.length > 0;
}

// ---------- entry ----------
// If the cursor sits in the symbol list of a selective import
// (`import mod : a, b|`), return that Import (with a loaded module).
private Import selectiveImportAt(Module mod, const(char)[] text, const CompleteCtx* ctx)
{
    if (!mod || !mod.members)
        return null;
    // Current line up to the cursor.
    size_t i = 0;
    uint l = 1;
    while (i < text.length && l < ctx.line)
    {
        if (text[i] == '\n')
            l++;
        i++;
    }
    size_t ls = i;
    size_t e = ls;
    for (uint c = 1; c < ctx.character && e < text.length && text[e] != '\n'; c++)
        e++;
    auto line = text[ls .. e];
    // Last ':' on the line, with an `import` keyword before it and no `;`
    // in between.
    size_t colon = size_t.max;
    for (size_t k = line.length; k > 0; k--)
        if (line[k - 1] == ':')
        {
            colon = k - 1;
            break;
        }
    if (colon == size_t.max)
        return null;
    auto head = line[0 .. colon];
    size_t imp = size_t.max;
    foreach (k; 0 .. head.length)
        if (k + 6 <= head.length && head[k .. k + 6] == "import" &&
            (k == 0 || !isPc(head[k - 1])) &&
            (k + 6 == head.length || !isPc(head[k + 6])))
        {
            imp = k;
            break;
        }
    if (imp == size_t.max)
        return null;
    foreach (k; imp .. colon)
        if (head[k] == ';')
            return null;
    // The Import declared on this line.
    Dsymbol[] flat;
    flattenMembers(mod.members, flat);
    foreach (s; flat)
        if (auto imp2 = s.isImport())
            if (imp2.loc.linnum() == ctx.line && imp2.mod)
                return imp2;
    return null;
}

// True when the cursor is in the module list of an import statement
// (`import mo|` / `import std.st|`), i.e. an `import` keyword precedes it
// and the statement hasn't reached a `;` or a selective `:` yet.
private bool inImportModuleList(const(char)[] text, const CompleteCtx* ctx)
{
    size_t i = 0;
    uint l = 1;
    while (i < text.length && l < ctx.line)
    {
        if (text[i] == '\n')
            l++;
        i++;
    }
    size_t ls = i;
    size_t e = ls;
    for (uint c = 1; c < ctx.character && e < text.length && text[e] != '\n'; c++)
        e++;
    auto line = text[ls .. e];
    size_t imp = size_t.max;
    foreach (k; 0 .. line.length)
        if (k + 6 <= line.length && line[k .. k + 6] == "import" &&
            (k == 0 || !isPc(line[k - 1])) &&
            (k + 6 == line.length || !isPc(line[k + 6])))
            imp = k;
    if (imp == size_t.max)
        return false;
    foreach (k; imp .. line.length)
    {
        if (line[k] == ';')
            return false; // statement ended
        if (line[k] == ':')
            return false; // selective symbol list follows
    }
    return true;
}

// Module-qualified completion: `import rt.dbg;` makes `rt.` list the next
// path segment and `rt.dbg.` list that module's members. Returns true when
// the chain is a module path (a prefix of, or exactly, an import's path).
private bool importPathCompletion(Arena* a, Module root, const(char)[][] segs,
    const(char)[] prefix, ref CompleteOut o, ref bool[const(char)[]] seen)
{
    if (!root || !root.members || !segs.length)
        return false;
    bool matched = false;
    Dsymbol[] flat;
    flattenMembers(root.members, flat);
    foreach (s; flat)
    {
        auto imp = s.isImport();
        if (!imp || imp.aliasId) // aliased imports use their alias name
            continue;
        const(char)[][32] parts;
        size_t np = 0;
        foreach (p; imp.packages)
            if (np < parts.length)
                parts[np++] = p.toString();
        if (imp.id && np < parts.length)
            parts[np++] = imp.id.toString();
        if (!np)
            continue;
        size_t m = 0;
        while (m < segs.length && m < np && segs[m] == parts[m])
            m++;
        if (m != segs.length)
            continue;
        matched = true;
        if (segs.length == np)
        {
            if (!imp.mod)
                continue;
            foreach (mem; scopeMembers(imp.mod))
            {
                if (!mem.ident)
                    continue;
                if (mem.visible().kind == Visibility.Kind.private_)
                    continue;
                auto nm = mem.ident.toString();
                if (!hasPrefix(nm, prefix))
                    continue;
                pushItem(a, o, nm, kindOf(mem), typeDetail(symType(mem)),
                    docOf(mem), "1", seen, mem);
                if (o.nitems >= 500)
                    break;
            }
        }
        else
        {
            auto next = parts[segs.length];
            if (hasPrefix(next, prefix))
                pushItem(a, o, next, 9, "module", null, "1", seen);
        }
    }
    return matched;
}

void completeAt(Arena* arena, Module mod, const CompleteCtx* ctx,
    const(char)[] text, const ref SynMod syn, ref CompleteOut out_)
{
    if (!mod || !mod.members)
        return;
    if (!posInCode(text, ctx.line, ctx.character))
        return; // inside comment/string: no completion
    bool[const(char)[]] seen;

    auto chain = extractChain(text, ctx.line, ctx.character);
    const(char)[] prefix = ctx.prefix;
    // Split chain on last dot.
    const(char)[] lhs = null;
    bool hasDot = false;
    if (chain.length)
    {
        size_t dot = chain.length;
        while (dot > 0 && chain[dot - 1] != '.')
            dot--;
        if (dot > 0)
        {
            hasDot = true;
            lhs = chain[0 .. dot - 1];
            prefix = chain[dot .. $];
        }
    }

    // Selective import symbol list: `import mod : sym1, sym|` -> offer the
    // imported module's own members.
    if (auto imp = selectiveImportAt(mod, text, ctx))
    {
        foreach (m; scopeMembers(imp.mod))
        {
            if (!m.ident)
                continue;
            if (m.visible().kind == Visibility.Kind.private_)
                continue;
            auto nm = m.ident.toString();
            if (!hasPrefix(nm, prefix))
                continue;
            pushItem(arena, out_, nm, kindOf(m), typeDetail(symType(m)),
                docOf(m), "1", seen, m);
            if (out_.nitems >= 500)
                break;
        }
        return;
    }

    // Module name(s) of an import: nothing useful to offer.
    if (inImportModuleList(text, ctx))
        return;

    // Semantic function (params with types + surviving body vars).
    auto fd = findEnclosingFunc(mod, ctx.line);
    // Snapshot function (pre-semantic names; survives error rewrites).
    auto sfn = synFuncAt(syn, ctx.line);

    NameType[] slots;
    collectSlots(mod, syn, ctx.line, fd, slots);

    if (!hasDot)
    {
        // Plain: emit typed items first, then untyped snapshot names.
        if (fd)
            collectInFunc(fd, ctx.line, prefix, arena, out_, seen);
        if (sfn)
        {
            foreach (i, pn; sfn.params)
            {
                if (pn in seen)
                    continue;
                if (!hasPrefix(pn, prefix))
                    continue;
                string tn = i < sfn.paramTypeTexts.length ? sfn.paramTypeTexts[i] : null;
                if (!tn.length)
                    tn = i < sfn.paramTypes.length ? sfn.paramTypes[i] : null;
                pushItem(arena, out_, pn, 6, "parameter", null, "0", seen, null, tn);
            }
            foreach (ref vl; sfn.vars)
            {
                if (vl.line > ctx.line || vl.name in seen)
                    continue;
                if (!hasPrefix(vl.name, prefix))
                    continue;
                pushItem(arena, out_, vl.name, 6, "local", null, "0", seen, null,
                    vl.typeText.length ? vl.typeText : vl.typeName);
            }
        }
    }

    if (hasDot)
    {
        // Dotted: resolve LHS scope, complete its members by prefix.
        const(char)[][] segs;
        size_t s = 0;
        foreach (i; 0 .. lhs.length + 1)
        {
            if (i == lhs.length || lhs[i] == '.')
            {
                if (i > s)
                    segs ~= lhs[s .. i];
                s = i + 1;
            }
        }
        Dsymbol[] rootMembers;
        flattenMembers(mod.members, rootMembers);
        // Module-qualified access from imports (`rt.` -> `dbg`, `rt.dbg.` ->
        // its members), for both plain and `static import`.
        if (importPathCompletion(arena, mod, segs, prefix, out_, seen))
            return;
        auto scope_ = resolveLhs(mod, segs, rootMembers, slots);
        if (!scope_.length)
        {
            out_.incomplete = true;
            return;
        }
        foreach (m; scope_)
        {
            if (!m.ident)
                continue;
            if (m.visible().kind == Visibility.Kind.private_)
                continue;
            const(char)[] nm = m.ident.toString();
            if (!hasPrefix(nm, prefix))
                continue;
            pushItem(arena, out_, nm, kindOf(m), typeDetail(symType(m)),
                docOf(m), "1", seen, m);
            if (out_.nitems >= 500)
                break;
        }
        return;
    }

    // Plain: locals already added; add module members + imports.
    {
        Dsymbol[] ms;
        flattenMembers(mod.members, ms);
        addMembers(arena, ms, prefix, "1", out_, seen);
    }
    walkImports(mod, 0, arena, prefix, out_, seen);
}

// Entry: offer the public interface of every module the root imports.
// The root can always see an imported module's public members *and*
// everything that module `public import`s, regardless of whether the
// root's own import statement is public (that only affects re-export).
private void walkImports(Module root, int depth, Arena* a, const(char)[] prefix,
    ref CompleteOut o, ref bool[const(char)[]] seen)
{
    if (!root || !root.members)
        return;
    Dsymbol[] flat;
    flattenMembers(root.members, flat);
    foreach (s; flat)
    {
        if (auto imp = s.isImport())
        {
            if (!imp.mod || imp.isstatic)
                continue; // static import: qualified access only
            addModuleInterface(imp.mod, depth, a, prefix, o, seen);
        }
    }
}

// Add `m`'s own members, then follow its `public import`s (and theirs).
private void addModuleInterface(Module m, int depth, Arena* a, const(char)[] prefix,
    ref CompleteOut o, ref bool[const(char)[]] seen)
{
    if (!m || depth > 4 || !m.members)
        return;
    addMembers(a, scopeMembers(m), prefix, "1", o, seen);
    Dsymbol[] flat;
    flattenMembers(m.members, flat);
    foreach (s; flat)
    {
        if (auto imp = s.isImport())
        {
            if (!imp.mod || imp.isstatic)
                continue;
            auto vk = imp.visibility.kind;
            if (vk == Visibility.Kind.public_ || vk == Visibility.Kind.export_)
                addModuleInterface(imp.mod, depth + 1, a, prefix, o, seen);
        }
    }
}

// True if (line,col) is in real code (not comment/string).
bool posInCode(const(char)[] text, uint line, uint col)
{
    size_t i = 0;
    uint l = 1;
    uint c = 1;
    while (i < text.length)
    {
        if (l == line && c >= col)
            return true; // reached cursor while in code
        char ch = text[i];
        if (ch == '\n')
        {
            i++;
            l++;
            c = 1;
            continue;
        }
        if (ch == '/' && i + 1 < text.length && text[i + 1] == '/')
        {
            while (i < text.length && text[i] != '\n')
            {
                if (l == line && c >= col)
                    return false;
                i++;
                c++;
            }
            continue;
        }
        if (ch == '/' && i + 1 < text.length && (text[i + 1] == '*' || text[i + 1] == '+'))
        {
            bool nest = text[i + 1] == '+';
            uint depth = 1;
            i += 2;
            c += 2;
            while (i < text.length && depth > 0)
            {
                if (l == line && c >= col)
                    return false;
                if (text[i] == '\n')
                {
                    l++;
                    c = 1;
                    i++;
                    continue;
                }
                if (!nest && text[i] == '*' && i + 1 < text.length && text[i + 1] == '/')
                {
                    depth--;
                    i += 2;
                    c += 2;
                    continue;
                }
                if (nest && text[i] == '/' && i + 1 < text.length && text[i + 1] == '+')
                {
                    depth++;
                    i += 2;
                    c += 2;
                    continue;
                }
                if (nest && text[i] == '+' && i + 1 < text.length && text[i + 1] == '/')
                {
                    depth--;
                    i += 2;
                    c += 2;
                    continue;
                }
                i++;
                c++;
            }
            continue;
        }
        if (ch == '"' || ch == '\'' || ch == '`' ||
            ((ch == 'r' || ch == 'R' || ch == 'q' || ch == 'Q') && i + 1 < text.length))
        {
            // Possible string start: handle " and ' precisely, bail-safe otherwise.
            if (ch == '"')
            {
                i++;
                c++;
                while (i < text.length && text[i] != '"' && text[i] != '\n')
                {
                    if (l == line && c >= col)
                        return false;
                    if (text[i] == '\\')
                    {
                        i++;
                        c++;
                    }
                    i++;
                    c++;
                }
                if (i < text.length && text[i] == '"')
                {
                    i++;
                    c++;
                }
                continue;
            }
            if (ch == '\'')
            {
                i++;
                c++;
                if (i < text.length && text[i] == '\\')
                {
                    i++;
                    c++;
                }
                while (i < text.length && text[i] != '\'' && text[i] != '\n')
                {
                    if (l == line && c >= col)
                        return false;
                    i++;
                    c++;
                }
                if (i < text.length && text[i] == '\'')
                {
                    i++;
                    c++;
                }
                continue;
            }
            // backtick / q-strings / r-strings: conservative — if cursor is
            // past such an opener on this line region, assume code (rare).
            i++;
            c++;
            continue;
        }
        i++;
        c++;
    }
    return true;
}

// Extract identifier prefix before (line,col) from text (1-based).
const(char)[] extractPrefix(const(char)[] text, uint line, uint col)
{
    size_t i = 0;
    uint l = 1;
    while (i < text.length && l < line)
    {
        if (text[i] == '\n')
            l++;
        i++;
    }
    size_t lineStart = i;
    while (i < text.length && text[i] != '\n')
        i++;
    auto lineText = text[lineStart .. i];
    size_t e = col - 1;
    if (e > lineText.length) // clamp overlong columns
        e = lineText.length;
    size_t s = e;
    while (s > 0 && isPc(lineText[s - 1]))
        s--;
    return lineText[s .. e];
}

private bool isPc(char c) pure nothrow @nogc @safe
{
    return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
}

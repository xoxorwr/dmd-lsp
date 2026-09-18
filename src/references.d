module references;

// textDocument/references + target resolution, semantic-only (PLAN.md Phase A).
//
// Identity comes exclusively from dmd's resolved AST. A use is a node that
// carries a resolved Dsymbol; a declaration is an AST declaration. Matching is
// by `DeclKey` so it is shadowing/overload correct and independent of the
// universe a symbol was resolved in. There is deliberately no lexer/scope
// re-resolution fallback: when a body collapsed, its uses are simply not
// reported (a false negative is acceptable; a guessed location is not).
//
// Struct-only, no phobos.

import dmd.dmodule : Module;
import dmd.dsymbol : Dsymbol;
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
import dmd.typesem : toBasetype;
import core.stdc.string : strlen;
import arena : Arena;
import session : sessionReadDisk;
import complete : appendScopeSubs;

// ---------- declaration identity ----------
// A declaration's identity, independent of the live pointer/universe it was
// resolved in, so a use resolved in one worker universe can be matched against
// a target resolved in another (importers analysed per module). `keyMatches`
// reproduces the folds the old pointer-based `sameTarget` applied.

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

// Collapse instance/wrapper layers to the declaration a rename would target:
// template instances and instantiated members map back to their template, and
// a function that is a template's single same-named member stands in for the
// template itself.
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
// source span, and a declaring module.
bool isRenameable(Dsymbol d)
{
    if (!d || !d.ident)
        return false;
    d = fold(d);
    if (!d || !d.ident || d.loc.linnum() < 1 || d.loc.charnum() < 1)
        return false;
    return moduleOf(d) !is null;
}

struct RefLoc
{
    string file;
    uint line; // 1-based
    uint col;  // 1-based
    uint len;
}

private bool isIdentChar(char c) pure nothrow @nogc @safe
{
    return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9');
}

// Uses of `target` reachable from `root`. Only modules that (transitively)
// import the target's declaring module can reference it, so the walk is
// narrowed to those plus the declaring module. Matching is by resolved
// declaration identity (see `keyMatches`).
RefLoc[] findReferences(Module root, Dsymbol target, bool includeDeclaration,
    const(char)[] rootPath = null, const(char)[] rootText = null)
{
    RefLoc[] out_;
    if (!root || !target)
        return out_;
    g_collect = false;
    g_keyMode = false;
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
    {
        if (!(m in canSee))
            continue;
        walkModule(m, target, includeDeclaration, out_, rootPath, rootText);
    }
    dedupe(out_);
    return out_;
}

// Uses of the declaration described by `key` in `mods`. Matching is by
// `DeclKey` only (no live `Dsymbol`), so the target can be resolved in one
// universe (the request) and the uses found in independently analysed ones
// (per-candidate-module workspace references).
RefLoc[] referencesForKey(Module[] mods, ref const DeclKey key, bool includeDecl,
    const(char)[] rootPath = null, const(char)[] rootText = null)
{
    RefLoc[] out_;
    if (!key.valid)
        return out_;
    g_collect = false;
    g_keyMode = true;
    g_key = key;
    foreach (m; mods)
    {
        if (!m)
            continue;
        walkModule(m, null, includeDecl, out_, rootPath, rootText);
    }
    dedupe(out_);
    g_keyMode = false;
    return out_;
}

// Merge two location lists, dropping duplicates.
RefLoc[] mergeRefs(RefLoc[] a, RefLoc[] b)
{
    a ~= b;
    dedupe(a);
    return a;
}

// The declaration symbol under a 1-based (line, col) cursor, resolved from the
// semantic AST. `text` is the module source (required for member accesses,
// whose AST node stores the receiver's location, not the member's). Returns
// null when the body is not semantic'd (collapsed) — the signal that rename
// must refuse.
Dsymbol resolvedSymbolAt(Module mod, uint line, uint col, const(char)[] text)
{
    if (!mod || !mod.members)
        return null;

    auto savedCollect = g_collect;
    auto savedHits = g_hits;
    auto savedFile = g_refFile;
    auto savedText = g_refText;
    auto savedSet = g_refTextSet;

    g_collect = true;
    g_hits = null;
    g_refFile = modulePath(mod);
    g_refText = text;
    g_refTextSet = true;

    RefLoc[] dummy;
    foreach (i; 0 .. (*mod.members).length)
        walkDecl((*mod.members)[i], null, false, dummy);

    Dsymbol best;
    foreach (h; g_hits)
    {
        if (!h.sym || !h.sym.ident)
            continue;
        if (h.line != line)
            continue;
        uint start = h.col;
        uint len = cast(uint) h.sym.ident.toString().length;
        if (start >= 1 && col >= start && col < start + len)
        {
            if (!spanVerified(h.line, h.col, h.sym.ident))
                continue; // generated symbol: not really at this position
            best = h.sym;
            break;
        }
    }

    g_collect = savedCollect;
    g_hits = savedHits;
    g_refFile = savedFile;
    g_refText = savedText;
    g_refTextSet = savedSet;
    return best;
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

private void walkModule(Module m, Dsymbol target, bool includeDecl, ref RefLoc[] out_,
    const(char)[] rootPath, const(char)[] rootText)
{
    if (!m.members)
        return;
    scopeRefText(m, rootPath, rootText);
    foreach (i; 0 .. (*m.members).length)
        walkDecl((*m.members)[i], target, includeDecl, out_);
}

// Canonical source path of a module: `arg` first (what dmd parsed), then the
// resolved `srcfile`. Backslashes are normalised to `/`.
private string modulePath(Module m)
{
    auto p = m.arg;
    if (!p.length)
        p = m.srcfile.toString();
    bool back = false;
    foreach (c; p)
        if (c == '\\')
        {
            back = true;
            break;
        }
    if (!back)
        return p.idup;
    char[] o;
    o.reserve(p.length);
    foreach (c; p)
        o ~= (c == '\\' ? '/' : c);
    return o.idup;
}

// ---------- current-module source scope (single-threaded worker) ----------

private const(char)[] g_refFile;
private const(char)[] g_refText;
private bool g_refTextSet;

private void scopeRefText(Module m, const(char)[] rootPath, const(char)[] rootText)
{
    g_refFile = modulePath(m);
    g_refText = null;
    g_refTextSet = false;
    if (rootPath !is null && rootText !is null && g_refFile == rootPath)
    {
        g_refText = rootText;
        g_refTextSet = true;
    }
}

private void ensureRefText()
{
    if (g_refTextSet)
        return;
    g_refTextSet = true;
    if (g_refFile.length)
        g_refText = sessionReadDisk(g_refFile);
}

// 1-based (line, col) -> byte offset.
private size_t refOffset(const(char)[] text, uint line, uint col)
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

private void offsetLineCol(const(char)[] text, size_t off, out uint line, out uint col)
{
    line = 1;
    col = 1;
    size_t n = off < text.length ? off : text.length;
    foreach (i; 0 .. n)
    {
        if (text[i] == '\n')
        {
            line++;
            col = 1;
        }
        else
            col++;
    }
}

// A source span is trustworthy only if the text at (line, col) actually
// spells `ident`. Mixin/CTFE-generated symbols get synthetic `Loc`s that point
// at unrelated source (e.g. a generated `printValue` reported inside `main`),
// which are valid-looking but have no real span. When the module text is
// unavailable we cannot check, so we keep the location (callers fall back).
private bool spanVerified(uint line, uint col, Identifier ident)
{
    if (line < 1 || col < 1 || !ident)
        return false;
    ensureRefText();
    if (!g_refText.length)
        return true;
    auto name = ident.toString();
    if (!name.length)
        return true;
    size_t off = refOffset(g_refText, line, col);
    if (off + name.length > g_refText.length)
        return false;
    foreach (k; 0 .. name.length)
        if (g_refText[off + k] != name[k])
            return false;
    return true;
}

private size_t indexOfFrom(const(char)[] hay, const(char)[] needle, size_t from)
{
    if (!needle.length || hay.length < needle.length)
        return size_t.max;
    for (size_t i = from; i + needle.length <= hay.length; i++)
    {
        bool ok = true;
        foreach (k; 0 .. needle.length)
            if (hay[i + k] != needle[k])
            {
                ok = false;
                break;
            }
        if (ok)
            return i;
    }
    return size_t.max;
}

// A 1-based source position.
private struct RefPos
{
    uint line;
    uint col;
}

// dmd stores a member access' receiver location in `DotVarExp.loc`, not the
// member's. Locate the member identifier as the first whole-word occurrence of
// `ident` after the receiver that is preceded (ignoring spaces/tabs) by a `.`.
// Falls back to the receiver location when the text is unavailable.
private RefPos usePos(Loc recv, Dsymbol sym)
{
    RefPos r = RefPos(recv.linnum(), recv.charnum());
    if (!sym || !sym.ident)
        return r;
    ensureRefText();
    if (!g_refText.length)
        return r;
    auto name = sym.ident.toString();
    if (!name.length)
        return r;
    size_t start = refOffset(g_refText, recv.linnum(), recv.charnum());
    size_t i = start;
    while (i < g_refText.length)
    {
        size_t j = indexOfFrom(g_refText, name, i);
        if (j == size_t.max)
            break;
        bool okL = j == 0 || !isIdentChar(g_refText[j - 1]);
        bool okR = j + name.length >= g_refText.length ||
            !isIdentChar(g_refText[j + name.length]);
        size_t k = j;
        while (k > 0 && (g_refText[k - 1] == ' ' || g_refText[k - 1] == '\t'))
            k--;
        bool afterDot = k > 0 && g_refText[k - 1] == '.';
        if (okL && okR && afterDot)
        {
            offsetLineCol(g_refText, j, r.line, r.col);
            return r;
        }
        i = j + name.length;
    }
    return r;
}

// ---------- semantic walk ----------

private struct Hit
{
    uint line;
    uint col;
    Dsymbol sym;
}

private Hit[] g_hits; // collect mode (resolvedSymbolAt)
private bool g_collect;
private DeclKey g_key; // key mode (referencesForKey)
private bool g_keyMode;

private bool isTarget(Dsymbol sym, Dsymbol target)
{
    if (!sym || !sym.ident)
        return false;
    if (g_keyMode)
    {
        // Cheap name filter before the allocating key comparison.
        if (sym.ident.toString() != g_key.name)
            return false;
        return keyMatches(declKey(sym), g_key);
    }
    return sameTarget(sym, target);
}

private void emitUse(Loc recv, Dsymbol sym, Dsymbol target, ref RefLoc[] out_)
{
    if (!sym)
        return;
    if (g_collect)
    {
        auto p = usePos(recv, sym);
        g_hits ~= Hit(p.line, p.col, sym);
        return;
    }
    if (!isTarget(sym, target))
        return;
    auto p = usePos(recv, sym);
    recordPos(p.line, p.col, sym.ident, out_);
}

private void emitDecl(Loc loc, Dsymbol d, Dsymbol target, bool includeDecl,
    ref RefLoc[] out_)
{
    if (!d.ident)
        return;
    if (g_collect)
    {
        g_hits ~= Hit(loc.linnum(), loc.charnum(), d);
        return;
    }
    if (!includeDecl || !isTarget(d, target))
        return;
    recordPos(loc.linnum(), loc.charnum(), d.ident, out_);
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
    emitDecl(d.loc, d, target, includeDecl, out_);

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
                emitDecl(p.loc, p, target, includeDecl, out_);
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
    if (auto ve = e.isVarExp())
        emitUse(e.loc, ve.var, target, out_);
    else if (auto dv = e.isDotVarExp())
        emitUse(e.loc, dv.var, target, out_);
    else if (auto so = e.isSymOffExp())
        emitUse(e.loc, so.var, target, out_);
    else if (auto ca = e.isCallExp())
    {
        // The callee is `e1` (walked below); some calls carry the resolved
        // function only in `ca.f` (templates/qualified), so record at the
        // callee identifier too. Dedupe folds the two paths.
        if (ca.f && ca.e1)
            emitUse(ca.e1.loc, ca.f, target, out_);
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
        emitUse(e.loc, typeSymbol(ne.newtype), target, out_);
        if (ne.arguments)
            foreach (a; *ne.arguments)
                walkExpr(a, target, out_);
        return;
    }
    else if (auto te = e.isTypeExp())
        emitUse(e.loc, typeSymbol(te.type), target, out_);
    else if (auto se = e.isScopeExp())
        emitUse(e.loc, se.sds, target, out_);
    else if (auto fe = e.isFuncExp())
        emitUse(e.loc, fe.fd ? cast(Dsymbol) fe.fd : cast(Dsymbol) fe.td, target, out_);
    else if (auto te = e.isTemplateExp())
        emitUse(e.loc, te.td, target, out_);
    else if (auto dte = e.isDotTemplateExp())
    {
        emitUse(e.loc, dte.td, target, out_);
        walkExpr(dte.e1, target, out_);
        return;
    }
    else if (auto dti = e.isDotTemplateInstanceExp())
    {
        emitUse(e.loc, dti.ti ? dti.ti.tempdecl : null, target, out_);
        walkExpr(dti.e1, target, out_);
        return;
    }
    else if (auto th = e.isThisExp())
        emitUse(e.loc, th.var, target, out_);

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

// The Dsymbol a type expression denotes (struct/class/enum/instance).
private Dsymbol typeSymbol(Type t)
{
    if (!t)
        return null;
    Type b = t.toBasetype();
    if (!b)
        return null;
    if (auto ts = b.isTypeStruct())
        return ts.sym;
    if (auto tc = b.isTypeClass())
        return tc.sym;
    if (auto te = b.isTypeEnum())
        return te.sym;
    if (auto ti = b.isTypeInstance())
        if (ti.tempinst)
            return ti.tempinst.tempdecl;
    return null;
}

private void recordPos(uint line, uint col, Identifier ident, ref RefLoc[] out_)
{
    if (line < 1 || col < 1)
        return;
    const(char)[] f = g_refFile;
    if (!f.length)
        return;
    if (!spanVerified(line, col, ident))
        return; // synthetic/generated location: no real source span
    uint len = ident ? cast(uint) ident.toString().length : 0;
    out_ ~= RefLoc(f.idup, line, col, len);
}

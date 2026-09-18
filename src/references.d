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
import dmd.declaration : VarDeclaration, AliasDeclaration;
import dmd.func : FuncDeclaration;
import dmd.denum : EnumDeclaration, EnumMember;
import dmd.dtemplate : TemplateDeclaration;
import dmd.expression : Expression, VarExp, DotVarExp, SymOffExp, CallExp,
    NewExp, TypeExp, ScopeExp, FuncExp, TemplateExp, DotTemplateExp,
    DotTemplateInstanceExp, ThisExp, StructLiteralExp, SliceExp, IntegerExp;
import dmd.visitor : SemanticTimeTransitiveVisitor;
import dmd.dstruct : StructDeclaration, UnionDeclaration;
import dmd.dclass : ClassDeclaration, InterfaceDeclaration;
import dmd.mtype : Type, TypeEnum;
import dmd.identifier : Identifier;
import dmd.location : Loc;
import dmd.typesem : toBasetype;
import core.stdc.string : strlen;
import session : sessionReadDisk;

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
    // Interned identifiers make a cheap reject before building (allocating)
    // keys; folding never changes the identifier.
    if (a.ident && b.ident && a.ident !is b.ident)
        return false;
    return keyMatches(declKey(a), declKey(b));
}

// True when `d` is a member of an aggregate (struct/class/union), i.e. a name
// that reflective __traits (allMembers/derivedMembers/getMember) could resolve
// without a source-level reference. Module-level symbols are not affected by
// those enumerators, and string mixins are expanded during semantic (their
// uses are already in the resolved AST), so they are not treated as risky.
bool isAggregateMember(Dsymbol d)
{
    for (Dsymbol p = d ? d.parent : null; p; p = p.parent)
    {
        if (p.isModule())
            return false;
        if (p.isAggregateDeclaration())
            return true;
    }
    return false;
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
    g_keyIdent = key.name.length ? Identifier.idPool(key.name) : null;
    foreach (m; mods)
    {
        if (!m)
            continue;
        walkModule(m, null, includeDecl, out_, rootPath, rootText);
    }
    dedupe(out_);
    g_keyMode = false;
    g_keyIdent = null;
    return out_;
}

// Merge two location lists, dropping duplicates.
RefLoc[] mergeRefs(RefLoc[] a, RefLoc[] b)
{
    a ~= b;
    dedupe(a);
    return a;
}

// A resolved occurrence under the cursor: the symbol plus the real source span
// of the identifier occurrence (a use site's span, not the declaration's).
struct Occurrence
{
    Dsymbol sym;
    uint line; // 1-based
    uint col;  // 1-based
    uint len;
}

// The identifier occurrence at a 1-based (line, col) cursor, resolved from the
// semantic AST. `text` is the module source (required for member accesses,
// whose AST node stores the receiver's location, not the member's). Returns a
// null `sym` when the body is not semantic'd (collapsed) — the signal that
// rename must refuse.
Occurrence occurrenceAt(Module mod, uint line, uint col, const(char)[] text)
{
    Occurrence occ;
    if (!mod || !mod.members)
        return occ;

    auto savedCollect = g_collect;
    auto savedHits = g_hits;
    auto savedFile = g_refFile;
    auto savedText = g_refText;
    auto savedSet = g_refTextSet;
    auto savedLines = g_lineStart;
    auto savedLinesReady = g_lineStartReady;

    g_collect = true;
    g_hits = null;
    g_refFile = modulePath(mod);
    g_refText = text;
    g_refTextSet = true;
    g_lineStart = null;
    g_lineStartReady = false;

    RefLoc[] dummy;
    scope RefWalker w = new RefWalker();
    w.target = null;
    w.includeDecl = false;
    w.out_ = dummy;
    foreach (i; 0 .. (*mod.members).length)
        (*mod.members)[i].accept(w);

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
            occ.sym = h.sym;
            occ.line = h.line;
            occ.col = h.col;
            occ.len = len;
            break;
        }
    }

    g_collect = savedCollect;
    g_hits = savedHits;
    g_refFile = savedFile;
    g_refText = savedText;
    g_refTextSet = savedSet;
    g_lineStart = savedLines;
    g_lineStartReady = savedLinesReady;
    return occ;
}

// The resolved declaration symbol under the cursor (see `occurrenceAt`).
Dsymbol resolvedSymbolAt(Module mod, uint line, uint col, const(char)[] text)
{
    return occurrenceAt(mod, line, col, text).sym;
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
    scope RefWalker w = new RefWalker();
    w.target = target;
    w.includeDecl = includeDecl;
    w.out_ = out_;
    foreach (i; 0 .. (*m.members).length)
        (*m.members)[i].accept(w);
    out_ = w.out_;
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
private size_t[] g_lineStart; // per-module line starts (lazy)
private bool g_lineStartReady;

private void scopeRefText(Module m, const(char)[] rootPath, const(char)[] rootText)
{
    g_refFile = modulePath(m);
    g_refText = null;
    g_refTextSet = false;
    g_lineStart = null;
    g_lineStartReady = false;
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
    g_lineStart = null;
    g_lineStartReady = false;
}

// Line-start offsets for `g_refText`, built once per module so (line,col) <->
// offset is cheap. The old scan-from-zero per lookup made references quadratic
// on large files (seconds and heavy allocation churn on the dmd frontend).
private void ensureLineStarts()
{
    if (g_lineStartReady)
        return;
    g_lineStartReady = true;
    ensureRefText();
    g_lineStart = null;
    if (!g_refText.length)
        return;
    g_lineStart ~= size_t(0);
    foreach (i, c; g_refText)
        if (c == '\n')
            g_lineStart ~= i + 1;
}

private size_t refOffsetFast(uint line, uint col)
{
    ensureLineStarts();
    if (line < 1 || col < 1 || !g_lineStart.length)
        return 0;
    if (line > g_lineStart.length)
        return g_refText.length;
    size_t o = g_lineStart[line - 1] + (col - 1);
    return o < g_refText.length ? o : g_refText.length;
}

private void offsetLineColFast(size_t off, out uint line, out uint col)
{
    ensureLineStarts();
    if (off > g_refText.length)
        off = g_refText.length;
    size_t lo = 0;
    size_t hi = g_lineStart.length;
    while (lo + 1 < hi)
    {
        size_t mid = (lo + hi) / 2;
        if (g_lineStart[mid] <= off)
            lo = mid;
        else
            hi = mid;
    }
    line = cast(uint)(lo + 1);
    col = cast(uint)(off - g_lineStart[lo] + 1);
}

// True when `g_refText` at 1-based (line, col) spells `name`.
private bool spellsAtFast(uint line, uint col, const(char)[] name)
{
    ensureRefText();
    if (!g_refText.length)
        return true; // cannot tell
    size_t off = refOffsetFast(line, col);
    if (off + name.length > g_refText.length)
        return false;
    foreach (k; 0 .. name.length)
        if (g_refText[off + k] != name[k])
            return false;
    return true;
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
    return spellsAtFast(line, col, name);
}

// True when `text` at 1-based (line, col) spells `name` exactly. Used to reject
// synthetic/generated spans and to detect edits computed against stale bytes.
bool textSpells(const(char)[] text, uint line, uint col, const(char)[] name)
{
    if (line < 1 || col < 1 || !name.length || !text.length)
        return false;
    size_t off = refOffset(text, line, col);
    if (off + name.length > text.length)
        return false;
    foreach (k; 0 .. name.length)
        if (text[off + k] != name[k])
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
// member's. For member-access nodes (`member` true) locate the member
// identifier as the first whole-word occurrence of `ident` after the receiver
// that is preceded (ignoring spaces/tabs) by a `.`. Plain identifier uses
// already carry the identifier's own location and must not be scanned (a later
// `.name` in a comment/other code would otherwise be latched onto).
private RefPos usePos(Loc recv, Dsymbol sym, bool member)
{
    RefPos r = RefPos(recv.linnum(), recv.charnum());
    if (!member || !sym || !sym.ident)
        return r;
    ensureRefText();
    if (!g_refText.length)
        return r;
    auto name = sym.ident.toString();
    if (!name.length)
        return r;
    size_t start = refOffsetFast(recv.linnum(), recv.charnum());
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
            offsetLineColFast(j, r.line, r.col);
            return r;
        }
        i = j + name.length;
    }
    return r;
}

// The name position of a declaration. Most symbols store the identifier in
// `loc`, but aggregate declarations (struct/class/union/interface/enum) store
// the *keyword* (`loc` points at `struct`); scan forward for the identifier as
// a whole word in that case.
private RefPos declPos(Loc loc, Identifier ident)
{
    RefPos r = RefPos(loc.linnum(), loc.charnum());
    if (!ident)
        return r;
    ensureRefText();
    if (!g_refText.length)
        return r;
    auto name = ident.toString();
    if (!name.length || spellsAtFast(loc.linnum(), loc.charnum(), name))
        return r;
    size_t start = refOffsetFast(loc.linnum(), loc.charnum());
    size_t i = start;
    while (i < g_refText.length)
    {
        size_t j = indexOfFrom(g_refText, name, i);
        if (j == size_t.max)
            break;
        bool okL = j == 0 || !isIdentChar(g_refText[j - 1]);
        bool okR = j + name.length >= g_refText.length ||
            !isIdentChar(g_refText[j + name.length]);
        if (okL && okR)
        {
            offsetLineColFast(j, r.line, r.col);
            return r;
        }
        i = j + name.length;
    }
    return r;
}

// First whole-word occurrence of `ident` on the declaration's line *before*
// `anchor` (the declared name). This locates an explicit type annotation
// (`S s;`, `S[] a;`) whose name dmd does not store on the resolved `Type`.
// Returns line 0 when absent (e.g. an inferred `auto` type), which the caller
// treats as "no source occurrence here".
private RefPos typeBackPos(Loc anchor, Identifier ident)
{
    RefPos none = RefPos(0, 0);
    if (!ident)
        return none;
    ensureRefText();
    if (!g_refText.length)
        return none;
    auto name = ident.toString();
    if (!name.length)
        return none;
    size_t off = refOffsetFast(anchor.linnum(), anchor.charnum());
    size_t ls = off;
    while (ls > 0 && g_refText[ls - 1] != '\n')
        ls--;
    // The *nearest* preceding occurrence is the declaration's own type
    // (`S a; S b;` must map each name to its own type).
    size_t best = size_t.max;
    size_t i = ls;
    while (i + name.length <= off)
    {
        size_t j = indexOfFrom(g_refText, name, i);
        if (j == size_t.max || j + name.length > off)
            break;
        bool okL = j == 0 || !isIdentChar(g_refText[j - 1]);
        bool okR = j + name.length >= g_refText.length ||
            !isIdentChar(g_refText[j + name.length]);
        if (okL && okR)
            best = j;
        i = j + 1;
    }
    if (best == size_t.max)
        return none;
    RefPos r;
    offsetLineColFast(best, r.line, r.col);
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
private Identifier g_keyIdent; // interned target name (O(1) reject)
private bool g_keyMode;

private bool isTarget(Dsymbol sym, Dsymbol target)
{
    if (!sym || !sym.ident)
        return false;
    if (g_keyMode)
    {
        // Interned-identifier pointer check before the allocating key compare.
        if (g_keyIdent !is null && sym.ident !is g_keyIdent)
            return false;
        return keyMatches(declKey(sym), g_key);
    }
    return sameTarget(sym, target);
}

// True when the source at `loc` spells `ident`. When the text is unavailable
// (unlikely in a walk) it returns true so callers take the normal path.
private bool useSpells(Loc loc, Identifier ident)
{
    if (!ident)
        return false;
    ensureRefText();
    if (!g_refText.length)
        return true;
    return textSpells(g_refText, loc.linnum(), loc.charnum(), ident.toString());
}

private void emitAt(uint line, uint col, Dsymbol sym, Dsymbol target,
    ref RefLoc[] out_)
{
    if (line < 1 || !sym || !sym.ident)
        return;
    if (g_collect)
    {
        g_hits ~= Hit(line, col, sym);
        return;
    }
    if (!isTarget(sym, target))
        return;
    recordPos(line, col, sym.ident, out_);
}

private void emitUse(Loc recv, Dsymbol sym, Dsymbol target, ref RefLoc[] out_,
    bool member = false)
{
    if (!sym)
        return;
    // dmd sometimes resolves a qualified access to the member directly and
    // keeps the *scope* in `loc` (e.g. `Type.staticMember` becomes a
    // `VarExp(member)` whose loc is `Type`, with no scope node). The scope is
    // the member's parent, so emit it at `loc`, then locate the member after
    // the `.`.
    if (!member && sym.ident && sym.parent && sym.parent.ident &&
        !useSpells(recv, sym.ident) && useSpells(recv, sym.parent.ident))
    {
        emitUse(recv, sym.parent, target, out_, false);
        auto mp = usePos(recv, sym, true);
        emitAt(mp.line, mp.col, sym, target, out_);
        return;
    }
    auto p = usePos(recv, sym, member);
    emitAt(p.line, p.col, sym, target, out_);
}

private void emitDecl(Loc loc, Dsymbol d, Dsymbol target, bool includeDecl,
    ref RefLoc[] out_)
{
    if (!d.ident)
        return;
    auto p = declPos(loc, d.ident);
    if (g_collect)
    {
        g_hits ~= Hit(p.line, p.col, d);
        return;
    }
    if (!includeDecl || !isTarget(d, target))
        return;
    recordPos(p.line, p.col, d.ident, out_);
}

// DMD's own semantic-time transitive visitor provides the AST traversal, so we
// inherit its complete walk instead of hand-rolling one (a hand-rolled walk
// silently missed array/assoc/struct literals and several statement kinds).
// This is the one deliberate OOP adapter in src/: dmd's visitor infrastructure
// is class-based (see `check-no-oop`).
extern (C++) final class RefWalker : SemanticTimeTransitiveVisitor
{
    alias visit = SemanticTimeTransitiveVisitor.visit;

    Dsymbol target;
    bool includeDecl;
    RefLoc[] out_;

    private void use(Loc loc, Dsymbol sym, bool member)
    {
        emitUse(loc, sym, target, out_, member);
    }

    private void decl(Dsymbol d)
    {
        if (d)
            emitDecl(d.loc, d, target, includeDecl, out_);
    }

    // A reference to `t` in a declaration's explicit type annotation. dmd drops
    // the type-name location when it resolves the type, so locate it by scanning
    // back from the declared name; inferred (`auto`/`typeof`) types have no
    // written type name and are skipped.
    private void typeUse(Loc anchor, Type t)
    {
        auto sym = typeSymbol(t);
        if (!sym || !sym.ident)
            return;
        if (g_collect)
        {
            // Also allow references/rename to be invoked on a type annotation.
            auto p = typeBackPos(anchor, sym.ident);
            if (p.line >= 1)
                g_hits ~= Hit(p.line, p.col, sym);
            return;
        }
        if (!isTarget(sym, target))
            return;
        auto p = typeBackPos(anchor, sym.ident);
        if (p.line >= 1)
            recordPos(p.line, p.col, sym.ident, out_);
    }

    // Uses: every expression node that carries a resolved symbol. `super.visit`
    // continues dmd's traversal into children.
    override void visit(VarExp e) { use(e.loc, e.var, false); super.visit(e); }
    override void visit(DotVarExp e) { use(e.loc, e.var, true); super.visit(e); }

    // dmd constant-folds an enum member access (`Test.A`) during semantic: the
    // `VarExp` is replaced by an `IntegerExp` typed as the enum, whose loc is
    // the *qualifier* (`Test`), and the EnumMember link is lost. Recover both
    // the enum type (the qualifier) and the member (the identifier after the
    // dot) from the source. Member values inside the enum declaration are not
    // uses: their loc spells the member name, not the enum, so they are skipped.
    override void visit(IntegerExp e)
    {
        if (e.type)
            if (auto te = e.type.isTypeEnum())
                emitEnumAccess(e.loc, te, target, out_);
        super.visit(e);
    }

    override void visit(EnumMember em)
    {
        decl(em);
        super.visit(em);
    }
    override void visit(SymOffExp e) { use(e.loc, e.var, false); super.visit(e); }
    override void visit(CallExp e)
    {
        if (e.f && e.e1)
            use(e.e1.loc, e.f, isMemberExpr(e.e1));
        super.visit(e);
    }
    override void visit(NewExp e) { use(e.loc, typeSymbol(e.newtype), false); super.visit(e); }
    override void visit(TypeExp e) { use(e.loc, typeSymbol(e.type), false); super.visit(e); }
    override void visit(ScopeExp e) { use(e.loc, e.sds, false); super.visit(e); }
    override void visit(FuncExp e)
    {
        use(e.loc, e.fd ? cast(Dsymbol) e.fd : cast(Dsymbol) e.td, false);
        super.visit(e);
    }
    override void visit(TemplateExp e) { use(e.loc, e.td, false); super.visit(e); }
    override void visit(DotTemplateExp e) { use(e.loc, e.td, true); super.visit(e); }
    override void visit(DotTemplateInstanceExp e)
    {
        use(e.loc, e.ti ? e.ti.tempdecl : null, true);
        super.visit(e);
    }
    override void visit(ThisExp e) { use(e.loc, e.var, false); super.visit(e); }

    // Declarations. The base visitor traverses members but does not emit them,
    // and not every declaration kind is reached; emit here.
    override void visit(StructDeclaration d) { decl(d); super.visit(d); }
    override void visit(UnionDeclaration d) { decl(d); super.visit(d); }
    override void visit(ClassDeclaration d) { decl(d); super.visit(d); }
    override void visit(InterfaceDeclaration d) { decl(d); super.visit(d); }
    override void visit(EnumDeclaration d) { decl(d); super.visit(d); }
    override void visit(TemplateDeclaration d) { decl(d); super.visit(d); }
    override void visit(AliasDeclaration d) { decl(d); super.visit(d); }

    override void visit(FuncDeclaration d)
    {
        decl(d);
        if (d.type)
            if (auto tf = d.type.isTypeFunction())
                if (tf.next)
                    typeUse(d.loc, tf.next); // return type annotation
        // `d.parameters` is a `VarDeclarations*` (the parameter symbols); the
        // base visitor only walks the function type + body, so emit the
        // parameters (their types and default arguments) explicitly.
        if (d.parameters)
            foreach (p; *d.parameters)
            {
                if (!p)
                    continue;
                decl(p);
                if (p.type)
                    typeUse(p.loc, p.type);
                if (p._init)
                    p._init.accept(this);
            }
        super.visit(d);
    }

    override void visit(VarDeclaration d)
    {
        decl(d);
        if (d.type)
            typeUse(d.loc, d.type);
        super.visit(d);
    }

    // dmd's transitive visitor does not descend into struct-literal elements or
    // slice bounds; patch those gaps (a struct literal can be self-referential,
    // so guard with the same stage flag the compiler's own walker uses).
    override void visit(StructLiteralExp e)
    {
        if (e.stageflags & StructLiteralExp.StageFlags.apply)
            return;
        auto old = e.stageflags;
        e.stageflags |= StructLiteralExp.StageFlags.apply;
        // `S(...)` is a struct literal whose `loc` is the `(`, not the type
        // name; locate the name just before it (like a type annotation).
        if (e.sd && e.sd.ident)
        {
            auto p = typeBackPos(e.loc, e.sd.ident);
            if (p.line >= 1)
                emitAt(p.line, p.col, e.sd, target, out_);
        }
        if (e.elements)
            foreach (el; *e.elements)
                if (el)
                    el.accept(this);
        e.stageflags = old;
    }

    override void visit(SliceExp e)
    {
        if (e.e1)
            e.e1.accept(this);
        if (e.lwr)
            e.lwr.accept(this);
        if (e.upr)
            e.upr.accept(this);
    }
}

// True for expressions whose resolved name is a member identifier following a
// `.` (so the AST node carries the receiver's location, not the member's).
private bool isMemberExpr(Expression e)
{
    return e && (e.isDotVarExp() || e.isDotTemplateInstanceExp() ||
        e.isDotTemplateExp());
}

// The Dsymbol a type expression denotes (struct/class/enum/instance). An enum
// type must be recognised *before* `toBasetype()` (which unwraps it to its base
// integer type, hiding the enum).
private Dsymbol typeSymbol(Type t)
{
    if (!t)
        return null;
    if (auto te = t.isTypeEnum())
        return te.sym;
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

// `Test.A` is folded to an `IntegerExp` (see visit(IntegerExp)); recover the
// enum type at the qualifier and the member after the dot. Only positions whose
// source actually spells the expected identifier are emitted (recordPos /
// occurrenceAt verify the span), so unrelated folded enum constants drop out.
private void emitEnumAccess(Loc qual, TypeEnum te, Dsymbol target,
    ref RefLoc[] out_)
{
    if (!te || !te.sym || !te.sym.ident)
        return;
    ensureRefText();
    if (g_refText.length &&
        !spellsAtFast(qual.linnum(), qual.charnum(), te.sym.ident.toString()))
        return; // not an `Enum.member` qualifier (e.g. a member's own value)
    emitAt(qual.linnum(), qual.charnum(), te.sym, target, out_);
    if (!g_refText.length)
        return;
    size_t i = refOffsetFast(qual.linnum(), qual.charnum());
    while (i < g_refText.length && g_refText[i] != '.' &&
        g_refText[i] != '\n' && g_refText[i] != ';')
        i++;
    if (i >= g_refText.length || g_refText[i] != '.')
        return;
    i++;
    while (i < g_refText.length && (g_refText[i] == ' ' || g_refText[i] == '\t'))
        i++;
    size_t s = i;
    while (i < g_refText.length && isIdentChar(g_refText[i]))
        i++;
    if (i == s || !te.sym.members)
        return;
    auto name = g_refText[s .. i];
    foreach (m; *te.sym.members)
    {
        auto em = m ? m.isEnumMember() : null;
        if (!em || !em.ident || em.ident.toString() != name)
            continue;
        uint line, col;
        offsetLineColFast(s, line, col);
        emitAt(line, col, em, target, out_);
        break;
    }
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

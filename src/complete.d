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
import dmd.dclass : ClassDeclaration;
import dmd.dtemplate : TemplateDeclaration, TemplateInstance;
import dmd.statement : Statement, WithStatement;
import dmd.tokens : Token;
import dmd.arraytypes : Dsymbols;
import dmd.attrib : ConditionalDeclaration;
import dmd.dsymbol : DSYM;
import dmd.mtype : Type, TypePointer, TypeFunction;
import dmd.astenums : TY, VarArg, STC;
import dmd.typesem : nextOf, toBasetype;
import dmd.dsymbolsem : toAlias;
import dmd.init : Initializer;
import dmd.expression : Expression, CallExp, NewExp, IdentifierExp, TypeExp,
    DotIdExp, DotTemplateInstanceExp, ScopeExp, TemplateExp, FuncExp, CastExp,
    CommaExp;
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
        labelDesc = typeTextWithStorage(vd); // caller arena-dups
        if (labelDesc.length)
            return;
    }
    if (auto al = s.isAliasDeclaration())
    {
        // Show what the alias points at (the useful part) while marking it as
        // an alias: `alias -> Foo.bar`, or `alias -> int` when only the type
        // is known (e.g. `__traits(getMember, ...)`).
        const(char)[] target;
        auto t = al.toAlias();
        if (t && t !is s)
            target = qualifiedName(t);
        if (!target.length)
            target = typeDetail(al.type);
        labelDesc = "alias -> " ~ (target.length ? target : "?");
        return;
    }
    if (auto td = s.isTemplateDeclaration())
    {
        if (auto fn = templateFunc(td))
        {
            // Function template: show `(template params)(function params)` and
            // the return type, like a plain function.
            auto tp = templateParamList(a, td);
            const(char)[] fp;
            const(char)[] rt;
            funcParts(a, fn, fp, rt);
            if (tp.length && fp.length)
                labelDetail = arenaDupStr(a, cast(string) tp ~ fp);
            else
                labelDetail = tp.length ? tp : fp;
            // Show the constraint text so the user can judge applicability.
            // It is not evaluated: filtering would require instantiating the
            // template (semantic side effects) that completion must not do.
            if (td.constraint)
            {
                import core.stdc.string : strlen;
                const(char)* cp = td.constraint.toChars();
                if (cp)
                    labelDetail = arenaDupStr(a, cast(string) labelDetail
                        ~ " if (" ~ cp[0 .. strlen(cp)] ~ ")");
            }
            labelDesc = rt;
            return;
        }
    }
    const(char)* k = s.kind();
    if (k)
    {
        import core.stdc.string : strlen;
        labelDesc = k[0 .. strlen(k)];
    }
}

// Compiler-generated unittest thunks (`__unittest_L<line>_C<col>`). No user
// writes this spelling, so it is always safe to hide.
private bool isUnittestThunk(const(char)[] nm) pure nothrow @nogc @safe
{
    return nm.length >= 11 && nm[0 .. 11] == "__unittest_";
}

// True for a symbol the language/runtime implements for you — never something
// a user calls directly. Prefer dmd's own markers over name guessing:
//   * `FuncDeclaration.isGenerated` — compiler-generated functions (`opCmp`/
//     `opEquals` thunks, `__xdtor`, `__xpostblit`, `__unittest_*`, ...);
//   * `Declaration.mangleOverride` starting with `_` — runtime entry points
//     declared with `pragma(mangle, "_aa..."/"_d_...")`;
//   * `isTypeInfoDeclaration` — generated `TypeInfo` objects.
// The reserved-name check is only a fallback for the few compiler-internal
// templates/aliases that carry none of those markers (`__ArrayCast`, ...).
private bool isInternalSymbol(Dsymbol s)
{
    if (!s)
        return false;
    if (auto fd = s.isFuncDeclaration())
        if (fd.isGenerated)
            return true;
    if (auto d = s.isDeclaration())
        if (d.mangleOverride.length && d.mangleOverride[0] == '_')
            return true;
    if (s.isTypeInfoDeclaration())
        return true;
    if (s.ident)
        return isReservedImpl(s.ident.toString());
    return false;
}

// Fallback reserved prefixes for compiler-internal names with no symbol marker.
private bool isReservedImpl(const(char)[] nm) pure nothrow @nogc @safe
{
    static immutable string[] prefixes = [
        "__", "_d_", "_aa", "_D", "_xop",
        "_aApply", "_arrayOp", "_newEntry", "_refAA", "_toAA",
    ];
    foreach (p; prefixes)
        if (nm.length >= p.length && nm[0 .. p.length] == p)
            return true;
    return false;
}

// Completion primary sort group (low sorts first), derived from the LSP kind
// so items arrive grouped by what they are. Keywords sit at the bottom; only
// anonymous `default` items are lower. The caller's own prefix is appended as a
// tiebreaker (e.g. locals before module variables within the variable group).
private const(char)[] sortGroup(ubyte kind)
{
    switch (kind)
    {
    case 9:  return "1"; // module/package
    case 6:  return "2"; // variable (locals, params, module vars)
    case 5:  return "3"; // field/member
    case 10: return "3"; // property
    case 2: case 3: case 4: return "4"; // method/function/constructor
    case 20: return "5"; // enum member
    case 1: case 7: case 8: case 13: case 22: case 25:
        return "6"; // type/alias/template/type parameter
    case 14: return "8"; // keyword
    default: return "9";
    }
}

private void pushItem(Arena* a, ref CompleteOut o, const(char)[] label, ubyte kind,
    const(char)[] detail, const(char)[] doc, const(char)[] sortPrefix,
    ref bool[const(char)[]] seen,
    Dsymbol sym = null, const(char)[] desc = null, const(char)[] marker = null,
    const(char)[] labelDetailOverride = null)
{
    if (label.length == 0 || label in seen)
        return;
    if (isUnittestThunk(label))
        return;
    seen[label] = true;
    char* lp = cast(char*)a.alloc(label.length + 1);
    if (!lp)
        return;
    lp[0 .. label.length] = label[];
    lp[label.length] = 0;
    const(char)[] ls = lp[0 .. label.length];
    const(char)[] ds = detail;
    const(char)[] dc = arenaDupStr(a, doc);
    const(char)[] ld = null;
    const(char)[] lx = null;
    if (sym)
        itemParts(a, sym, ld, lx);
    else if (desc.length)
        lx = desc;
    if (labelDetailOverride.length)
        ld = labelDetailOverride;
    if (marker.length)
    {
        // Surface where the item comes from (UFCS, alias this) in the
        // labelDetails line the editor shows inline, and in `detail` for
        // clients that do not support labelDetails.
        ds = withMarker(ds, marker);
        lx = withMarker(lx, marker);
    }
    ds = arenaDupStr(a, ds);
    ld = arenaDupStr(a, ld);
    lx = arenaDupStr(a, lx);
    string sort = sortGroup(kind).idup ~ sortPrefix.idup ~ label.idup;
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

// Prefix a label's detail with its origin marker, e.g. `(alias this) int`. The
// marker comes first so the type text is not pushed around by it.
private const(char)[] withMarker(const(char)[] s, const(char)[] marker)
{
    if (!marker.length)
        return s;
    if (!s.length)
        return marker;
    return cast(const(char)[]) ("(" ~ marker ~ ") " ~ cast(string) s);
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

private ubyte kindOf(Dsymbol s) => kindOfDepth(s, 0);

private ubyte kindOfDepth(Dsymbol s, int depth)
{
    if (!s || depth > 8)
        return 1;
    if (auto al = s.isAliasDeclaration())
    {
        auto t = al.toAlias();
        if (t && t !is s)
            return kindOfDepth(t, depth + 1);
        return 1;
    }
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
    if (auto td = s.isTemplateDeclaration())
    {
        if (auto fn = templateFunc(td))
            return kindOfDepth(fn, depth + 1);
        return 1;
    }
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

// Storage classes that read as part of a declaration but are not part of its
// `Type` (`ref`, `out`, `lazy`, `scope`, `return`, `in`). A parameter must show
// its spelling: `ref int arg` is not `int arg`.
private string storagePrefixStr(ulong stc)
{
    string p;
    if (stc & STC.return_)
        p ~= "return ";
    if ((stc & STC.scope_) && !(stc & STC.in_))
        p ~= "scope ";
    if (stc & STC.in_)
        p ~= "in ";
    if (stc & STC.lazy_)
        p ~= "lazy ";
    if (stc & STC.out_)
        p ~= "out ";
    else if (stc & STC.ref_)
        p ~= "ref ";
    return p;
}

// A variable/parameter's source spelling for completion detail: storage
// prefix + type, e.g. `ref int`.
private const(char)[] typeTextWithStorage(VarDeclaration vd)
{
    if (!vd)
        return null;
    auto t = typeDetail(vd.type);
    auto p = storagePrefixStr(vd.storage_class);
    return p.length ? (p ~ t) : t;
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
    const(char)[] sortPrefix, ref CompleteOut o, ref bool[const(char)[]] seen,
    bool skipReserved = false)
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
        if (skipReserved && isInternalSymbol(s))
            continue;
        if (!hasPrefix(nm, prefix))
            continue;
        pushItem(a, o, nm, kindOf(s), typeDetail(symType(s)), docOf(s), sortPrefix, seen, s);
        if (o.nitems >= 500)
            return;
    }
}

private Type symType(Dsymbol s) => symTypeDepth(s, 0);

private Type symTypeDepth(Dsymbol s, int depth)
{
    if (!s || depth > 8)
        return null;
    if (auto vd = s.isVarDeclaration())
        return vd.type;
    if (auto fd = s.isFuncDeclaration())
        return fd.type;
    if (auto al = s.isAliasDeclaration())
    {
        auto t = al.toAlias();
        if (t && t !is s)
            return symTypeDepth(t, depth + 1);
        return al.type;
    }
    return null;
}

// Qualified name within the module (e.g. `Foo.bar`), or null.
private const(char)[] qualifiedName(Dsymbol s)
{
    if (!s)
        return null;
    string[] parts;
    for (auto p = s; p; p = p.parent)
    {
        if (p.isModule())
            break;
        if (p.ident)
            parts ~= p.ident.toString().idup;
    }
    if (!parts.length)
        return s.ident ? s.ident.toString() : null;
    string r;
    foreach_reverse (part; parts)
    {
        if (r.length)
            r ~= ".";
        r ~= part;
    }
    return r;
}

// Function label parts for LSP 3.17 `labelDetails`: the parameter list
// (e.g. "(int, string)") and the return type. Empty for non-functions.
private const(char)[] funcParamList(Arena* a, TypeFunction tf, bool withNames,
    bool skipFirst = false)
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
            // UFCS: the receiver fills the first parameter, so it is not shown.
            if (skipFirst && i == 0)
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

// A function template's underlying FuncDeclaration, if it is one (e.g.
// `void f(T)(T x)`), so completion can present it as a function rather than
// an opaque "template".
private FuncDeclaration templateFunc(TemplateDeclaration td)
{
    import dmd.templatesem : computeOneMember;
    if (!td)
        return null;
    if (!td.haveComputedOneMember)
        computeOneMember(td);
    if (td.onemember)
        if (auto fd = td.onemember.isFuncDeclaration())
            return fd;
    return td.funcroot;
}

// `(T, U...)` from a template declaration's parameters.
private const(char)[] templateParamList(Arena* a, TemplateDeclaration td)
{
    if (!td.parameters || (*td.parameters).length == 0)
        return null;
    import core.stdc.string : strlen;
    string buf = "(";
    foreach (i; 0 .. (*td.parameters).length)
    {
        if (i)
            buf ~= ", ";
        auto p = (*td.parameters)[i];
        const(char)* s = p ? p.toChars() : null;
        buf ~= s ? s[0 .. strlen(s)] : "?";
        if (p && p.isTemplateTupleParameter())
            buf ~= "...";
    }
    buf ~= ")";
    return arenaDupStr(a, buf);
}

Dsymbol[] scopeMembers(Dsymbol scope_)
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
        // NOTE: never D-cast dmd AST nodes (extern(C++) classes have no
        // runtime type check; a bogus cast reads wrong field offsets).
        // Tag-check first, then the cast is safe.
        if (at.dsym == DSYM.conditionalDeclaration ||
            at.dsym == DSYM.staticIfDeclaration)
        {
            auto cd = cast(ConditionalDeclaration)at;
            // Only the branch dmd actually selected is live. Including both
            // (or always the `then` branch) lets a versioned-out declaration
            // shadow the real one: e.g. on Linux `core.stdc.stdio`'s
            // `version (MinGW)` `printf` and its
            // `static if (PPCUseIEEE128)` alias both precede the glibc
            // declaration, so resolution/completion answered with the wrong
            // symbol. `inc` is computed by semantic; on a parse-only module it
            // is still `notComputed`, so include both branches there.
            import dmd.cond : Include;
            Dsymbols* branch = null;
            if (cd.condition && cd.condition.inc != Include.notComputed)
                branch = cd.condition.inc == Include.yes ? cd.decl : cd.elsedecl;
            if (branch)
            {
                foreach (i; 0 .. (*branch).length)
                    out_ ~= (*branch)[i];
            }
            else if (cd.condition)
            {
                if (cd.decl)
                    foreach (i; 0 .. (*cd.decl).length)
                        out_ ~= (*cd.decl)[i];
                if (cd.elsedecl)
                    foreach (i; 0 .. (*cd.elsedecl).length)
                        out_ ~= (*cd.elsedecl)[i];
            }
            return;
        }
        if (at.decl)
            foreach (i; 0 .. (*at.decl).length)
                out_ ~= (*at.decl)[i];
    }
}

// Flat member list with attribute blocks expanded recursively (for name
// lookup and completion; aggregates stay intact for scopeMembers/stepInto).
private void flattenMembers(Dsymbols* mem, ref Dsymbol[] out_)
{
    if (!mem)
        return;
    if (g_flatMemoOn)
    {
        if (auto p = mem in g_flatMemo)
            if (p.len == (*mem).length)
            {
                if (out_.length)
                    out_ ~= p.flat;
                else
                    out_ = p.flat;
                return;
            }
        Dsymbol[] flat;
        flattenArray((*mem)[], flat);
        // A sentinel past the end: the memo slice never ends at its block's
        // used length, so a caller appending to what it got reallocates
        // instead of writing into the shared list.
        flat ~= null;
        flat = flat[0 .. $ - 1];
        g_flatMemo[mem] = FlatMemo((*mem).length, flat);
        if (out_.length)
            out_ ~= flat;
        else
            out_ = flat;
        return;
    }
    flattenArray((*mem)[], out_);
}

// One op resolves thousands of names against the same few scopes (semantic
// tokens, highlights, lint): flatten each member array once per op instead
// of per lookup, which made those walks O(names x scope size) in time and
// garbage. Keyed by the array and its length (lazy semantic appends
// members). Only valid inside one op: a popped overlay frees the arrays.
private struct FlatMemo
{
    size_t len;
    Dsymbol[] flat;
}

private __gshared FlatMemo[Dsymbols*] g_flatMemo;
private __gshared bool g_flatMemoOn;

void flattenMemoBegin()
{
    g_flatMemo = null;
    g_flatMemoOn = true;
}

void flattenMemoEnd()
{
    g_flatMemo = null;
    g_flatMemoOn = false;
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

// The aggregate (struct/class/union) owning the cursor's scope, so its members
// can act as implicit `this` in completion (`renderer.` where `renderer` is a
// field). Inside a member function the semantic `parent` chain is exact; a
// cursor in the aggregate body itself (no enclosing function) falls back to the
// lexer brace ranges, innermost (deepest declaration) winning.
private AggregateDeclaration enclosingAggregate(Module mod, const ref SynMod syn,
    uint line, FuncDeclaration fd)
{
    for (Dsymbol p = fd ? fd.parent : null; p; p = p.parent)
        if (auto ad = p.isAggregateDeclaration())
            return ad;
    if (!mod || !mod.members)
        return null;
    AggregateDeclaration best = null;
    uint bestStart = 0;
    void visit(Dsymbol s)
    {
        if (!s)
            return;
        if (auto ad = s.isAggregateDeclaration())
        {
            uint sl = ad.loc.linnum();
            if (sl >= 1 && sl <= line && aggregateBraceContains(syn, sl, line))
                if (!best || sl >= bestStart)
                {
                    best = ad;
                    bestStart = sl;
                }
        }
        Dsymbol[] subs = null;
        appendScopeSubs(s, subs);
        foreach (c; subs)
            visit(c);
    }
    foreach (i; 0 .. (*mod.members).length)
        visit((*mod.members)[i]);
    return best;
}

// True when a lexer brace opened after the aggregate's declaration still
// contains `line`: the aggregate body (method bodies nest inside it, so the
// earliest such brace is the body and its presence is what we test).
private bool aggregateBraceContains(const ref SynMod syn, uint declLine, uint line)
{
    // The aggregate's own body is the first brace opened at/after its
    // declaration. Checking *any* later brace would also match a following
    // function's body and wrongly treat the cursor as being inside the
    // aggregate (surfacing its members as implicit `this`).
    uint bestOpen = uint.max;
    uint bestClose = 0;
    foreach (ref br; syn.braces)
    {
        if (br.openLine < declLine)
            continue;
        if (br.openLine < bestOpen)
        {
            bestOpen = br.openLine;
            bestClose = br.closeLine;
        }
    }
    return bestOpen != uint.max && line >= bestOpen && line <= bestClose;
}

// Own + inherited (class base chain) members, for implicit-`this` completion.
private Dsymbol[] aggregateMembers(AggregateDeclaration ad)
{
    Dsymbol[] r;
    if (!ad)
        return r;
    r ~= scopeMembers(ad);
    if (auto cd = ad.isClassDeclaration())
    {
        for (auto b = cd.baseClass; b; b = b.baseClass)
            r ~= scopeMembers(b);
        foreach (bc; cd.interfaces)
            if (bc.sym)
                r ~= scopeMembers(bc.sym);
    }
    return r;
}

// Emit an aggregate's members as completion items (implicit `this`): a member
// function's fields/methods are in scope when typing a bare prefix, though they
// are not locals. `seen` dedups against already-listed locals/params.
private void addAggregateMemberItems(Arena* a, ref CompleteOut o,
    ref bool[const(char)[]] seen, const(char)[] prefix, AggregateDeclaration ad)
{
    foreach (m; aggregateMembers(ad))
    {
        if (!m.ident)
            continue;
        auto nm = m.ident.toString();
        if (nm == "this" || nm == "super" || nm == "_")
            continue;
        if (!hasPrefix(nm, prefix))
            continue;
        pushItem(a, o, nm, kindOf(m), typeDetail(symType(m)), docOf(m), "0", seen, m);
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

private FuncDeclaration findEnclosingFunc(Module mod, const ref SynMod syn, uint line)
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
    // An AST range can be recovery-extended over following functions, so accept
    // it only when the cursor is inside the function's lexical body; otherwise
    // the snapshot's brace-scoped fallback owns the locals.
    if (!funcScopedToLine(syn, best, line))
        best = null;
    return best;
}

// True when `fd`'s lexical body (from the snapshot) contains `line`, so its
// statement-level AST endLocs are safe to trust. A null fd, or a function with
// no snapshot entry, passes: there is no lexical bound to contradict. This is
// the single predicate all callers of the statement-level walkers must satisfy.
// The walkers enforce it unconditionally (guarding, not merely asserting) so an
// ungated call site fails safe even under -release, where asserts are stripped.
private bool funcScopedToLine(const ref SynMod syn, FuncDeclaration fd, uint line)
{
    if (!fd)
        return true;
    auto fsn = synFuncAt(syn, fd.loc.linnum());
    return !fsn || line <= fsn.endLine;
}

// ---------- pre-semantic snapshot ----------
// Post-semantic bodies are lossy (failed statements propagate
// ErrorStatement up to fbody), so structure (function ranges, local
// names) is snapshotted from the fresh parse BEFORE semantic runs.
// The snapshot is consumed in the same worker process as the parsed Module
// it came from, so it also keeps the local's VarDeclaration: semantic runs
// on those same nodes (and keeps going after a statement error), so its
// resolved `.type` is readable even once the body has been collapsed.
struct SynLocal
{
    string name;
    uint line = 0;
    string typeName; // unresolved (pre-semantic) type ident, if simple
    string typeText; // pre-semantic type spelling, display fallback
    VarDeclaration vd; // the parsed declaration; `.type` is dmd-resolved
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
private SynLocal synVar(const(char)[] name, uint line, Type t,
    VarDeclaration vd = null)
{
    return SynLocal(name.idup, line, identTypeName(t), typeTextOf(t), vd);
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

// A function-scoped `import` captured pre-semantic. `mod` is null at snapshot
// time and filled in by `dmdSemantic` on the same Import object, so completion
// (which runs post-semantic) can read it even if an error rewrote the body.
struct SynImport
{
    Import imp;
    uint line; // declaration line: visible only from here on
}

struct SynFunc
{
    FuncDeclaration fd; // the parsed function; fbody is re-checked post-semantic
    string name; // null for literals
    uint startLine = 0;
    uint endLine = 0; // 0 = unknown/open
    uint depth = 0;
    SynLocal[] vars;   // body vars (names + decl lines + type idents)
    SynImport[] imports; // function-scoped imports
    string[] params;   // param names from the type (no locs)
    string[] paramTypes; // parallel unresolved type idents (may be null)
    string[] paramTypeTexts; // parallel full type spelling for display
}

struct SynMod
{
    SynFunc[] funcs;
    // Lexer brace ranges, for scoping captured vars when no function range
    // matches (recovery merged a function away; see collectSlots).
    BraceRange[] braces;
}

private void synWalkBody(Statement s, uint funcEnd, ref SynFunc fn)
{
    if (!s)
        return;
    if (auto is_ = s.isImportStatement())
    {
        if (is_.imports)
            foreach (i; 0 .. (*is_.imports).length)
            {
                auto imp = (*is_.imports)[i] ? (*is_.imports)[i].isImport() : null;
                if (imp)
                    fn.imports ~= SynImport(imp, imp.loc.linnum());
            }
        return;
    }
    // `version(...)`/`debug`/`static if` block in a body: walk both branches
    // (conditions aren't evaluated; offering names from either is the usual
    // editor behaviour). Covers imports/locals declared inside them.
    if (auto c = s.isConditionalStatement())
    {
        synWalkBody(c.ifbody, funcEnd, fn);
        synWalkBody(c.elsebody, funcEnd, fn);
        return;
    }
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
                            vd.loc.linnum(), tn, typeTextOf(vd.type), vd);
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
            fn.vars ~= synVar(fes.key.ident.toString(), fes.key.loc.linnum(), fes.key.type, fes.key);
        if (fes.value && fes.value.ident)
            fn.vars ~= synVar(fes.value.ident.toString(), fes.value.loc.linnum(), fes.value.type, fes.value);
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
                    fn.vars ~= synVar(c.ident.toString(), c.loc.linnum, c.type, c.var);
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

// Lexer-derived brace ranges for the current snapshot (g_braces, reset with
// g_synFuncs). Parser error recovery can extend a function's AST past its real
// body (an unterminated `.` swallows following functions), so scoping from
// `endloc` leaks locals forward across functions. Matching the body's `{` with
// dmd's lexer bounds each snapshot scope to its actual body. A text scan would
// miscount braces inside strings/comments; the lexer cannot.
struct BraceRange
{
    uint openLine;
    uint openCol;
    uint closeLine;
}

private BraceRange[] g_braces;

private void braceRanges(const(char)[] text)
{
    import dmd.lexer : Lexer;
    import dmd.tokens : Token, TOK;
    import dmd.globals : global;

    g_braces = null;
    auto buf = text.dup ~ '\0';
    scope lex = new Lexer(null, cast(char*) buf.ptr, 0, buf.length - 1,
        false, false, global.errorSinkNull, &global.compileEnv);
    uint[] openLines;
    uint[] openCols;
    while (true)
    {
        Token tok;
        lex.scan(&tok);
        if (tok.value == TOK.endOfFile)
            break;
        if (tok.value == TOK.leftCurly)
        {
            openLines ~= tok.loc.linnum();
            openCols ~= cast(uint) tok.loc.charnum();
        }
        else if (tok.value == TOK.rightCurly && openLines.length)
        {
            g_braces ~= BraceRange(openLines[$ - 1], openCols[$ - 1],
                tok.loc.linnum());
            openLines.length--;
            openCols.length--;
        }
    }
}

// Line of the `}` matching this function's body `{`. For a body-less function
// there is no body scope, and for a body `{` with no lexical match (unterminated
// or recovery-mangled) the AST end cannot be trusted — it may have swallowed
// following functions. Both cases collapse the range to the signature line:
// body locals are then not offered. Missing names are safe; wrong-scope names
// are not, so we never fall back to the extended AST end.
private uint lexicalBodyEnd(FuncDeclaration fd)
{
    if (!fd.fbody)
        return fd.loc.linnum();
    uint l = fd.fbody.loc.linnum();
    uint c = cast(uint) fd.fbody.loc.charnum();
    foreach (ref br; g_braces)
        if (br.openLine == l && br.openCol == c)
            return br.closeLine;
    return fd.loc.linnum();
}

private void synFunc(FuncDeclaration fd, uint depth)
{
    if (!fd)
        return;
    SynFunc fn;
    fn.fd = fd;
    fn.name = fd.ident ? fd.ident.toString().idup : null;
    fn.startLine = fd.loc.linnum();
    fn.endLine = lexicalBodyEnd(fd);
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
                        auto pdisp = typeTextOf(p.type);
                        auto sp = storagePrefixStr(p.storageClass);
                        fn.paramTypeTexts ~= sp.length ? (sp ~ pdisp).idup : pdisp;
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
SynMod snapshotModule(Module mod, const(char)[] text)
{
    SynMod m;
    if (!mod || !mod.members)
        return m;
    g_synFuncs = null;
    braceRanges(text);
    Dsymbol[] members;
    foreach (i; 0 .. (*mod.members).length)
        members ~= (*mod.members)[i];
    synMembers(members, 0);
    m.funcs = g_synFuncs;
    m.braces = g_braces;
    g_synFuncs = null;
    g_braces = null;
    return m;
}

// Whether some lexer brace range contains both lines. Used to scope captured
// locals when parser recovery merged a function into an earlier one and no
// SynFunc range covers the cursor: a local and the cursor are in the same
// function iff a brace encloses them both. Nested blocks still share their
// function's brace, while two sibling functions share none.
private bool sameBraceRegion(const ref SynMod syn, uint declLine, uint cursorLine)
{
    // Innermost matched pair containing the declaration line, then require the
    // cursor to be inside that same pair. Being inside the declaration's block
    // (or a nested one) is exactly the declaration's scope. Two sibling
    // functions/blocks are excluded even when an enclosing aggregate or
    // version block contains them both, and module-scope cursors (no enclosing
    // pair) are gated out.
    int best = -1;
    foreach (i, ref br; syn.braces)
    {
        if (br.openLine > declLine || declLine > br.closeLine)
            continue;
        if (best >= 0 &&
            (br.closeLine - br.openLine) >=
            (syn.braces[best].closeLine - syn.braces[best].openLine))
            continue;
        best = cast(int) i;
    }
    if (best < 0)
        return false;
    auto br = syn.braces[best];
    return br.openLine <= cursorLine && cursorLine <= br.closeLine;
}

// Snapshot locals usable at `line`: the matching function's captured vars, or
// when no function range matches (recovery merged the function into an earlier
// one) every captured var sharing a lexer brace region with the cursor.
private const(SynLocal)[] snapshotLocals(const ref SynMod syn, uint line,
    const(SynFunc)* sfn)
{
    if (sfn)
        return sfn.vars;
    const(SynLocal)[] pool;
    foreach (ref fn; syn.funcs)
        foreach (ref vl; fn.vars)
            if (vl.line <= line && sameBraceRegion(syn, vl.line, line))
                pool ~= vl;
    return pool;
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

// Update an already-listed item's type in place. Used when a later local
// declaration shadows an earlier same-named one: the nearer type must win.
private void replaceLocalType(Arena* a, ref CompleteOut o, const(char)[] nm,
    const(char)[] typeText)
{
    for (size_t i = 0; i < o.nitems; i++)
        if (o.items[i].label == nm)
        {
            o.items[i].detail = arenaDupStr(a, typeText);
            o.items[i].labelDesc = arenaDupStr(a, typeText);
            o.items[i].labelDetail = null;
            return;
        }
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
    if (nm in seen)
    {
        replaceLocalType(a, o, nm, typeTextWithStorage(vd));
        return;
    }
    pushItem(a, o, nm, 6, typeTextWithStorage(vd), docOf(vd), "0", seen, vd);
}

// `foreach` over a user type (opApply) is lowered to a call passing a delegate
// (`cast(void) (aggr.opApply(delegate { ... }))`), so the loop variable is a
// parameter of that delegate, not a `ForeachStatement` parameter. Walk the
// statement expression looking for such a delegate whose body contains the
// cursor.
private void walkDelegateExpr(Expression e, FuncDeclaration cur,
    const ref SynMod syn, uint cursorLine, const(char)[] prefix, Arena* a,
    ref CompleteOut o, ref bool[const(char)[]] seen, int depth)
{
    if (!e || depth > 8)
        return;
    if (auto fe = e.isFuncExp())
    {
        auto dfd = fe.fd;
        if (dfd && dfd.fbody)
        {
            uint el = dfd.endloc.linnum();
            if (dfd.loc.linnum() <= cursorLine && (el == 0 || cursorLine <= el))
            {
                if (dfd.parameters)
                    foreach (i; 0 .. dfd.parameters.length)
                    {
                        VarDeclaration v = (*dfd.parameters)[i];
                        addLocal(a, o, seen, v, cursorLine, prefix);
                    }
                walkStmt(dfd.fbody, dfd, syn, cursorLine, prefix, a, o, seen);
            }
        }
        return;
    }
    if (auto ce = e.isCallExp())
    {
        if (ce.e1)
            walkDelegateExpr(ce.e1, cur, syn, cursorLine, prefix, a, o, seen, depth + 1);
        if (ce.arguments)
            foreach (arg; *ce.arguments)
                walkDelegateExpr(arg, cur, syn, cursorLine, prefix, a, o, seen, depth + 1);
        return;
    }
    if (auto ce = e.isCastExp())
    {
        walkDelegateExpr(ce.e1, cur, syn, cursorLine, prefix, a, o, seen, depth + 1);
        return;
    }
    if (auto me = e.isCommaExp())
    {
        walkDelegateExpr(me.e1, cur, syn, cursorLine, prefix, a, o, seen, depth + 1);
        walkDelegateExpr(me.e2, cur, syn, cursorLine, prefix, a, o, seen, depth + 1);
        return;
    }
}

// Members made available by `with (obj) { ... }`: unqualified names resolve
// against the object. The frontend resolves the object into `w.wthis` (a
// synthetic VarDeclaration whose type is the object's type); for pre-semantic
// buffers `w.exp.type` is the best available.
private void addWithMembers(Arena* a, ref CompleteOut o,
    ref bool[const(char)[]] seen, const(char)[] prefix, WithStatement w)
{
    Type t = w.wthis ? w.wthis.type : (w.exp ? w.exp.type : null);
    if (!t)
        return;
    if (isBuiltinArrayType(t))
    {
        pushArrayProperties(a, o, seen, prefix, t);
        return;
    }
    auto members = followTypeDepth(t, null, null, 0);
    if (!members.length)
        return;
    foreach (m; members)
    {
        if (!m.ident)
            continue;
        if (m.visible().kind == Visibility.Kind.private_)
            continue;
        auto nm = m.ident.toString();
        if (nm in seen || !hasPrefix(nm, prefix))
            continue;
        pushItem(a, o, nm, kindOf(m), typeDetail(symType(m)), docOf(m), "0", seen, m);
        if (o.nitems >= 500)
            return;
    }
}

private void walkStmt(Statement s, FuncDeclaration cur, const ref SynMod syn, uint cursorLine,
    const(char)[] prefix, Arena* a, ref CompleteOut o, ref bool[const(char)[]] seen)
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
                        if (fd.loc.linnum() <= cursorLine && (el == 0 || cursorLine <= el) &&
                            funcScopedToLine(syn, fd, cursorLine))
                            collectInFunc(fd, syn, cursorLine, prefix, a, o, seen);
                    }
                }
                else if (auto ls = localTypeDecl(de.declaration, cursorLine))
                {
                    const(char)[] nm = ls.ident.toString();
                    if (hasPrefix(nm, prefix))
                        pushItem(a, o, nm, kindOf(ls), typeDetail(symType(ls)),
                            docOf(ls), "0", seen, ls);
                }
            }
            else
                walkDelegateExpr(es.exp, cur, syn, cursorLine, prefix, a, o, seen, 0);
        }
        return;
    }
    if (auto cs = s.isCompoundStatement())
    {
        for (size_t i = 0; i < cs.statements.length; i++)
            walkStmt(cs.statements[i], cur, syn, cursorLine, prefix, a, o, seen);
        return;
    }
    if (auto ss = s.isScopeStatement())
    {
        walkStmt(ss.statement, cur, syn, cursorLine, prefix, a, o, seen);
        return;
    }
    // Descend only into the branch/body that contains the cursor, so a
    // sibling block's same-named variable isn't listed as in scope.
    if (auto is_ = s.isIfStatement())
    {
        uint end = is_.endloc.linnum();
        if (end != 0 && cursorLine > end)
            return;
        if (is_.param && is_.param.ident && is_.ifbody &&
            cursorLine >= is_.ifbody.loc.linnum())
        {
            const(char)[] inm = is_.param.ident.toString();
            if (hasPrefix(inm, prefix))
                pushItem(a, o, inm, 6, typeDetail(is_.param.type), null, "0", seen, null, typeDetail(is_.param.type));
        }
        if (is_.match)
            addLocal(a, o, seen, is_.match, cursorLine, prefix);
        uint elseStart = is_.elsebody ? is_.elsebody.loc.linnum() : 0;
        if (elseStart != 0 && cursorLine >= elseStart)
            walkStmt(is_.elsebody, cur, syn, cursorLine, prefix, a, o, seen);
        else
            walkStmt(is_.ifbody, cur, syn, cursorLine, prefix, a, o, seen);
        return;
    }
    if (auto ws = s.isWhileStatement())
    {
        uint end = ws.endloc.linnum();
        if (end != 0 && cursorLine > end)
            return;
        if (ws.param && ws.param.ident)
        {
            const(char)[] wnm = ws.param.ident.toString();
            if (hasPrefix(wnm, prefix))
                pushItem(a, o, wnm, 6, typeDetail(ws.param.type), null, "0", seen, null, typeDetail(ws.param.type));
        }
        walkStmt(ws._body, cur, syn, cursorLine, prefix, a, o, seen);
        return;
    }
    if (auto ds = s.isDoStatement())
    {
        uint end = ds.endloc.linnum();
        if (end == 0 || cursorLine <= end)
            walkStmt(ds._body, cur, syn, cursorLine, prefix, a, o, seen);
        return;
    }
    if (auto fs = s.isForStatement())
    {
        uint end = fs.endloc.linnum();
        if (end != 0 && cursorLine > end)
            return;
        walkStmt(fs._init, cur, syn, cursorLine, prefix, a, o, seen);
        walkStmt(fs._body, cur, syn, cursorLine, prefix, a, o, seen);
        return;
    }
    if (auto fes = s.isForeachStatement())
    {
        uint end = fes.endloc.linnum();
        if (end != 0 && cursorLine > end)
            return;
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
        walkStmt(fes._body, cur, syn, cursorLine, prefix, a, o, seen);
        return;
    }
    if (auto sw = s.isSwitchStatement())
    {
        uint end = sw.endloc.linnum();
        if (end != 0 && cursorLine > end)
            return;
        if (sw.param && sw.param.ident)
        {
            const(char)[] snm = sw.param.ident.toString();
            if (hasPrefix(snm, prefix))
                pushItem(a, o, snm, 6, typeDetail(sw.param.type), null, "0", seen, null, typeDetail(sw.param.type));
        }
        walkStmt(sw._body, cur, syn, cursorLine, prefix, a, o, seen);
        return;
    }
    if (auto c1 = s.isCaseStatement())
    {
        walkStmt(c1.statement, cur, syn, cursorLine, prefix, a, o, seen);
        return;
    }
    if (auto d1 = s.isDefaultStatement())
    {
        walkStmt(d1.statement, cur, syn, cursorLine, prefix, a, o, seen);
        return;
    }
    if (auto lb = s.isLabelStatement())
    {
        walkStmt(lb.statement, cur, syn, cursorLine, prefix, a, o, seen);
        return;
    }
    if (auto tc = s.isTryCatchStatement())
    {
        uint bodyEnd = tc.catches && (*tc.catches).length
            ? (*tc.catches)[0].handler.loc.linnum() : 0;
        if (bodyEnd == 0 || cursorLine < bodyEnd)
            walkStmt(tc._body, cur, syn, cursorLine, prefix, a, o, seen);
        if (tc.catches)
            foreach (i; 0 .. (*tc.catches).length)
            {
                auto c = (*tc.catches)[i];
                uint hs = c.handler ? c.handler.loc.linnum() : 0;
                uint he = i + 1 < (*tc.catches).length
                    ? (*tc.catches)[i + 1].handler.loc.linnum() : 0;
                if (hs == 0 || cursorLine < hs || (he != 0 && cursorLine >= he))
                    continue;
                if (c.var)
                    addLocal(a, o, seen, c.var, cursorLine, prefix);
                walkStmt(c.handler, cur, syn, cursorLine, prefix, a, o, seen);
            }
        return;
    }
    if (auto tf = s.isTryFinallyStatement())
    {
        walkStmt(tf._body, cur, syn, cursorLine, prefix, a, o, seen);
        walkStmt(tf.finalbody, cur, syn, cursorLine, prefix, a, o, seen);
        return;
    }
    if (auto w = s.isWithStatement())
    {
        uint end = w.endloc.linnum();
        if (end != 0 && cursorLine > end)
            return;
        // Body locals shadow the with object's members, so walk the body first
        // and add the object's members afterwards (first add wins via `seen`).
        walkStmt(w._body, cur, syn, cursorLine, prefix, a, o, seen);
        if (w.prm && w.prm.ident)
        {
            const(char)[] wnm = w.prm.ident.toString();
            if (hasPrefix(wnm, prefix))
                pushItem(a, o, wnm, 6, typeDetail(w.prm.type), null, "0", seen, null, typeDetail(w.prm.type));
        }
        addWithMembers(a, o, seen, prefix, w);
        return;
    }
    if (auto sy = s.isSynchronizedStatement())
    {
        walkStmt(sy._body, cur, syn, cursorLine, prefix, a, o, seen);
        return;
    }
    // Other statements: no locals.
}

private void collectInFunc(FuncDeclaration fd, const ref SynMod syn, uint cursorLine,
    const(char)[] prefix, Arena* a, ref CompleteOut o, ref bool[const(char)[]] seen)
{
    if (!fd)
        return;
    // Invariant: callers only pass a function whose lexical body contains the
    // cursor (findEnclosingFunc gates it; nested descent below gates too).
    // Enforced unconditionally, not just by assert: asserts are stripped under
    // -release, and an ungated future call site must degrade to no locals
    // rather than leak a preceding function's locals once that flag appears.
    if (!funcScopedToLine(syn, fd, cursorLine))
    {
        assert(false); // dev: fail loudly
        return;        // release: fail safe
    }
    if (fd.parameters)
        foreach (i; 0 .. fd.parameters.length)
        {
            VarDeclaration v = (*fd.parameters)[i];
            addLocal(a, o, seen, v, cursorLine, prefix);
        }
    if (fd.fbody)
        walkStmt(fd.fbody, fd, syn, cursorLine, prefix, a, o, seen);
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
            return aggregateMembers(ts.sym, depth, root, rootMembers);
    }
    else if (auto tc = tb.isTypeClass())
    {
        if (tc.sym)
            return aggregateMembers(tc.sym, depth, root, rootMembers);
    }
    else if (auto te = tb.isTypeEnum())
    {
        if (te.sym)
            return scopeMembers(te.sym);
    }
    return null;
}

// An aggregate's own members, its inherited members (class base chain and
// interfaces; `cd.baseclasses` lists the base class first, then interfaces),
// and those promoted by `alias this` (`w.field` for a field of `w`'s
// subobject). Own members come first, so a derived override shadows the base.
// `depth` keeps a cyclic inheritance/`alias this` finite.
private Dsymbol[] aggregateMembers(AggregateDeclaration ad, int depth,
    Module root, Dsymbol[] rootMembers)
{
    auto mem = scopeMembers(ad);
    if (depth > 8)
        return mem;
    if (auto cd = ad.isClassDeclaration())
        if (cd.baseclasses)
            foreach (ref bc; *cd.baseclasses)
                if (bc.sym && bc.sym !is ad)
                    mem ~= aggregateMembers(bc.sym, depth + 1, root, rootMembers);
    if (ad.aliasthis && ad.aliasthis.sym)
    {
        auto more = stepInto(ad.aliasthis.sym, depth + 1, root, rootMembers);
        if (more.length)
            mem ~= more;
    }
    return mem;
}

// A built-in array / associative-array type (not a user aggregate). D exposes
// the element's members only through an index (`arr[i].field`), never `arr.`.
private bool isBuiltinArrayType(Type t)
{
    if (!t)
        return false;
    Type tb = t.toBasetype();
    if (!tb)
        return false;
    return tb.ty == TY.Tsarray || tb.ty == TY.Tarray || tb.ty == TY.Taarray;
}

// Built-in array properties/methods for `arr.`. Labels only: the heuristic
// engine has no `Dsymbol` for them, which is fine for completion.
private void pushArrayProperties(Arena* a, ref CompleteOut o,
    ref bool[const(char)[]] seen, const(char)[] prefix, Type t)
{
    Type tb = t ? t.toBasetype() : null;
    if (!tb)
        return;
    const(char)[][] names;
    switch (tb.ty)
    {
    case TY.Tarray:
        names = ["length", "ptr", "dup", "idup", "capacity", "reserve",
            "reverse", "sort"];
        break;
    case TY.Tsarray:
        names = ["length", "ptr", "dup", "idup", "reverse", "sort"];
        break;
    case TY.Taarray:
        names = ["length", "keys", "values", "byKey", "byValue", "byKeyValue",
            "rehash", "dup", "get", "require", "update"];
        break;
    default:
        return;
    }
    foreach (nm; names)
    {
        if (!hasPrefix(nm, prefix))
            continue;
        pushItem(a, o, nm, 10, "property", null, "1", seen);
    }
}

// Built-in D properties offered after a dot, chosen by the LHS type. Arrays
// keep their rich set (`.length`, `.dup`, ...); every type gets `.init`,
// `.sizeof`, `.alignof`, `.mangleof`, `.stringof`; numerics `.max`/`.min`
// (floats also `.nan`/`.infinity`/...); aggregates `.tupleof` and, for
// classes, `.classinfo`.
private void pushBuiltinProperties(Arena* a, ref CompleteOut o,
    ref bool[const(char)[]] seen, const(char)[] prefix, Type t)
{
    Type tb = t ? t.toBasetype() : null;
    const(char)[][] names = ["init", "sizeof", "alignof", "mangleof", "stringof"];
    if (tb)
        switch (tb.ty)
        {
        case TY.Tarray:
            names ~= ["length", "ptr", "dup", "idup", "capacity", "reserve",
                "reverse", "sort"];
            break;
        case TY.Tsarray:
            names ~= ["length", "ptr", "dup", "idup", "reverse", "sort"];
            break;
        case TY.Taarray:
            names ~= ["length", "keys", "values", "byKey", "byValue",
                "byKeyValue", "rehash", "dup", "get", "require", "update"];
            break;
        case TY.Tbool, TY.Tchar, TY.Twchar, TY.Tdchar,
            TY.Tint8, TY.Tuns8, TY.Tint16, TY.Tuns16, TY.Tint32, TY.Tuns32,
            TY.Tint64, TY.Tuns64, TY.Tint128, TY.Tuns128, TY.Tenum:
            names ~= ["max", "min"];
            break;
        case TY.Tfloat32, TY.Tfloat64, TY.Tfloat80,
            TY.Timaginary32, TY.Timaginary64, TY.Timaginary80,
            TY.Tcomplex32, TY.Tcomplex64, TY.Tcomplex80:
            names ~= ["max", "min", "min_normal", "nan", "infinity",
                "epsilon", "dig", "mant_dig", "max_10_exp", "min_10_exp",
                "max_exp", "min_exp"];
            break;
        default:
            break;
        }
    if (tb)
    {
        if (auto ts = tb.isTypeStruct())
            names ~= "tupleof";
        else if (auto tc = tb.isTypeClass())
        {
            names ~= "tupleof";
            if (tc.sym && tc.sym.isClassDeclaration())
                names ~= "classinfo";
        }
    }
    foreach (nm; names)
    {
        if (!hasPrefix(nm, prefix))
            continue;
        pushItem(a, o, nm, 10, "property", null, "1", seen);
    }
}

// The struct/class declaration a (possibly qualified/aliased) type denotes, or
// null for pointers/arrays/primitives.
private Dsymbol aggregateSym(Type t)
{
    if (!t)
        return null;
    Type tb = t.toBasetype();
    if (!tb)
        return null;
    if (auto ts = tb.isTypeStruct())
        return ts.sym;
    if (auto tc = tb.isTypeClass())
        return tc.sym;
    return null;
}

// Cap on UFCS candidates: without semantic overload/constraint filtering a
// large project offers thousands, which bloats the response (and the client's
// list) for little value. Real members are emitted first and are never capped
// by this.
private enum size_t ufcsCap = 100;

// UFCS candidates for `expr.`: free functions whose first parameter accepts
// `expr`'s aggregate type. dmd resolves these calls semantically (references
// already follow them, see `Visit(CallExp)`), but completion is heuristic, so
// only non-template functions with a directly matching first parameter are
// offered; real members were emitted first and win via `seen`.
private void addUfcsMembers(Arena* a, Module mod, Dsymbol[] rootMembers,
    Type lhsType, Dsymbol lhsAgg, const(char)[] prefix,
    ref bool[const(char)[]] seen, ref CompleteOut o)
{
    auto agg = aggregateSym(lhsType);
    if (!agg)
        agg = lhsAgg;
    if (!agg)
        return;
    foreach (m; rootMembers)
    {
        if (o.nitems >= ufcsCap)
            return;
        addUfcsCandidate(a, m, agg, prefix, seen, o);
    }
    // Direct imports only (no recursive public-import closure): the map-based
    // `indexImportInterfaces` walk was ~9 ms/request on a 60-module project.
    if (!mod || !mod.members)
        return;
    Dsymbol[] flat;
    flattenMembers(mod.members, flat);
    foreach (s; flat)
    {
        if (o.nitems >= ufcsCap)
            return;
        auto imp = s.isImport();
        if (!imp || imp.isstatic || !imp.mod || !imp.mod.members)
            continue;
        foreach (m; scopeMembers(imp.mod))
        {
            if (o.nitems >= ufcsCap)
                return;
            if (m.visible().kind == Visibility.Kind.private_)
                continue; // not callable from here
            addUfcsCandidate(a, m, agg, prefix, seen, o);
        }
    }
}

private void addUfcsCandidate(Arena* a, Dsymbol s, Dsymbol agg,
    const(char)[] prefix, ref bool[const(char)[]] seen, ref CompleteOut o)
{
    if (!s || !s.ident || o.nitems >= ufcsCap)
        return;
    auto fd = s.isFuncDeclaration();
    if (!fd)
        return; // template UFCS needs constraint evaluation; too noisy here
    auto tf = fd.type ? fd.type.isTypeFunction() : null;
    if (!tf || !tf.parameterList.parameters ||
        (*tf.parameterList.parameters).length == 0)
        return;
    auto p = (*tf.parameterList.parameters)[0];
    if (!p || !p.type)
        return;
    Type pt = p.type.toBasetype();
    Dsymbol psym = pt ? (pt.isTypeStruct() ? pt.isTypeStruct().sym
        : pt.isTypeClass() ? pt.isTypeClass().sym : null) : null;
    if (psym !is agg)
        return;
    auto nm = s.ident.toString();
    if (nm in seen || !hasPrefix(nm, prefix))
        return;
    // The receiver is passed as the first argument, so it is not part of the
    // signature the user sees (`ev.helper()` for `void helper(Event e)`).
    pushItem(a, o, nm, 3, typeDetail(fd.type), docOf(s), "1", seen, s, null,
        "UFCS", funcParamList(a, tf, false, true));
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
    Dsymbol[] rootMembers, NameType[] locals, int depth = 0,
    Type* valueType = null, Dsymbol* valueSym = null)
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
            // A later declaration with the same name shadows an earlier one;
            // slots are in source order, so keep the last match.
            shadowed = true;
            auto cm = followTypeDepth(v.type, root, rootMembers, depth + 1);
            // An aggregate slot (`this`/`super`) carries its declaration but no
            // type: step straight into it. Also covers a field whose resolved
            // type was wiped by an error.
            if (!cm.length && v.sym)
                cm = stepInto(v.sym, depth + 1, root, rootMembers);
            if (!cm.length && v.typeName.length)
            {
                // Unresolved (pre-semantic) type name: scope lookup.
                auto m = findMember(rootMembers, v.typeName);
                if (!m)
                    m = findImportMember(root, v.typeName);
                if (m)
                {
                    cm = stepInto(m, depth + 1, root, rootMembers);
                    if (valueSym)
                        *valueSym = m;
                }
            }
            curMembers = cm;
            if (valueType)
                *valueType = v.type ? v.type : (v.sym ? symType(v.sym) : null);
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
        if (valueType)
            *valueType = symType(cur);
        if (valueSym && cur.isAggregateDeclaration())
            *valueSym = cur;
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
        if (valueType)
            *valueType = symType(m);
        if (valueSym && m.isAggregateDeclaration())
            *valueSym = m;
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
        return aggregateMembers(ad, depth, root, rootMembers);
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
    // Inside a batch the same lookups repeat per token: answer from its
    // index (built by the same walk, so the first match is the same).
    if (g_batchImports !is null && g_batchRoot is root)
    {
        if (auto p = name in *g_batchImports)
            return *p;
        return null;
    }
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

// The import index of the running `resolveSymbolsBatch`, for its root.
private __gshared Dsymbol[const(char)[]]* g_batchImports;
private __gshared Module g_batchRoot;

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
// The loop variables of a lowered `foreach` over `opApply` live in the delegate
// passed to `opApply`, so collect its parameters (and anything declared in its
// body) when the cursor is inside it. Also covers ordinary delegate literals.
private void collectDelegateSlots(Expression e, uint cursorLine, ref NameType[] r,
    int depth)
{
    if (!e || depth > 8)
        return;
    if (auto fe = e.isFuncExp())
    {
        auto dfd = fe.fd;
        if (dfd && dfd.fbody)
        {
            uint el = dfd.endloc.linnum();
            if (dfd.loc.linnum() <= cursorLine && (el == 0 || cursorLine <= el))
            {
                if (dfd.parameters)
                    foreach (i; 0 .. dfd.parameters.length)
                    {
                        VarDeclaration v = (*dfd.parameters)[i];
                        if (v && v.ident)
                            r ~= NameType(v.ident.toString(), v.type, null, v);
                    }
                collectSemSlots(dfd.fbody, cursorLine, r);
            }
        }
        return;
    }
    if (auto ce = e.isCallExp())
    {
        if (ce.e1)
            collectDelegateSlots(ce.e1, cursorLine, r, depth + 1);
        if (ce.arguments)
            foreach (arg; *ce.arguments)
                collectDelegateSlots(arg, cursorLine, r, depth + 1);
        return;
    }
    if (auto ce = e.isCastExp())
    {
        collectDelegateSlots(ce.e1, cursorLine, r, depth + 1);
        return;
    }
    if (auto me = e.isCommaExp())
    {
        collectDelegateSlots(me.e1, cursorLine, r, depth + 1);
        collectDelegateSlots(me.e2, cursorLine, r, depth + 1);
        return;
    }
}

// A named type-level declaration in a function body (struct, class, enum,
// alias, template) declared by `cursorLine`, else null. Local variables and
// nested functions have their own handling.
private Dsymbol localTypeDecl(Dsymbol d, uint cursorLine)
{
    if (!d || !d.ident || d.loc.linnum() > cursorLine)
        return null;
    if (d.isAggregateDeclaration() || d.isEnumDeclaration() ||
        d.isAliasDeclaration() || d.isTemplateDeclaration())
        return d;
    return null;
}

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
                else if (auto ls = localTypeDecl(de.declaration, cursorLine))
                    r ~= NameType(ls.ident.toString(), null, null, ls);
            }
            else
                collectDelegateSlots(es.exp, cursorLine, r, 0);
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
    // For all of the following, descend only into the branch/body that
    // contains the cursor (by line range), so a sibling block's variable
    // with the same name is not offered as if it were in scope.
    if (auto is_ = s.isIfStatement())
    {
        uint end = is_.endloc.linnum();
        if (end != 0 && cursorLine > end)
            return; // past the whole if/else
        // The condition variable is in scope in both arms.
        if (is_.param && is_.param.ident && is_.ifbody &&
            cursorLine >= is_.ifbody.loc.linnum())
            r ~= NameType(is_.param.ident.toString(), is_.param.type, null, null);
        uint elseStart = is_.elsebody ? is_.elsebody.loc.linnum() : 0;
        if (elseStart != 0 && cursorLine >= elseStart)
            collectSemSlots(is_.elsebody, cursorLine, r);
        else
            collectSemSlots(is_.ifbody, cursorLine, r);
        return;
    }
    if (auto ws = s.isWhileStatement())
    {
        uint end = ws.endloc.linnum();
        if (end != 0 && cursorLine > end)
            return;
        if (ws.param && ws.param.ident)
            r ~= NameType(ws.param.ident.toString(), ws.param.type, null, null);
        collectSemSlots(ws._body, cursorLine, r);
        return;
    }
    if (auto ds = s.isDoStatement())
    {
        uint end = ds.endloc.linnum();
        if (end == 0 || cursorLine <= end)
            collectSemSlots(ds._body, cursorLine, r);
        return;
    }
    if (auto fs = s.isForStatement())
    {
        uint end = fs.endloc.linnum();
        if (end != 0 && cursorLine > end)
            return;
        collectSemSlots(fs._init, cursorLine, r);
        collectSemSlots(fs._body, cursorLine, r);
        return;
    }
    if (auto fes = s.isForeachStatement())
    {
        uint end = fes.endloc.linnum();
        if (end != 0 && cursorLine > end)
            return;
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
        uint end = sw.endloc.linnum();
        if (end != 0 && cursorLine > end)
            return;
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
        uint bodyEnd = tc.catches && (*tc.catches).length
            ? (*tc.catches)[0].handler.loc.linnum() : 0;
        if (bodyEnd == 0 || cursorLine < bodyEnd)
            collectSemSlots(tc._body, cursorLine, r);
        if (tc.catches)
            foreach (i; 0 .. (*tc.catches).length)
            {
                auto c = (*tc.catches)[i];
                uint hs = c.handler ? c.handler.loc.linnum() : 0;
                uint he = i + 1 < (*tc.catches).length
                    ? (*tc.catches)[i + 1].handler.loc.linnum() : 0;
                if (hs == 0 || cursorLine < hs || (he != 0 && cursorLine >= he))
                    continue;
                if (c.var && c.var.ident)
                    r ~= NameType(c.var.ident.toString(), c.var.type, null, c.var);
                collectSemSlots(c.handler, cursorLine, r);
            }
        return;
    }
    if (auto w = s.isWithStatement())
    {
        uint end = w.endloc.linnum();
        if (end != 0 && cursorLine > end)
            return;
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
    // Semantic locals shadow by scope: a nearer same-named declaration replaces
    // the outer one (source order, so the last write wins for a name).
    void put(NameType nt)
    {
        foreach (i, ref sl; slots)
            if (sl.name == nt.name)
            {
                slots[i] = nt;
                return;
            }
        slots ~= nt;
    }
    // An AST function range can be recovery-extended over following functions
    // (and its body left un-collapsed), so the semantic slots path can leak
    // across the boundary just like the snapshot did. If the cursor is outside
    // the enclosing function's lexical body, drop it and let the snapshot's
    // brace-scoped fallback below handle the locals.
    if (!funcScopedToLine(syn, fd, line))
        fd = null;
    assert(funcScopedToLine(syn, fd, line));
    if (fd && fd.parameters)
        foreach (i; 0 .. fd.parameters.length)
        {
            VarDeclaration v = (*fd.parameters)[i];
            if (!v || !v.ident)
                continue;
            if (v.loc.linnum() > line)
                continue;
            const(char)[] nm = v.ident.toString();
            put(NameType(nm, v.type, null, v));
        }
    if (fd && fd.fbody)
    {
        NameType[] surv;
        collectSemSlots(fd.fbody, line, surv);
        foreach (ref sl; surv)
            put(sl);
    }
    auto sfn = synFuncAt(syn, line);
    if (sfn)
        foreach (pi, pn; sfn.params)
        {
            if (has(pn))
                continue;
            string tn = pi < sfn.paramTypes.length ? sfn.paramTypes[pi] : null;
            slots ~= NameType(pn, null, tn, null);
        }
    // Candidate snapshot vars. When a function range matches, its captured
    // vars (bounded by the lexical body brace). When none does — recovery
    // merged this function into an earlier one — take every captured var whose
    // line shares the cursor's innermost lexer brace range, so the merged-away
    // function's locals stay usable without leaking a preceding one's.
    auto pool = snapshotLocals(syn, line, sfn);
    // Snapshot has no block scopes (body collapsed), so keep the nearest
    // declaration per name (line <= cursor).
    string[const(char)[]] synType;
    uint[const(char)[]] synLine;
    VarDeclaration[const(char)[]] synVd;
    foreach (ref vl; pool)
    {
        if (vl.line > line)
            continue;
        if (auto p = vl.name in synLine)
            if (*p >= vl.line)
                continue;
        synLine[vl.name] = vl.line;
        synType[vl.name] = vl.typeName;
        synVd[vl.name] = cast(VarDeclaration) vl.vd;
    }
    foreach (name, tn; synType)
    {
        // A semantic slot whose resolved type errored (Terror: the declaration
        // was rewritten by a bad statement in the body) keeps the pre-semantic
        // spelling, so a dotted chain can still resolve the type by name.
        auto vd = synVd[name];
        bool merged = false;
        foreach (ref sl; slots)
            if (sl.name == name)
            {
                merged = true;
                if ((!sl.type || sl.type.ty == TY.Terror) && tn.length)
                {
                    if (!sl.typeName.length)
                        sl.typeName = tn;
                }
                break;
            }
        if (merged)
            continue;
        // dmd resolved `.type` on the same node, even if a later
        // statement error collapsed the body; prefer it over the
        // pre-semantic spelling.
        Type t = vd && vd.type && vd.type.ty != TY.Terror ? vd.type : null;
        slots ~= NameType(name, t, tn, vd);
    }
    // Implicit `this`: the enclosing aggregate's members are in scope inside a
    // member function (or the aggregate body) even though they are not locals.
    // Locals already collected above win by name, matching D shadowing.
    if (auto ad = enclosingAggregate(mod, syn, line, fd))
    {
        foreach (m; aggregateMembers(ad))
        {
            if (!m.ident)
                continue;
            auto nm = m.ident.toString();
            if (nm == "this" || nm == "super" || nm == "_")
                continue;
            if (has(nm))
                continue;
            if (auto vd = m.isVarDeclaration())
                slots ~= NameType(nm, vd.type, identTypeName(vd.type), vd);
            else
                slots ~= NameType(nm, null, null, m);
        }
        slots ~= NameType("this", null, null, ad);
        if (auto cd = ad.isClassDeclaration())
            if (cd.baseClass)
                slots ~= NameType("super", null, null, cd.baseClass);
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
    collectSlots(mod, syn, ctx.line, findEnclosingFunc(mod, syn, ctx.line), slots);
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

// Tokens of one source line, via dmd's lexer (comments, strings and raw
// strings are the frontend's problem). Token charnums are 1-based columns.
private Token[] lexLineTokens(const(char)[] lt)
{
    import dmd.lexer : Lexer;
    import dmd.tokens : Token, TOK;
    import dmd.globals : global;

    Token[] toks;
    if (!lt.length)
        return toks;
    auto buf = lt.dup ~ '\0';
    scope lex = new Lexer(null, cast(char*) buf.ptr, 0, buf.length - 1,
        false, false, global.errorSinkNull, &global.compileEnv);
    while (true)
    {
        Token t;
        lex.scan(&t);
        if (t.value == TOK.endOfFile)
            break;
        // Point into `lt` itself, so a token's column is `ptr - lt.ptr`.
        // Its `loc` would do too, but every line lexed adds an entry to
        // dmd's file table, whose lookups then scan linearly (semantic
        // tokens lex every line of the document).
        t.ptr = lt.ptr + (t.ptr - buf.ptr);
        toks ~= t;
    }
    return toks;
}

// 0-based column in `lt` of a token from `lexLineTokens(lt)`.
private uint tokCol(const(char)[] lt, const ref Token t)
{
    return cast(uint)(t.ptr - lt.ptr);
}

// The dotted chain (as spelled in `lt`) ending at the identifier under `col`
// (0-based), or null. Token-based, so an identifier inside an index expression
// (`hate_table[target.ai.hate_count]`) is its own chain and does not merge with
// the array name, while `arr[0][i].member` keeps its index groups.
private const(char)[] chainFromTokens(const(char)[] lt, const(Token)[] toks,
    uint col)
{
    import dmd.tokens : TOK;

    int idx = -1;
    foreach (i, t; toks)
    {
        if (t.value != TOK.identifier)
            continue;
        // Token charnum is 1-based; compare in 0-based. The inclusive end also
        // accepts the 1-based columns the batch resolver passes (charnum) and
        // an end-of-word cursor (completion).
        uint start0 = tokCol(lt, t);
        uint len = cast(uint) t.ident.toString().length;
        if (col >= start0 && col <= start0 + len)
        {
            idx = cast(int) i;
            break;
        }
    }
    if (idx < 0)
        return null;

    size_t startIdx = idx;
    while (startIdx >= 1 && toks[startIdx - 1].value == TOK.dot)
    {
        int j = cast(int) startIdx - 2;
        // Skip any index groups attached to the left expression.
        while (j >= 0 && toks[j].value == TOK.rightBracket)
        {
            int depth = 0;
            int open = -1;
            for (int k = j; k >= 0; k--)
            {
                if (toks[k].value == TOK.rightBracket)
                    depth++;
                else if (toks[k].value == TOK.leftBracket)
                {
                    depth--;
                    if (depth == 0)
                    {
                        open = k;
                        break;
                    }
                }
            }
            if (open < 0)
                return null;
            j = open - 1;
        }
        if (j < 0 || toks[j].value != TOK.identifier)
            break;
        startIdx = cast(size_t) j;
    }

    uint c0 = tokCol(lt, toks[startIdx]) + 1;
    uint c1 = tokCol(lt, toks[idx]) + 1 +
        cast(uint) toks[idx].ident.toString().length;
    if (c0 < 1 || c0 > c1 || c1 > lt.length + 1)
        return null;
    return lt[c0 - 1 .. c1 - 1];
}

private const(char)[] chainInLine(const(char)[] lt, uint col)
{
    return chainFromTokens(lt, lexLineTokens(lt), col);
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
                sym = v.sym; // last (nearest) declaration shadows earlier ones
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
private void lineColOfOffset(const(char)[] text, size_t off, out uint line,
    out uint col)
{
    line = 1;
    col = 1;
    size_t n = off < text.length ? off : text.length;
    for (size_t i = 0; i < n; i++)
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

private const(char)[] lastSeg(const(char)[] chain)
{
    size_t s = chain.length;
    while (s > 0 && chain[s - 1] != '.')
        s--;
    return baseName(chain[s .. $]);
}

// Members of the value a *call* returns, for `expr(...).member`: a text
// chain stops at the `)`, so locate the call before the cursor's `.`, resolve
// its callee, and use the callee's return-type members. Null when the cursor
// is not a member of a call result.
private Dsymbol[] callLhsMembers(Module mod, const ref SynMod syn,
    const(char)[] text, uint line, uint col)
{
    size_t off = lineColToOffset(text, line, col);
    if (off > text.length)
        off = text.length;
    size_t p = off;
    while (p > 0 && isPc(text[p - 1]))
        p--;
    if (p == 0 || text[p - 1] != '.')
        return null;
    size_t q = p - 1; // index of '.'
    while (q > 0 && (text[q - 1] == ' ' || text[q - 1] == '\t'))
        q--;
    if (q == 0 || text[q - 1] != ')')
        return null;
    size_t closePos = q - 1;
    // Matching '(' for closePos, from a forward scan (strings/comments off).
    size_t[256] opens;
    size_t sp = 0;
    size_t i = 0;
    while (i < closePos)
    {
        char c = text[i];
        if (c == '/' && i + 1 < closePos && text[i + 1] == '/')
        {
            while (i < closePos && text[i] != '\n')
                i++;
            continue;
        }
        if (c == '/' && i + 1 < closePos && text[i + 1] == '*')
        {
            i += 2;
            while (i + 1 < closePos && !(text[i] == '*' && text[i + 1] == '/'))
                i++;
            i += 2;
            continue;
        }
        if (c == '"' || c == '\'' || c == '`')
        {
            char qc = c;
            i++;
            while (i < closePos && text[i] != qc)
            {
                if (text[i] == '\\' && qc != '`')
                    i++;
                i++;
            }
            i++;
            continue;
        }
        if (c == '(')
        {
            if (sp < opens.length)
                opens[sp++] = i;
        }
        else if (c == ')')
        {
            if (sp)
                sp--;
        }
        i++;
    }
    if (sp == 0)
        return null;
    size_t open = opens[sp - 1];
    size_t e = open;
    while (e > 0 && (text[e - 1] == ' ' || text[e - 1] == '\t'))
        e--;
    size_t s = e;
    while (s > 0 && (isPc(text[s - 1]) || text[s - 1] == '.' || text[s - 1] == '!'))
        s--;
    if (s == e)
        return null;
    uint cl, cc;
    lineColOfOffset(text, e - 1, cl, cc);
    auto sym = resolveSymbolAt(mod, syn, cl, cc, text);
    if (!sym)
        return null;
    Dsymbol[] rootMembers;
    flattenMembers(mod.members, rootMembers);
    if (auto fd = sym.isFuncDeclaration())
    {
        auto tf = fd.type ? fd.type.isTypeFunction() : null;
        if (tf && tf.next)
            return followTypeDepth(tf.next, mod, rootMembers, 0);
        return null;
    }
    if (sym.isAggregateDeclaration() || sym.isEnumDeclaration())
        return scopeMembers(sym);
    return null;
}

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
    auto fd = findEnclosingFunc(mod, syn, line);
    collectSlots(mod, syn, line, fd, locals);
    auto sym = resolveChain(mod, chain, rootMembers, rootByName, importByName,
        locals, fd);
    if (sym)
        return sym;
    // `expr(...).name`: text resolution stops at the ')'; fall back to the
    // call's return type.
    if (auto members = callLhsMembers(mod, syn, text, line, character))
    {
        auto nm = lastSeg(chain);
        foreach (m; members)
            if (m.ident && m.ident.toString() == nm)
            {
                auto t = m.toAlias();
                return (t && t !is m) ? t : m;
            }
    }
    return null;
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
    g_batchImports = &importByName;
    g_batchRoot = mod;
    scope (exit)
    {
        g_batchImports = null;
        g_batchRoot = null;
    }
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
    const(char)[] lineText = null;
    Token[] lineToks;
    FuncDeclaration fd;
    FuncDeclaration cachedFd;
    bool haveCached = false;
    NameType[] locals;
    foreach (i; 0 .. lines.length)
    {
        if (lines[i] != lastLine)
        {
            lastLine = lines[i];
            lineText = lineSlice(text, lineStart, lines[i]);
            lineToks = lexLineTokens(lineText);
            fd = enclosingFunc(funcs, lines[i]);
            // AST ranges can be recovery-extended over following functions;
            // accept fd only when the token is inside its lexical body.
            if (!funcScopedToLine(syn, fd, lines[i]))
                fd = null;
        }
        auto chain = chainFromTokens(lineText, lineToks, cols[i]);
        if (!chain.length)
            continue;
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
                // Prefer the snapshot's lexical body end. The AST end can run
                // past the closing brace (recovery / off-by-one) and would then
                // miss the bounded range for this function.
                auto sfn = synFuncAt(syn, fd.loc.linnum());
                uint el = sfn ? sfn.endLine : fd.endloc.linnum();
                if (el >= slotLine)
                    slotLine = el;
            }
            collectSlots(mod, syn, slotLine, fd, locals);
        }
        out_[i] = resolveChain(mod, chain, rootMembers, rootByName, importByName,
            locals, fd);
    }
}

// Build a jump target for an already-resolved symbol (dmd's own answer, from
// `references.resolvedSymbolAt`) or from the text-chain resolver's result.
void defLocOf(Arena* arena, Dsymbol sym, ref DefLoc out_)
{
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
    out_.len = sym.ident ? sym.ident.toString().length : 0;
}

void definitionAt(Arena* arena, Module mod, const CompleteCtx* ctx,
    const(char)[] text, const ref SynMod syn, ref DefLoc out_)
{
    defLocOf(arena, resolveSymbolAt(mod, syn, ctx.line, ctx.character, text), out_);
}

// The declaration a symbol is *typed* as, for `textDocument/typeDefinition`:
// a variable/field -> its type, a function -> its return type, an alias ->
// through. Aggregates/enums are already types.
private Dsymbol typeDeclOf(Dsymbol s)
{
    if (!s)
        return null;
    if (s.isAggregateDeclaration() || s.isEnumDeclaration())
        return s;
    if (auto vd = s.isVarDeclaration())
        return typeDeclSymbol(vd.type);
    if (auto fd = s.isFuncDeclaration())
    {
        auto tf = fd.type ? fd.type.isTypeFunction() : null;
        if (tf && tf.next)
            return typeDeclSymbol(tf.next);
        return null;
    }
    if (auto al = s.isAliasDeclaration())
    {
        auto t = al.toAlias();
        if (t && t !is s)
            return typeDeclOf(t);
        return typeDeclSymbol(al.type);
    }
    return null;
}

private Dsymbol typeDeclSymbol(Type t)
{
    if (!t)
        return null;
    if (auto te = t.isTypeEnum()) // before toBasetype(): it unwraps the enum
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

void typeDefinitionAt(Arena* arena, Module mod, const CompleteCtx* ctx,
    const(char)[] text, const ref SynMod syn, ref DefLoc out_)
{
    defLocOf(arena, typeDeclOf(resolveSymbolAt(mod, syn, ctx.line, ctx.character, text)), out_);
}

// The type-declaration target of an already-resolved symbol.
void typeDefinitionSymbol(Arena* arena, Dsymbol sym, ref DefLoc out_)
{
    defLocOf(arena, typeDeclOf(sym), out_);
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

// hdrgen prints the declaration name unqualified (`struct MyStruct`); splice in
// the fully-qualified name so `fullTypeHover` still shows which module the type
// comes from (`struct my.mod.MyStruct { ... }`).
private const(char)[] hdrgenQualified(Arena* a, Dsymbol sym)
{
    auto hd = hdrgenDecl(a, sym);
    if (!hd.length || !sym.ident)
        return hd;
    import core.stdc.string : strlen;
    const(char)* qp = sym.toPrettyChars();
    if (!qp)
        return hd;
    auto q = qp[0 .. strlen(qp)];
    auto id = sym.ident.toString();
    if (!id.length || q == id)
        return hd;
    // First whole-word occurrence of the declaration name.
    size_t at = size_t.max;
    foreach (i; 0 .. hd.length)
    {
        if (i + id.length > hd.length)
            break;
        if (hd[i .. i + id.length] == id &&
            (i == 0 || !isPc(hd[i - 1])) &&
            (i + id.length == hd.length || !isPc(hd[i + id.length])))
        {
            at = i;
            break;
        }
    }
    if (at == size_t.max)
        return hd;
    char[] buf;
    buf ~= hd[0 .. at];
    buf ~= q;
    buf ~= hd[at + id.length .. $];
    return arenaDupStr(a, buf);
}

// Render hover for an already-resolved symbol (dmd's `resolvedSymbolAt`, or
// the text-chain resolver's result).
// Short, fully-qualified declaration for an aggregate/enum: `struct mod.Name`
// rather than hdrgen's whole body. The body (members, enum `cast` values)
// reads as source code and is what users reported as noisy; the module
// qualification is what disambiguates a same-named symbol elsewhere.
private const(char)[] shortDecl(Arena* a, Dsymbol sym)
{
    import core.stdc.string : strlen;
    char[] buf;
    if (auto k = sym.kind())
    {
        buf ~= k[0 .. strlen(k)];
        buf ~= " ";
    }
    if (auto q = sym.toPrettyChars())
        buf ~= q[0 .. strlen(q)];
    return arenaDupStr(a, buf);
}

void hoverSymbol(Arena* arena, Dsymbol sym, ref HoverInfo out_,
    bool fullDecl = false)
{
    if (!sym)
        return;
    if (sym.isAggregateDeclaration() || sym.isEnumDeclaration())
    {
        // Types/enums: short qualified declaration by default; hdrgen's full
        // body (with the name qualified) when `fullTypeHover` is on.
        out_.detail = fullDecl ? hdrgenQualified(arena, sym) : shortDecl(arena, sym);
    }
    else
    {
        // Prefer dmd's own declaration renderer for functions/aliases. Not for
        // variables (hdrgen is header form: `extern int gval;`, and locals
        // become `extern S s;`) nor Module (it would dump the file).
        out_.detail = declLine(arena, sym);
        if (!sym.isVarDeclaration() && !sym.isModule())
        {
            if (auto hd = hdrgenDecl(arena, sym))
                if (hd.length)
                    out_.detail = hd;
        }
    }
    out_.doc = arenaDupStr(arena, docOf(sym));
    out_.found = out_.detail.length > 0 || out_.doc.length > 0;
}

void hoverAt(Arena* arena, Module mod, const CompleteCtx* ctx,
    const(char)[] text, const ref SynMod syn, ref HoverInfo out_,
    bool fullDecl = false)
{
    hoverSymbol(arena, resolveSymbolAt(mod, syn, ctx.line, ctx.character, text),
        out_, fullDecl);
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

// Within an initializer's braces [from, off), true when the cursor is in the
// *value* part of the current element (a top-level `:` precedes it). Only the
// field-name part scopes to the type's members; values use normal completion.
private bool inInitializerValue(const(char)[] text, size_t from, size_t off)
{
    int depth = 0;
    bool value = false;
    size_t k = from;
    while (k < off)
    {
        char c = text[k];
        if (c == '/' && k + 1 < off && text[k + 1] == '/')
        {
            while (k < off && text[k] != '\n')
                k++;
            continue;
        }
        if (c == '/' && k + 1 < off && text[k + 1] == '*')
        {
            k += 2;
            while (k + 1 < off && !(text[k] == '*' && text[k + 1] == '/'))
                k++;
            k += 2;
            continue;
        }
        if (c == '"' || c == '\'' || c == '`')
        {
            char q = c;
            k++;
            while (k < off && text[k] != q)
            {
                if (text[k] == '\\' && q != '`')
                    k++;
                k++;
            }
            k++;
            continue;
        }
        if (c == '(' || c == '[' || c == '{')
            depth++;
        else if (c == ')' || c == ']' || c == '}')
        {
            if (depth > 0)
                depth--;
        }
        else if (depth == 0)
        {
            if (c == ',')
                value = false; // next element starts
            else if (c == ':')
                value = true;
        }
        k++;
    }
    return value;
}

// If the cursor sits directly inside a `Type name = { ... }` struct
// initializer (D's designated initializer form), return the type name (a
// slice of `text`); null otherwise.
private const(char)[] structInitializerType(const(char)[] text, uint line,
    uint col)
{
    size_t off = lineColToOffset(text, line, col);
    if (off > text.length)
        off = text.length;
    char[128] kinds;
    size_t[128] poses;
    size_t sp = 0;
    size_t i = 0;
    bool isSpace(char c) pure nothrow @nogc @safe
    {
        return c == ' ' || c == '\t' || c == '\n' || c == '\r';
    }
    while (i < off)
    {
        char c = text[i];
        if (c == '/' && i + 1 < off && text[i + 1] == '/')
        {
            while (i < off && text[i] != '\n')
                i++;
            continue;
        }
        if (c == '/' && i + 1 < off && text[i + 1] == '*')
        {
            i += 2;
            while (i + 1 < off && !(text[i] == '*' && text[i + 1] == '/'))
                i++;
            i += 2;
            continue;
        }
        if (c == '"' || c == '\'' || c == '`')
        {
            char q = c;
            i++;
            while (i < off && text[i] != q)
            {
                if (text[i] == '\\' && q != '`')
                    i++;
                i++;
            }
            i++;
            continue;
        }
        if (c == '{' || c == '(' || c == '[')
        {
            if (sp < kinds.length)
            {
                kinds[sp] = c;
                poses[sp] = i;
                sp++;
            }
            i++;
            continue;
        }
        if (c == '}' || c == ')' || c == ']')
        {
            if (sp)
                sp--;
            i++;
            continue;
        }
        i++;
    }
    // Innermost open bracket must be the initializer's `{` (a cursor inside a
    // nested call/paren/array is a different completion context).
    if (sp == 0 || kinds[sp - 1] != '{')
        return null;
    size_t b = poses[sp - 1];
    size_t j = b;
    while (j > 0 && isSpace(text[j - 1]))
        j--;
    if (j == 0 || text[j - 1] != '=')
        return null;
    j--;
    while (j > 0 && isSpace(text[j - 1]))
        j--;
    size_t nameEnd = j;
    while (j > 0 && isPc(text[j - 1]))
        j--;
    if (j == nameEnd)
        return null; // no declared name before '='
    while (j > 0 && isSpace(text[j - 1]))
        j--;
    size_t typeEnd = j;
    while (j > 0 && (isPc(text[j - 1]) || text[j - 1] == '.'))
        j--;
    if (j == typeEnd)
        return null;
    auto tn = text[j .. typeEnd];
    if (tn == "auto")
        return null; // no type to resolve fields from
    if (inInitializerValue(text, b + 1, off))
        return null; // cursor is in a value, not a field name
    return tn;
}

// Import-statement completion: emit caller-provided names (module names, or a
// module's exported top-level members) directly. No analysis; the ops layer
// supplies the candidates.
void addImportItems(Arena* arena, ref CompleteOut out_, const(string)[] names,
    const(ubyte)[] kinds, const(char)[] detail)
{
    bool[const(char)[]] seen;
    foreach (i, nm; names)
    {
        ubyte k = i < kinds.length ? kinds[i] : cast(ubyte) 2;
        pushItem(arena, out_, nm, k, detail, null, "0", seen, null);
    }
}

// D keywords/type words, straight from dmd. Every token spelling is checked
// against the identifier pool (keywords are registered with their TOK value;
// a plain identifier's value is `TOK.identifier`), and C-only keywords are
// excluded by the same boundary the lexer uses (`FirstCKeyword`): that drops
// `signed`/`unsigned`/`sizeof`/`typedef`/`_Bool`/`__attribute__` and other
// spellings that are not D. Internal token names (`reserved`, `xstring`) never
// made it into the pool, so they are out too.
// True when the cursor sits where a statement/declaration may begin: the last
// significant token before it is `;`, `{`, `}` or `:` (the `:` covers labels
// and `case`/`default`, `}` covers the `else`/`catch`/`finally`/`do..while`
// continuations), or nothing precedes it. Keywords are offered only here, so
// they never appear mid-expression or after a dot.
private bool atStatementBoundary(const(char)[] text, uint line, uint col)
{
    import dmd.tokens : TOK;

    static bool trivia(TOK t)
    {
        return t == TOK.comment || t == TOK.whitespace || t == TOK.endOfLine;
    }
    if (line < 1)
        return true;
    size_t off = lineColToOffset(text, line, col);
    if (off > text.length)
        off = text.length;
    size_t ls = off;
    while (ls > 0 && text[ls - 1] != '\n')
        ls--;
    auto prefix = text[ls .. off];
    auto toks = lexLineTokens(prefix);
    // Ignore a trailing identifier that is the word currently being typed (it
    // ends exactly at the cursor): typing `swit`/`stru` must still see the
    // boundary before it, or keyword completion never fires.
    size_t n = toks.length;
    while (n > 0 && trivia(toks[n - 1].value))
        n--;
    if (n > 0 && toks[n - 1].value == TOK.identifier &&
        tokCol(prefix, toks[n - 1]) +
            toks[n - 1].ident.toString().length == prefix.length)
        n--;
    while (n > 0 && trivia(toks[n - 1].value))
        n--;
    TOK last = TOK.endOfFile;
    bool have = false;
    if (n > 0)
    {
        last = toks[n - 1].value;
        have = true;
    }
    uint l = line;
    while (!have && l > 1)
    {
        l--;
        size_t s = lineColToOffset(text, l, 0);
        size_t e = s;
        while (e < text.length && text[e] != '\n')
            e++;
        auto ptoks = lexLineTokens(text[s .. e]);
        foreach_reverse (t; ptoks)
            if (!trivia(t.value))
            {
                last = t.value;
                have = true;
                break;
            }
    }
    if (!have)
        return true; // start of the file/visible text
    switch (last)
    {
    case TOK.semicolon:
    case TOK.leftCurly:
    case TOK.rightCurly:
    case TOK.colon:
        return true;
    default:
        return false;
    }
}

private void addKeywordItems(Arena* a, ref CompleteOut o, const(char)[] prefix,
    ref bool[const(char)[]] seen)
{
    import dmd.identifier : Identifier;
    import dmd.tokens : Token, TOK, FirstCKeyword;
    foreach (i; 0 .. cast(int)TOK.max + 1)
    {
        auto nm = Token.toString(cast(TOK) i);
        if (nm.length == 0)
            continue;
        auto id = Identifier.lookup(nm);
        if (!id)
            continue;
        int v = id.getValue();
        if (v == cast(int) TOK.identifier || v >= cast(int) FirstCKeyword)
            continue;
        if (!hasPrefix(nm, prefix))
            continue;
        pushItem(a, o, nm, 14, "keyword", null, "2", seen);
        if (o.nitems >= 500)
            return;
    }
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
    auto fd = findEnclosingFunc(mod, syn, ctx.line);
    // Snapshot function (pre-semantic names; survives error rewrites).
    auto sfn = synFuncAt(syn, ctx.line);

    // `expr(...).` / `expr(...).pre` — a member of a call result. Handled
    // before the line-based chain split, because a bare trailing dot yields
    // no chain at all.
    if (auto members = callLhsMembers(mod, syn, text, ctx.line, ctx.character))
    {
        foreach (m; members)
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

    NameType[] slots;
    collectSlots(mod, syn, ctx.line, fd, slots);

    // Struct initializer `Type name = { ... }`: offer the type's fields by
    // name (D designated initializers), not the enclosing scope.
    if (auto tn = structInitializerType(text, ctx.line, ctx.character))
    {
        const(char)[][] tsegs;
        size_t ts = 0;
        foreach (k; 0 .. tn.length + 1)
        {
            if (k == tn.length || tn[k] == '.')
            {
                if (k > ts)
                    tsegs ~= tn[ts .. k];
                ts = k + 1;
            }
        }
        Dsymbol[] smembers;
        flattenMembers(mod.members, smembers);
        auto fields = resolveLhs(mod, tsegs, smembers, slots);
        if (fields.length)
        {
            foreach (m; fields)
            {
                if (!m.ident || !m.isVarDeclaration()) // fields only
                    continue;
                if (m.visible().kind == Visibility.Kind.private_)
                    continue;
                const(char)[] nm = m.ident.toString();
                if (!hasPrefix(nm, prefix))
                    continue;
                pushItem(arena, out_, nm, kindOf(m), typeDetail(symType(m)),
                    docOf(m), "0", seen, m);
                if (out_.nitems >= 500)
                    break;
            }
        }
        else
            out_.incomplete = true;
        return;
    }

    if (!hasDot)
    {
        // Plain: emit typed items first, then untyped snapshot names.
        if (fd)
            collectInFunc(fd, syn, ctx.line, prefix, arena, out_, seen);
        if (sfn)
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
        // Snapshot vars are in source order; a later same-named one
        // shadows an earlier one, so keep the nearest per name.
        string[const(char)[]] nearest;
        foreach (ref vl; snapshotLocals(syn, ctx.line, sfn))
            if (vl.line <= ctx.line)
            {
                // dmd's resolved type (survives a collapsed body) beats
                // the pre-semantic spelling.
                auto vd = cast(VarDeclaration) vl.vd;
                string disp = null;
                if (vd && vd.type && vd.type.ty != TY.Terror)
                    disp = typeDetail(vd.type).idup;
                if (!disp.length)
                    disp = vl.typeText.length ? vl.typeText : vl.typeName;
                nearest[vl.name] = disp;
            }
        foreach (name, tn; nearest)
        {
            if (name in seen || !hasPrefix(name, prefix))
                continue;
            pushItem(arena, out_, name, 6, "local", null, "0", seen, null, tn);
        }
        // Implicit `this`: enclosing aggregate fields/methods.
        if (auto ad = enclosingAggregate(mod, syn, ctx.line, fd))
            addAggregateMemberItems(arena, out_, seen, prefix, ad);
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
        Type lhsType;
        Dsymbol lhsAgg;
        auto scope_ = resolveLhs(mod, segs, rootMembers, slots, 0, &lhsType,
            &lhsAgg);
        // A plain `arr.` is the array itself, so offer the built-in properties;
        // `followTypeDepth` unwraps arrays only for indexed access (`arr[i].`).
        bool indexedLast = segs.length &&
            baseName(segs[$ - 1]).length != segs[$ - 1].length;
        if (lhsType && !indexedLast && isBuiltinArrayType(lhsType))
        {
            pushBuiltinProperties(arena, out_, seen, prefix, lhsType);
            return;
        }
        if (!scope_.length && !aggregateSym(lhsType) && !lhsAgg)
        {
            // No members (e.g. a primitive), but a resolved type still has
            // built-in properties: `int.` -> init, sizeof, max, min, ...
            if (lhsType)
            {
                pushBuiltinProperties(arena, out_, seen, prefix, lhsType);
                return;
            }
            out_.incomplete = true;
            return;
        }
        // Names reachable only through `alias this`: marked so the editor can
        // show which suggestions are promoted from the subobject.
        bool[const(char)[]] promoted;
        {
            Dsymbol aggM = aggregateSym(lhsType);
            if (!aggM)
                aggM = lhsAgg;
            if (auto ad = aggM ? aggM.isAggregateDeclaration() : null)
                if (ad.aliasthis && ad.aliasthis.sym)
                {
                    bool[const(char)[]] own;
                    foreach (m; scopeMembers(ad))
                        if (m.ident)
                            own[m.ident.toString()] = true;
                    foreach (m; stepInto(ad.aliasthis.sym, 0, mod, rootMembers))
                        if (m.ident)
                        {
                            auto pn = m.ident.toString();
                            if (pn !in own)
                                promoted[pn] = true;
                        }
                }
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
            const(char)[] marker = (nm in promoted) ? "alias this" : null;
            pushItem(arena, out_, nm, kindOf(m), typeDetail(symType(m)),
                docOf(m), "1", seen, m, null, marker);
            if (out_.nitems >= 500)
                break;
        }
        // UFCS: free functions callable as `expr.name(...)`.
        addUfcsMembers(arena, mod, rootMembers, lhsType, lhsAgg, prefix, seen,
            out_);
        // Built-in properties are valid on any expression.
        pushBuiltinProperties(arena, out_, seen, prefix, lhsType);
        return;
    }

    // Plain: locals already added; add module members + imports.
    {
        Dsymbol[] ms;
        flattenMembers(mod.members, ms);
        addMembers(arena, ms, prefix, "1", out_, seen);
    }
    walkImports(mod, 0, arena, prefix, out_, seen);
    addLocalImports(syn, ctx.line, arena, prefix, out_, seen);
    // Contextual keywords: only where a statement can begin.
    if (atStatementBoundary(text, ctx.line, ctx.character))
        addKeywordItems(arena, out_, prefix, seen);
}

// One import's completions: its local binding (the alias in
// `import custom = rt.dbg;`, else the leftmost name) plus, for a non-static
// import, the imported module's public interface.
private void addOneImport(Import imp, int depth, Arena* a, const(char)[] prefix,
    ref CompleteOut o, ref bool[const(char)[]] seen)
{
    if (imp.ident)
    {
        auto nm = imp.ident.toString();
        if (hasPrefix(nm, prefix))
        {
            const(char)[] d;
            if (imp.mod)
            {
                const(char)* mp = imp.mod.toPrettyChars();
                if (mp)
                {
                    import core.stdc.string : strlen;
                    d = mp[0 .. strlen(mp)];
                }
            }
            pushItem(a, o, nm, 9, d, null, "1", seen);
        }
    }
    if (!imp.mod || imp.isstatic)
        return; // static import: qualified access only
    addModuleInterface(imp.mod, depth, a, prefix, o, seen);
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
        if (auto imp = s.isImport())
            addOneImport(imp, depth, a, prefix, o, seen);
}

// Function-scoped `import`s visible at the cursor: every snapshot function
// whose body range contains the line, for imports declared at or before it.
private void addLocalImports(const ref SynMod syn, uint line, Arena* a,
    const(char)[] prefix, ref CompleteOut o, ref bool[const(char)[]] seen)
{
    foreach (ref fn; syn.funcs)
    {
        if (!fn.startLine || fn.startLine > line)
            continue;
        if (fn.endLine && line > fn.endLine)
            continue;
        foreach (ref li; fn.imports)
            if (li.line <= line)
                addOneImport(cast(Import) li.imp, 0, a, prefix, o, seen);
    }
}

// Add `m`'s own members, then follow its `public import`s (and theirs).
private void addModuleInterface(Module m, int depth, Arena* a, const(char)[] prefix,
    ref CompleteOut o, ref bool[const(char)[]] seen)
{
    if (!m || depth > 4 || !m.members)
        return;
    addMembers(a, scopeMembers(m), prefix, "1", o, seen, true);
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

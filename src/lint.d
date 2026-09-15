module lint;

// Tooling-side lint (no dmd changes): unused imports + unused params.
// Method: single post-semantic universe + lexical identifier use-set.
// Conservative skips (never false-positive):
//   imports: public/export imports, files with string-mixin or risky
//     __traits, failed compiles (baseline errors), empty/unresolved mods.
//   params: out params, functions with errors risk (same file skip when
//     baseline errors), bodies with string-mixin/risky traits.

import arena;
import lexutil;

import dmd.dimport : Import;
import dmd.dmodule : Module;
import dmd.dsymbol : Dsymbol, Visibility;
import dmd.func : FuncDeclaration;
import dmd.declaration : VarDeclaration;
import dmd.astenums : STC;
import dmd.attrib : ConditionalDeclaration;
import dmd.arraytypes : Dsymbols;
import dmd.dsymbol : DSYM;

// Child scopes to descend when walking members, including attribute
// blocks (`private:`, `@safe:`, ...) that hide declarations in
// real-world code.
private void appendScopeSubs(Dsymbol s, ref Dsymbol[] out_)
{
    if (auto ad = s.isAggregateDeclaration())
    {
        if (ad.members)
            foreach (m; (*ad.members)[])
                out_ ~= m;
    }
    else if (auto td = s.isTemplateDeclaration())
    {
        if (td.members)
            foreach (m; (*td.members)[])
                out_ ~= m;
    }
    else if (auto ns = s.isNspace())
    {
        if (ns.members)
            foreach (m; (*ns.members)[])
                out_ ~= m;
    }
    else if (auto at = s.isAttribDeclaration())
    {
        if (at.decl)
            foreach (m; (*at.decl)[])
                out_ ~= m;
        // NOTE: never D-cast dmd AST nodes (extern(C++) classes have no
        // runtime type check); tag-check first, then the cast is safe.
        if (at.dsym == DSYM.conditionalDeclaration)
        {
            auto cd = cast(ConditionalDeclaration)at;
            if (cd.elsedecl)
                foreach (m; (*cd.elsedecl)[])
                    out_ ~= m;
        }
    }
}

// Flat member list with attribute blocks expanded recursively.
private void flattenScopeMembers(Dsymbols* mem, ref Dsymbol[] out_)
{
    if (!mem)
        return;
    Dsymbol[] direct = null;
    foreach (m; (*mem)[])
        direct ~= m;
    flattenScopeArray(direct, out_);
}

private void flattenScopeArray(Dsymbol[] arr, ref Dsymbol[] out_)
{
    foreach (s; arr)
    {
        if (!s)
            continue;
        if (s.isAttribDeclaration())
        {
            Dsymbol[] subs = null;
            appendScopeSubs(s, subs);
            flattenScopeArray(subs, out_);
        }
        else
            out_ ~= s;
    }
}

struct UnusedHit
{
    string path;
    uint line = 0; // 1-based
    uint col = 0;  // 1-based
    ubyte kind = 0; // 0=import 1=param
    string name;
    uint endLine = 0; // import span end (for removal edit)
}

struct LintOut
{
    UnusedHit* hits = null; // Arena array
    size_t nhits = 0;
    size_t capHits = 0;
    bool skipped = false;
    string skipReason;
}

private void pushHit(Arena* a, ref LintOut o, UnusedHit h)
{
    if (o.nhits == o.capHits)
    {
        size_t ncap = o.capHits == 0 ? 32 : o.capHits * 2;
        UnusedHit* p = cast(UnusedHit*)a.alloc(ncap * UnusedHit.sizeof);
        if (!p)
            return;
        for (size_t i = 0; i < o.nhits; i++)
            p[i] = o.hits[i];
        o.hits = p;
        o.capHits = ncap;
    }
    o.hits[o.nhits++] = h;
}

// ---------- import span: find terminating ';' from (startLine,startCol) ----
private uint importEndLine(const(char)[] text, uint startLine, uint startCol)
{
    // Walk raw text tracking line/col; respect strings/comments; depth for ().
    size_t i = 0;
    uint line = 1;
    uint col = 1;
    // advance to start
    while (i < text.length && line < startLine)
    {
        if (text[i] == '\n')
            line++;
        i++;
    }
    // advance col on start line (approx: col counts chars)
    while (i < text.length && line == startLine && col < startCol)
    {
        if (text[i] == '\n')
        {
            line++;
            col = 1;
        }
        else
        {
            col++;
        }
        i++;
    }
    uint depth = 0;
    while (i < text.length)
    {
        char c = text[i];
        if (c == '\n')
        {
            line++;
            col = 1;
            i++;
            continue;
        }
        if (c == '/' && i + 1 < text.length && text[i + 1] == '/')
        {
            while (i < text.length && text[i] != '\n')
                i++;
            continue;
        }
        if (c == '/' && i + 1 < text.length && (text[i + 1] == '*' || text[i + 1] == '+'))
        {
            char closer = text[i + 1] == '*' ? '*' : '+';
            i += 2;
            col += 2;
            while (i + 1 < text.length && !(text[i] == closer && text[i + 1] == '/'))
            {
                if (text[i] == '\n')
                {
                    line++;
                    col = 1;
                }
                else
                    col++;
                i++;
            }
            i += 2;
            continue;
        }
        if (c == '"')
        {
            i++;
            while (i < text.length && text[i] != '"' && text[i] != '\n')
            {
                if (text[i] == '\\')
                    i++;
                i++;
            }
            if (i < text.length && text[i] == '"')
                i++;
            continue;
        }
        if (c == '\'')
        {
            i++;
            if (i < text.length && text[i] == '\\')
                i++;
            i++;
            if (i < text.length && text[i] == '\'')
                i++;
            continue;
        }
        if (c == '(')
            depth++;
        else if (c == ')')
        {
            if (depth > 0)
                depth--;
        }
        else if (c == ';' && depth == 0)
            return line;
        i++;
        col++;
    }
    return line;
}

// ---------- AST collection ----------
struct ImportRec
{
    Import imp;
    uint line = 0;
    uint col = 0;
    uint endLine = 0;
}

private void collectImportsRec(Dsymbol s, const(char)[] rootBase, ref ImportRec[] acc)
{
    if (auto imp = s.isImport())
    {
        // Only imports spelled in the root file (edits are local).
        auto fn = imp.loc.filename();
        string f = fn ? fn[0 .. strLen(fn)].idup : "";
        if (baseName(f) == rootBase)
        {
            ImportRec r;
            r.imp = imp;
            r.line = imp.loc.linnum();
            r.col = imp.loc.charnum();
            acc ~= r;
        }
        return;
    }
    // Recurse into member scopes (aggregates, namespaces, templates,
    // attribute blocks like `private:` — declarations hide inside them).
    // Function bodies excluded v1 (function-local imports never reported).
    Dsymbol[] subs = null;
    appendScopeSubs(s, subs);
    foreach (m; subs)
        collectImportsRec(m, rootBase, acc);
}

private size_t strLen(const(char)* p) nothrow @nogc
{
    size_t n = 0;
    while (p[n])
        n++;
    return n;
}

private string baseName(string p) pure @safe
{
    foreach_reverse (i, c; p)
    {
        if (c == '/' || c == '\\')
            return p[i + 1 .. $];
    }
    return p;
}

// Exported top-level names of mod + transitive public re-exports.
private void collectExported(Module mod, ref const(char)[][] out_, ref void*[] seen, int depth)
{
    if (!mod || depth > 8)
        return;
    foreach (v; seen)
        if (v is cast(void*)mod)
            return;
    seen ~= cast(void*)mod;
    if (mod.members)
    {
        Dsymbol[] flat = null;
        flattenScopeMembers(mod.members, flat);
        foreach (s; flat)
        {
            if (s.ident)
            {
                // Skip privates: not reachable from importer.
                auto vk = s.visible().kind;
                if (vk == Visibility.Kind.private_)
                    continue;
                out_ ~= s.ident.toString();
            }
            if (auto imp = s.isImport())
            {
                auto vk = imp.visibility.kind;
                if ((vk == Visibility.Kind.public_ || vk == Visibility.Kind.export_) && imp.mod)
                    collectExported(imp.mod, out_, seen, depth + 1);
            }
        }
    }
}

private bool inSet(const const(char)[][] set, const(char)[] name)
{
    foreach (s; set)
        if (s == name)
            return true;
    return false;
}

// Main entry: unused imports in root module `mod` (already semantic'd).
// `path` is the root file path as passed to parse; `text` its content.
void lintUnusedImports(Arena* arena, Module mod, const(char)[] path, const(char)[] text,
    bool hadErrors, ref LintOut out_)
{
    if (hadErrors)
    {
        out_.skipped = true;
        out_.skipReason = "baseline errors present";
        return;
    }
    if (!mod || !mod.members)
        return;
    string rootBase = baseName(path.idup);

    ImportRec[] imports;
    {
        Dsymbol[] flat = null;
        flattenScopeMembers(mod.members, flat);
        foreach (s; flat)
            collectImportsRec(s, rootBase, imports);
    }
    if (!imports.length)
        return;

    // Identifier use-set (whole file), minus import spans.
    ScanOut scan;
    if (!scanIdents(arena, text, 1, scan) || !scan.ok)
    {
        out_.skipped = true;
        out_.skipReason = "unscannable syntax (token strings?)";
        return;
    }
    if (scan.riskyMixin || scan.riskyTraits)
    {
        out_.skipped = true;
        out_.skipReason = "string mixin / reflective traits present";
        return;
    }

    // Compute import spans for exclusion.
    foreach (ref r; imports)
        r.endLine = importEndLine(text, r.line, r.col);

    foreach (ref r; imports)
    {
        Import imp = r.imp;
        auto vk = imp.visibility.kind;
        if (vk == Visibility.Kind.public_ || vk == Visibility.Kind.export_)
            continue; // re-export intent
        if (!imp.mod)
            continue; // unresolved: dmd already errored (but baseline clean?) — skip
        if (imp.mod.ident && rootBase == imp.mod.ident.toString() ~ ".d")
            continue; // self-import edge

        // Bind names for this import form.
        const(char)[][] binds;
        if (imp.names.length > 0)
        {
            foreach (i; 0 .. imp.names.length)
            {
                auto al = imp.aliases[i];
                auto nm = imp.names[i];
                binds ~= (al ? al.toString() : nm.toString());
            }
        }
        else
        {
            if (imp.aliasId)
                binds ~= imp.aliasId.toString();
            // qualification roots for static/plain forms
            if (imp.packages.length > 0)
                binds ~= imp.packages[0].toString();
            if (imp.id)
                binds ~= imp.id.toString();
            // plain import: all exported names (incl. transitive public)
            if (!imp.isstatic && !imp.aliasId)
            {
                const(char)[][] ex;
                void*[] seen;
                collectExported(imp.mod, ex, seen, 0);
                binds ~= ex;
            }
        }

        bool used = false;
        foreach (h; scan.hits[0 .. scan.nhits])
        {
            if (!inSet(binds, h.name))
                continue;
            // exclude occurrences inside any import span
            bool inImport = false;
            foreach (ref q; imports)
            {
                if (h.line < q.line || h.line > q.endLine)
                    continue;
                if (h.line == q.line && h.col < q.col)
                    continue;
                inImport = true;
                break;
            }
            if (!inImport)
            {
                used = true;
                break;
            }
        }
        if (!used)
        {
            const(char)[] disp = imp.aliasId ? imp.aliasId.toString() :
                imp.names.length > 0 ? imp.names[0].toString() :
                imp.id ? imp.id.toString() : "?";
            UnusedHit hit;
            hit.path = path.idup;
            hit.line = r.line;
            hit.col = r.col;
            hit.kind = 0;
            hit.name = disp.idup;
            hit.endLine = r.endLine;
            pushHit(arena, out_, hit);
        }
    }
}

// ---------- unused params ----------
void lintUnusedParams(Arena* arena, Module mod, const(char)[] path, const(char)[] text,
    bool hadErrors, ref LintOut out_)
{
    if (hadErrors || !mod || !mod.members)
        return;
    // Gather FuncDeclarations (module + aggregates + attribute blocks).
    FuncDeclaration[] funcs;
    void gather(Dsymbol s)
    {
        if (auto fd = s.isFuncDeclaration())
        {
            funcs ~= fd;
            return; // do not descend into bodies v1
        }
        Dsymbol[] subs = null;
        appendScopeSubs(s, subs);
        foreach (m; subs)
            gather(m);
    }
    foreach (s; (*mod.members)[])
        gather(s);

    // Split text into lines for body ranges.
    // (simple: reuse importEndLine-style? no — scan body range directly.)
    foreach (fd; funcs)
    {
        if (!fd.parameters || !fd.fbody)
            continue;
        if (!fd.ident)
            continue; // lambdas/literals v1 skip
        const(char)[] fname = fd.ident.toString();
        if (fname.length >= 2 && fname[0] == '_' && fname[1] == '_')
            continue;
        uint sl = fd.loc.linnum();
        uint el = fd.endloc.linnum();
        if (el < sl || sl < 1)
            continue;
        // Extract source range covering signature + body. The parameter's
        // own declaration is the first occurrence of its name (D is
        // declare-before-use), so: unused iff total occurrences < 2.
        // Shadowing may hide an unused param (safe false negative).
        const(char)[] body_ = sliceLines(text, sl, el);
        if (!body_.length)
            continue;
        ScanOut bs;
        if (!scanIdents(arena, body_, sl, bs) || !bs.ok)
            continue;
        if (bs.riskyMixin || bs.riskyTraits)
            continue;
        // build body name set
        foreach (i; 0 .. fd.parameters.length)
        {
            VarDeclaration v = (*fd.parameters)[i];
            if (!v.ident)
                continue;
            if (v.storage_class & (STC.out_ | STC.temp))
                continue; // must-write semantics / generated `__param_N`
            const(char)[] pn = v.ident.toString();
            if (pn == "this" || pn == "super" || pn == "_")
                continue;
            size_t count = 0;
            foreach (h; bs.hits[0 .. bs.nhits])
            {
                if (h.name == pn && ++count >= 2)
                    break;
            }
            if (count < 2)
            {
                UnusedHit hit;
                hit.path = path.idup;
                hit.line = sl;
                hit.col = 1;
                hit.kind = 1;
                hit.name = pn.idup;
                pushHit(arena, out_, hit);
            }
        }
    }
}

private const(char)[] sliceLines(const(char)[] text, uint fromLine, uint toLine)
{
    size_t i = 0;
    uint line = 1;
    size_t start = 0;
    size_t end = text.length;
    bool sset = false;
    while (i < text.length)
    {
        if (line == fromLine && !sset)
        {
            start = i;
            sset = true;
        }
        if (text[i] == '\n')
        {
            if (line == toLine)
            {
                end = i;
                break;
            }
            line++;
        }
        i++;
    }
    if (!sset)
        return null;
    return text[start .. end];
}

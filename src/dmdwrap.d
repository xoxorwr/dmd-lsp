module dmdwrap;

// Thin wrappers around dmd frontend as library (read-only use).
// RULE: dmd/ is never edited from here; this file only *calls* it.
// Struct-only; dmd class instances held as opaque void* outside this
// module, or as typed imports used locally in free functions.

import core.stdc.stdarg : va_list, va_copy, va_end;
import core.stdc.stdio : vsnprintf;
import core.stdc.string : strncmp;
import log : log;

import dmd.frontend : initDMD, deinitializeDMD, parseModule, addImport, addStringImport;
import dmd.common.charactertables : IdentifierCharLookup, IdentifierTable;
import dmd.dsymbolsem : dsymbolSemantic, importAll,
    runDeferredSemantic, runDeferredSemantic2, runDeferredSemantic3;
import dmd.semantic2 : semantic2;
import dmd.semantic3 : semantic3;
import dmd.errors : DiagnosticHandler, FatalErrorHandler;
import dmd.astcodegen : ASTCodegen;
import dmd.dsymbol : Dsymbol;
import dmd.dmodule : Module;
import dmd.console : Color;
import dmd.globals : global, FeatureState;
import dmd.location : SourceLoc;


//$table-begin: per-request diagnostic sink (single-threaded daemon) $table-end
struct DiagMsg
{
    string file;
    uint line = 0;
    uint col = 0;
    // 'E' error, 'W' warning, 'D' deprecation, 'S' supplemental, 'M' message
    char kind = 'E';
    string text;
}

struct DiagSink
{
    DiagMsg[] msgs;
    void reset() { msgs = null; }
}

__gshared DiagSink* gSink;

private bool onDiag(const ref SourceLoc loc, Color headerColor, const(char)* header,
    const(char)* fmt, va_list args, const(char)* p1, const(char)* p2) nothrow
{
    try
    {
        if (gSink is null)
            return false;
        char kind = 'E';
        if (header)
        {
            if (strncmp(header, "Error:", 6) == 0)
                kind = 'E';
            else if (strncmp(header, "Warning:", 8) == 0)
                kind = 'W';
            else if (strncmp(header, "Deprecation:", 12) == 0)
                kind = 'D';
            else
                kind = 'S'; // supplemental / context lines
        }
        // Format message (bounded; truncate rather than fail).
        char[8192] buf = void;
        va_list aq;
        va_copy(aq, args);
        int n = vsnprintf(buf.ptr, buf.length, fmt, aq);
        va_end(aq);
        string msg;
        if (n < 0)
            msg = "<format error>";
        else if (cast(size_t)n < buf.length)
            msg = buf[0 .. n].idup;
        else
            msg = (buf[0 .. $].idup ~ "...<truncated>");
        string prefix;
        if (p1 && *p1)
        {
            import core.stdc.string : strlen;
            prefix = p1[0 .. strlen(p1)].idup ~ " ";
        }
        if (p2 && *p2)
        {
            import core.stdc.string : strlen;
            prefix ~= p2[0 .. strlen(p2)].idup ~ " ";
        }
        DiagMsg m;
        m.file = loc.filename.idup;
        m.line = loc.line;
        m.col = loc.column;
        m.kind = kind;
        m.text = prefix ~ msg;
        gSink.msgs ~= m;
        return true; // handled: never print to stderr
    }
    catch (Exception)
    {
        return true;
    }
}

private bool onFatal() nothrow
{
    return true; // never exit() the daemon
}

struct DmdState
{
    bool inited = false;
    string[] importPaths;
    string[] stringPaths; // -J string import paths (import("...") files)
    string[] flags; // raw dmd flags (-preview=, -version=, -betterC, ...)
    ulong configGen = 0; // bumped on config change; invalidates cached universe
}

struct ParseOut
{
    void* module_ = null; // opaque dmd Module*
    uint errors = 0;
    bool ok = false;
}

// Parse only (no semantic). The returned module is pre-semantic:
// callers MUST snapshot any structure they need (function ranges,
// locals) BEFORE dmdSemantic, which rewrites bodies in place
// (e.g. failed statements propagate ErrorStatement up to fbody).
ParseOut dmdParseOnly(const(char)[] path, const(char)[] text)
{
    ParseOut r;
    auto tup = parseModule!ASTCodegen(path, text);
    auto m = tup.module_;
    if (m is null)
    {
        r.errors = global.errors;
        return r;
    }
    r.module_ = cast(void*)m;
    r.errors = global.errors;
    r.ok = true;
    return r;
}

// Parse a module WITHOUT registering it: no `Package.resolve` (so `parent`
// stays null), no `Module.modules`/`amodules` insertion, errors to a null sink
// and the global counters restored. This is what lets an index build run
// alongside a live semantic universe without evicting it — `dmdParseOnly`
// would collide on an already-registered module name and return the live one.
// The caller must roll back the `Loc` table it appended (`dmdLocCheckpoint`).
// Hack H3: see docs/hacks.md. Rebuild the FQN from `md.packages` + `ident`.
ParseOut dmdParseNoRegister(const(char)[] path, const(char)[] text,
    bool suppress = true)
{
    import dmd.root.filename : FileName;
    import dmd.identifier : Identifier;

    ParseOut r;
    // Restore the error counters afterwards so a parse cannot perturb the live
    // request. `suppress` also gags the sink (index builds); a consumer that
    // wants the diagnostics (lint) passes `false` and reads `s.sink`.
    auto savedErrors = global.errors;
    auto savedWarnings = global.warnings;
    auto savedGagged = global.gaggedErrors;
    auto savedGag = global.gag;
    if (suppress)
        global.gag = 1;
    scope (exit)
    {
        global.errors = savedErrors;
        global.warnings = savedWarnings;
        global.gaggedErrors = savedGagged;
        global.gag = savedGag;
    }
    auto id = Identifier.idPool(FileName.removeExt(FileName.name(path)));
    auto m = new Module(path, id, 1, 0);
    auto fb = cast(ubyte[]) text.dup ~ '\0';
    global.fileManager.add(FileName(path), fb);
    m.src = fb;
    m.importedFrom = m;
    m = m.parseModule!ASTCodegen(false);
    if (m is null)
    {
        r.errors = global.errors - savedErrors; // delta of this parse
        return r;
    }
    r.module_ = cast(void*)m;
    r.errors = global.errors - savedErrors;
    r.ok = true;
    return r;
}

// True when `path` is already a registered module (loaded as a root or as a
// dependency of one).
bool dmdModuleResident(const(char)[] path)
{
    import dmd.dmodule : Module;

    foreach (m; Module.amodules)
        if (m && m.srcfile.toString() == path)
            return true;
    return false;
}

// True when any module in the import closure has a failed load (its `Import.mod`
// is null). A scope search over a null import segfaults, so that — and only
// that — must gate semantic. A parse error in a loaded import also bumps
// `global.errors`, but must not gate: the LSP analyses mid-edit code, and
// gating on it would blank out every inferred type in the closure whenever any
// imported file is momentarily syntactically invalid.
private bool hasUnloadedImport(Module root)
{
    import dmd.dmodule : Module;
    import dmd.dimport : Import;

    if (root is null)
        return false;
    Module[] stack = [root];
    bool[Module] seen;
    while (stack.length)
    {
        auto cur = stack[$ - 1];
        stack.length--;
        if (cur is null || cur in seen)
            continue;
        seen[cur] = true;
        if (!cur.members)
            continue;
        foreach (i; 0 .. (*cur.members).length)
        {
            auto s = (*cur.members)[i];
            if (auto imp = s.isImport())
            {
                if (imp.mod is null)
                    return true;
                stack ~= imp.mod;
            }
        }
    }
    return false;
}

// Public probe: true when any module in `modp`'s import closure failed to load,
// which makes its semantic incomplete (references may be missed, rename must
// refuse). See `hasUnloadedImport`.
bool dmdHasUnloadedImport(void* modp)
{
    import dmd.dmodule : Module;

    return hasUnloadedImport(cast(Module)modp);
}

uint dmdSemantic(void* modp)
{
    import dmd.dmodule : Module;

    auto m = cast(Module)modp;
    m.importAll(null);
    if (hasUnloadedImport(m))
        return global.errors;
    dsymbolSemantic(m, null);
    runDeferredSemantic();
    semantic2(m, null);
    runDeferredSemantic2();
    semantic3(m, null);
    runDeferredSemantic3();
    return global.errors;
}

// Reset the error counters (and nothing else) so an incremental re-analysis
// can be measured the same way dmdResetRequest measures a full one. Does not
// touch the live universe.
void dmdResetCounters()
{
    import dmd.globals : global;

    global.errors = 0;
    global.warnings = 0;
    global.gaggedErrors = 0;
    global.gag = 0;
}

// Snapshot / restore the global Loc tables. `dmd.location` appends a BaseLoc
// (holding the entire file content) on every parse, so a long-lived consumer
// must roll back to the end of the initial build before each re-parse.
void dmdLocCheckpoint(ref size_t tableLen, ref uint index)
{
    import dmd.location : Loc;
    auto cp = Loc.checkpoint();
    tableLen = cp.tableLength;
    index = cp.index;
}

void dmdLocRollback(size_t tableLen, uint index)
{
    import dmd.location : Loc;
    Loc.rollback(Loc.Checkpoint(tableLen, index));
}

// Reset the frontend's global *caches* without tearing down the module
// registry, so a live universe can be re-analysed in place without the caches
// accumulating one generation per edit. This is the cache-only subset of
// `deinitializeDMD` (no `Module.deinitialize`, no `global.deinitialize`).
void dmdResetCaches()
{
    import dmd.dsymbol : Dsymbol;
    import dmd.dscope : Scope;
    import dmd.location : Loc;
    import funcsem = dmd.funcsem;
    import dsymbolsem = dmd.dsymbolsem;
    import typesem = dmd.typesem;
    import semantic3 = dmd.semantic3;
    import templatesem = dmd.templatesem;
    import dtemplate = dmd.dtemplate;
    import clone = dmd.clone;
    import arrayop = dmd.arrayop;

    // Only the module-scoped caches are cleared here. `Type.stringtable` and
    // the `Expression` singletons are deliberately left alone: re-initialising
    // them mid-universe recreates the basic `Type` objects and CTFE sentinels,
    // which breaks identity comparisons (`t is Type.tint32`) and semantic
    // against the still-live dependency closure. Module-specific `Type` entries
    // are handled by `dmdEvictRoot`.
    Dsymbol.deinitialize();
    funcsem.deinitialize();
    dsymbolsem.deinitialize();
    typesem.deinitialize();
    semantic3.deinitialize();
    templatesem.deinitialize();
    dtemplate.deinitialize();
    clone.deinitialize();
    arrayop.deinitialize();
    Scope.freelist = null;
    // Loc._init();
    import dmd.dmodule : Module;
    Module.deferred = Module.deferred.init;
    Module.deferred2 = Module.deferred2.init;
    Module.deferred3 = Module.deferred3.init;
    // CTFE caches every evaluated global constant, which keeps the constant's
    // declaration (and its module) alive across analyses.
    import dmd.dinterpret : dinterpret = deinitialize;
    dinterpret();
}

private bool containsSlice(const(char)[] hay, const(char)[] needle) pure nothrow @nogc @safe
{
    if (needle.length == 0 || hay.length < needle.length)
        return false;
    foreach (i; 0 .. hay.length - needle.length + 1)
        if (hay[i .. i + needle.length] == needle)
            return true;
    return false;
}

// Evict a module from the live universe so the same module name can be
// parsed again without collisions (incremental root re-analysis). Removes
// the module from its package symbol table and the global registries, and
// drops every interned type whose deco mentions the module's length-prefixed
// FQN token (`dmd.a` -> `3dmd1a`) — that covers types declared inside
// function bodies, which walking the members would miss. The dependency
// closure is left untouched.
void dmdEvictRoot(void* modp)
{
    import dmd.dmodule : Module, Package;
    import dmd.dsymbol : Dsymbol;
    import dmd.mtype : Type;
    import dmd.root.stringtable : StringValue;
    import dmd.root.aav : AssocArray;

    if (!modp)
        return;
    auto m = cast(Module)modp;

    // Build the mangled FQN token: each component as decimal length + bytes.
    auto fqn = m.toPrettyChars();
    size_t flen = 0;
    while (fqn[flen])
        flen++;
    char[] tok;
    for (size_t start = 0; start <= flen;)
    {
        size_t dot = start;
        while (dot < flen && fqn[dot] != '.')
            dot++;
        size_t v = dot - start;
        char[24] nb = void;
        size_t ni = nb.length;
        if (v == 0)
            nb[--ni] = '0';
        while (v)
        {
            nb[--ni] = cast(char)('0' + v % 10);
            v /= 10;
        }
        tok ~= nb[ni .. $];
        tok ~= fqn[start .. dot];
        if (dot == flen)
            break;
        start = dot + 1;
    }

    // Null the symbol table entry that holds the module (package.d uses a
    // wrapping Package; a package-less module lives in Module.modules).
    if (auto par = m.parent)
    {
        if (auto p = par.isPackage())
        {
            if (p.symtab)
            {
                auto pv = p.symtab.tab.getLvalue(m.ident);
                if (pv && *pv is m)
                    *pv = null;
            }
        }
    }
    if (auto pv = Module.modules.tab.getLvalue(m.ident))
        if (pv && *pv is m)
            *pv = null;
    foreach (i, mm; Module.amodules)
        if (mm is m)
        {
            Module.amodules.remove(i);
            break;
        }

    auto removedTypes = Type.stringtable.removeWhere((const(StringValue!Type)* sv)
        => containsSlice(sv.toString(), tok));
    import core.stdc.stdlib : getenv;
    if (getenv("DMD_LSP_TRACE_EVICT"))
        log("evict token=%.*s typesRemoved=%zu",
            cast(int) tok.length, tok.ptr, removedTypes);
}

// Re-parse a module in place with `text`, reusing the same Module object so
// importers' `imp.mod` and template-instance links keep pointing at it (a
// fresh Module would leave the closure pinned to the old one). The module's
// interned types are evicted first so semantic re-merges cleanly. The caller
// runs dmdSemantic on the returned module next; returns null on failure.
void* dmdReparseModule(void* modp, const(char)[] text)
{
    import dmd.dmodule : Module;
    import dmd.dsymbol : DsymbolTable, PASS;

    if (!modp)
        return null;
    auto m = cast(Module) modp;
    dmdEvictRoot(modp);
    dmdResetCaches(); // drop the previous generation's frontend caches
    // The reused Module still carries the previous run's semantic state, which
    // makes `dsymbolSemantic` short-circuit (visit(Module): semanticRun !=
    // initial -> return) and the import list. Reset both so the new members
    // are analysed from scratch.
    m.semanticRun = PASS.initial;
    m._scope = null;
    m.aimports = m.aimports.init;
    m.errors = 0;
    m.members = null; // drop the previous member list before parse replaces it
    m.symtab = null; // drop references to the previous members (fresh-module state)
    // Other symbol-bearing fields the previous semantic populated; left over
    // they anchor the replaced members.
    m.importedScopes = null; // imported modules + template mixins
    m.userAttribDecl = null;
    m.decldefs = null;
    m.tagSymTab = m.tagSymTab.init;
    m.contentImportedFiles = m.contentImportedFiles.init;
    // Invalidate the symbol-search cache: it holds a Dsymbol from the previous
    // parse (Module field at offset 360) and would otherwise pin the replaced
    // members for as long as the module object lives.
    m.searchCacheIdent = null;
    m.searchCacheSymbol = null;
    m.searchCacheFlags = typeof(m.searchCacheFlags).init;
    m.insearch = false;
    m.src = cast(const(ubyte)[]) (text.dup ~ '\0');
    return cast(void*) m.parseModule!ASTCodegen();
}

// True when some loaded module imports `modp`. Inside a closure that is
// exactly the "root is in an import cycle" case, and it means an in-place
// re-parse of the root would leave those importers holding stale symbols.
bool dmdRootHasImporters(void* modp)
{
    import dmd.dmodule : Module;
    auto root = cast(Module) modp;
    if (!root)
        return false;
    foreach (m; Module.amodules)
    {
        if (m is root || m.aimports.length == 0)
            continue;
        foreach (imp; m.aimports)
            if (imp is root)
                return true;
    }
    return false;
}

// True when `s` is a single D identifier (and not a keyword). Uses the
// frontend lexer so the keyword set stays in sync.
bool dmdIsPlainIdentifier(const(char)[] s)
{
    import dmd.lexer : Lexer;
    import dmd.tokens : Token, TOK;
    import dmd.globals : global;

    if (!s.length)
        return false;
    auto buf = s.dup ~ '\0';
    scope lex = new Lexer(null, cast(char*) buf.ptr, 0, buf.length - 1,
        false, false, global.errorSinkNull, &global.compileEnv);
    Token tok;
    lex.scan(&tok);
    if (tok.value != TOK.identifier)
        return false;
    Token t2;
    lex.scan(&t2);
    return t2.value == TOK.endOfFile;
}

// True when `text` can synthesise a reference to `name` that dmd's resolved
// AST does not contain: a string mixin or `__traits`/`is` expression (whose
// inner expression semantic evaluates with gagging and may discard). Uses the
// frontend lexer, and is name-aware so a `__traits` unrelated to `name` does
// not make the reference set incomplete.
bool dmdHasHiddenRefRisk(const(char)[] text, const(char)[] name)
{
    import dmd.lexer : Lexer;
    import dmd.tokens : Token, TOK;
    import dmd.globals : global;

    if (!text.length || !name.length)
        return false;
    auto buf = text.dup ~ '\0';
    scope lex = new Lexer(null, cast(char*) buf.ptr, 0, buf.length - 1,
        false, false, global.errorSinkNull, &global.compileEnv);

    // Copy each token's value + identifier/string text (string buffers may be
    // reused by the lexer).
    static struct T
    {
        TOK v;
        string s; // identifier name or string-literal content, else null
    }
    T[] toks;
    while (true)
    {
        Token t;
        lex.scan(&t);
        if (t.value == TOK.endOfFile)
            break;
        string s;
        if (t.ident)
            s = t.ident.toString().idup;
        else if (t.ustring && t.len)
            s = t.ustring[0 .. t.len].idup;
        toks ~= T(t.value, s);
    }

    static bool wordIn(const(char)[] hay, const(char)[] needle)
    {
        if (!needle.length || hay.length < needle.length)
            return false;
        foreach (i; 0 .. hay.length - needle.length + 1)
        {
            if (hay[i .. i + needle.length] != needle)
                continue;
            if (i > 0 && isWordChar(hay[i - 1]))
                continue;
            if (i + needle.length < hay.length && isWordChar(hay[i + needle.length]))
                continue;
            return true;
        }
        return false;
    }

    foreach (i, t; toks)
    {
        if (t.v != TOK.traits && t.v != TOK.mixin_ && t.v != TOK.is_)
            continue;
        if (i + 1 >= toks.length || toks[i + 1].v != TOK.leftParenthesis)
            continue;
        // A member-enumerating trait is risky regardless of any name.
        if (t.v == TOK.traits && i + 2 < toks.length && toks[i + 2].s.length)
        {
            auto tr = toks[i + 2].s;
            if (tr == "allMembers" || tr == "derivedMembers")
                return true;
        }
        // Scan the parenthesised region for the target name (identifier or
        // string literal). Dynamic mixins/traits with no literal also count.
        size_t depth = 0;
        bool sawString = false;
        for (size_t j = i + 1; j < toks.length; j++)
        {
            auto v = toks[j].v;
            if (v == TOK.leftParenthesis)
            {
                depth++;
                continue;
            }
            if (v == TOK.rightParenthesis)
            {
                depth--;
                if (depth == 0)
                    break;
                continue;
            }
            if (j == i + 1)
                continue;
            if (toks[j].s.length)
            {
                if (v == TOK.string_)
                    sawString = true;
                if (toks[j].s == name || wordIn(toks[j].s, name))
                    return true;
            }
        }
        // A `mixin(...)`/`is(...)` whose argument is not a string literal can
        // generate code we cannot inspect; treat it as risky.
        if (t.v == TOK.mixin_ && !sawString)
            return true;
    }
    return false;
}

private bool isWordChar(char c) pure nothrow @nogc @safe
{
    return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9');
}

// Fingerprint of a source's significant tokens (comments and whitespace are
// not tokens). Two texts with the same fingerprint differ only in trivia, so
// re-analysis can be skipped; unlike stripping whitespace/comments by hand,
// this never mistakes string/char literal content for trivia.
ulong dmdTokenHash(const(char)[] text)
{
    import dmd.lexer : Lexer;
    import dmd.tokens : Token, TOK;
    import dmd.globals : global;

    auto buf = text.dup ~ '\0';
    scope lex = new Lexer(null, cast(char*) buf.ptr, 0, buf.length - 1,
        false, false, global.errorSinkNull, &global.compileEnv);
    ulong h = 0xcbf29ce484222325UL;
    while (true)
    {
        Token tok;
        lex.scan(&tok);
        if (tok.value == TOK.endOfFile)
            break;
        h = (h ^ 0x1F) * 0x100000001b3UL;
        h = (h ^ cast(ubyte) tok.value) * 0x100000001b3UL;
        tok.toString((ubyte c) nothrow { h = (h ^ c) * 0x100000001b3UL; });
    }
    return h;
}

// Apply a supported subset of dmd command-line flags so analysis matches
// the project's real build (previews/versions change overload resolution,
// version blocks and template constraints). Unknown flags are ignored.
private void applyDmdFlags(string[] flags)
{
    import dmd.identifier : Identifier;

    foreach (f; flags)
    {
        if (f == "-betterC")
            global.params.betterC = true;
        else if (f.length > 9 && f[0 .. 9] == "-version=")
            global.versionids.push(Identifier.idPool(f[9 .. $]));
        else if (f.length > 9 && f[0 .. 9] == "-preview=")
            setFeature(f[9 .. $], true);
        else if (f.length > 8 && f[0 .. 8] == "-revert=")
            setFeature(f[8 .. $], false);
        else if (f.length > 2 && f[0 .. 2] == "-J")
            addStringImport(f[2 .. $]);
        else if (f.length > 2 && f[0 .. 2] == "-I")
            addImport(f[2 .. $]);
        // -release/-debug/-mcpu/... not modelled yet; ignore.
    }
}

private void setFeature(const(char)[] name, bool on)
{
    auto fs = on ? FeatureState.enabled : FeatureState.disabled;
    switch (name)
    {
    case "dip25": global.params.useDIP25 = fs; break;
    case "dip1000": global.params.useDIP1000 = fs; break;
    case "dip1008": global.params.ehnogc = on; break;
    case "dip1021": global.params.useDIP1021 = on; break;
    case "bitfields": global.params.bitfields = on; break;
    case "fieldwise": global.params.fieldwise = fs; break;
    case "fixaliasthis": global.params.fixAliasThis = on; break;
    case "intpromote": global.params.fix16997 = on; break;
    case "dtorfields": global.params.dtorFields = fs; break;
    case "rvaluerefparam": global.params.rvalueRefParam = fs; break;
    case "safer": global.params.safer = fs; break;
    case "nosharedaccess": global.params.noSharedAccess = fs; break;
    case "in": global.params.previewIn = on; break;
    case "inclusiveincontracts": global.params.inclusiveInContracts = on; break;
    case "shortenedmethods": global.params.shortenedMethods = on; break;
    case "fiximmutableconv": global.params.fixImmutableConv = on; break;
    case "systemvariables": global.params.systemVariables = fs; break;
    case "fastdfa": global.params.useFastDFA = on; break;
    default: break;
    }
}

void dmdInit(ref DmdState st)
{
    if (st.inited)
        return;
    DiagnosticHandler h = (const ref SourceLoc loc, Color hc, const(char)* header,
        const(char)* fmt, va_list args, const(char)* p1, const(char)* p2) {
        return onDiag(loc, hc, header, fmt, args, p1, p2);
    };
    FatalErrorHandler f = () { return onFatal(); };
    initDMD(h, f);
    global.errorSink.errorLimit = 0; // unlimited; daemon must survive error storms
    // initDMD leaves the identifier tables unset (stock sets them from CLI
    // flags in main.d); without them any non-ASCII identifier segfaults the
    // lexer via null table function pointers. Mirror stock's default (LR).
    global.compileEnv.dCharLookupTable = IdentifierCharLookup.forTable(IdentifierTable.LR);
    global.compileEnv.cCharLookupTable = IdentifierCharLookup.forTable(IdentifierTable.LR);
    foreach (p; st.importPaths)
        addImport(p);
    foreach (p; st.stringPaths)
        addStringImport(p);
    applyDmdFlags(st.flags);
    st.inited = true;
}

void dmdDeinit(ref DmdState st)
{
    if (!st.inited)
        return;
    deinitializeDMD();
    st.inited = false;
}

// Drop dmd globals that `deinitializeDMD` leaves behind. `Module.amodules`
// (plus the deferred-semantic queues) are `Array` instances backed by
// GC-scanned memory, and `Module.deinitialize()` resets `modules` but not
// these, so stale module registrations survive a reset. Resetting to
// `.init` drops the backing block, not just its length.
private void dmdResetGlobals()
{
    import dmd.dmodule : Module;
    import dmd.dclass : ClassDeclaration;
    import dmd.mtype : Type;
    import dmd.dtemplate : TemplateValueParameter;
    import dmd.dscope : Scope;
    import dmd.dstruct : StructDeclaration;

    Module.amodules = Module.amodules.init;
    Module.deferred = Module.deferred.init;
    Module.deferred2 = Module.deferred2.init;
    Module.deferred3 = Module.deferred3.init;
    Module.rootModule = null;
    Module.moduleinfo = null;

    // Universe-holding caches that deinitializeDMD does not clear; they must
    // be dropped before the region is freed or they dangle.
    ClassDeclaration.object = null;
    ClassDeclaration.throwable = null;
    ClassDeclaration.exception = null;
    ClassDeclaration.errorException = null;
    ClassDeclaration.cpp_type_info_ptr = null;
    Scope.freelist = null;
    TemplateValueParameter.edummies = null;
    StructDeclaration.xerreq = null;
    StructDeclaration.xerrcmp = null;
    Type.dtypeinfo = null;
    Type.typeinfoclass = null;
    Type.typeinfointerface = null;
    Type.typeinfostruct = null;
    Type.typeinfopointer = null;
    Type.typeinfoarray = null;
    Type.typeinfostaticarray = null;
    Type.typeinfoassociativearray = null;
    Type.typeinfovector = null;
    Type.typeinfoenum = null;
    Type.typeinfofunction = null;
    Type.typeinfodelegate = null;
    Type.typeinfotypelist = null;
    Type.typeinfoinvariant = null;
    Type.typeinfoshared = null;
    Type.typeinfowild = null;
}


// Manual per-request global reset (full universe re-init).

// Enumerated reset surface (see plan):
//   errors/warnings/deprecations/gag counters, Module registry
//   (modules/amodules/deferred queues), FileManager, Id/Type/target
//   tables, Loc tables, errorLimit.
void dmdResetRequest(ref DmdState st, DiagSink* sink,
    scope void delegate() nothrow regionReset = null)
{
    auto saved = st.importPaths;
    auto savedStr = st.stringPaths;
    if (st.inited)
        deinitializeDMD();
    dmdResetGlobals();
    // Reclaim transient OutBuffer stores (e.g. cached file contents) from the
    // discarded universe; independent of any arena reset.
    import dmd.root.scratch : resetScratch;
    resetScratch();
    if (regionReset !is null)
    {
        regionReset(); // free the run's arena between clearing and re-init
        // The Identifier table lives in persistent memory but its values point
        // into the freed arena; drop the stale entries (and counters), then
        // re-register the keywords *before* dmdInit (whose Id.initialize then
        // finds them, matching stock deinit/init order).
        import dmd.identifier : Identifier;
        import dmd.tokens : initializeKeywords;
        import dmd.dinterpret : reinitAfterRegion;
        reinitAfterRegion();
        Identifier.reinitAfterRegion();
        initializeKeywords();
    }
    st.inited = false;
    st.importPaths = saved;
    st.stringPaths = savedStr;
    dmdInit(st);
    gSink = sink;
    if (sink)
        sink.reset();
    global.gag = 0;
    global.gaggedErrors = 0;
    // `_init` built a fresh FileManager: re-install the open-doc mirror.
    dmdReapplyDocMirror();
}

// ---- Cross-request module cache (hit support) ----
//
// The last analysis's dmd universe is kept alive across requests. A request
// with identical inputs (same root text, same dep disk bytes, same config)
// is served from cache with zero dmd work (see server.Universe).
// Deps are fingerprinted from the bytes dmd consumed (`Module.src`). For an
// open document that is the server's unsaved buffer (the mirror below); for
// everything else it is the disk bytes — see `universeDepsChanged`.

// One recorded dependency: path + content hash of what the parser consumed
// (Module.src: unsaved mirror bytes for open docs, disk bytes otherwise).
struct DepRec
{
    string path;
    ulong hash;
}

// Record post-analysis fingerprints for every loaded module except the
// root (the root is tracked by session text, which may differ from disk).
void universeRecord(ref DepRec[] deps, const(char)[] rootPath)
{
    import dmd.dmodule : Module;
    import session : fnv1a64;

    deps = null;
    foreach (m; Module.amodules)
    {
        if (!m)
            continue;
        string p = m.srcfile.toString().idup;
        if (p == rootPath)
            continue;
        deps ~= DepRec(p, depHash(cast(const(ubyte)[])m.src));
    }
}

// True when any recorded dep's current bytes differ. A dep that is an open
// document is compared against the pushed mirror (unsaved edits count as a
// change); everything else against disk (missing counts as changed — the
// rebuild then reports the proper error).
bool universeDepsChanged(const DepRec[] deps)
{
    import session : hashFileDisk, fnv1a64;

    foreach (ref d; deps)
    {
        if (auto mv = d.path in g_docMirror)
        {
            if (depHash(*mv) != d.hash)
                return true;
            continue;
        }
        ulong h;
        if (!hashFileDisk(d.path, h) || h != d.hash)
            return true;
    }
    return false;
}

// ---- Open-document mirror (hack H4, docs/hacks.md) ----
// The server pushes the current text of open documents; the worker keeps this
// map (worker-global, so it survives `dmdResetRequest`, which rebuilds the
// FileManager) and reapplies it after every reset. dmd then reads a dependency
// that is open in the editor as the unsaved buffer, not stale disk bytes.
private __gshared const(ubyte)[][string] g_docMirror;

// Content hash of a source buffer, ignoring a trailing NUL. Mirrored buffers
// are NUL-terminated (like the root parse) while disk reads are not, so
// hashing verbatim made opening a dependency flip its hash and spuriously
// invalidate the warm universe — respawning the worker per keystroke.
private ulong depHash(const(ubyte)[] b)
{
    import session : fnv1a64;

    auto s = b;
    if (s.length && s[$ - 1] == 0)
        s = s[0 .. $ - 1];
    return fnv1a64(s);
}

void dmdSetDoc(const(char)[] path, const(char)[] text)
{
    import dmd.root.filename : FileName;

    auto buf = cast(const(ubyte)[]) (text.dup ~ '\0');
    g_docMirror[path.idup] = buf;
    if (global.fileManager !is null)
        global.fileManager.setFileContents(FileName(path.idup), buf);
}

void dmdRemoveDoc(const(char)[] path)
{
    import dmd.root.filename : FileName;

    g_docMirror.remove(path.idup);
    if (global.fileManager !is null)
        global.fileManager.removeFileContents(FileName(path.idup));
}

void dmdReapplyDocMirror()
{
    import dmd.root.filename : FileName;

    if (global.fileManager is null)
        return;
    foreach (path, buf; g_docMirror)
        global.fileManager.setFileContents(FileName(path), buf);
}

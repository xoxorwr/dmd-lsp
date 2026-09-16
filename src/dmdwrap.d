module dmdwrap;

// Thin wrappers around dmd frontend as library (read-only use).
// RULE: dmd/ is never edited from here; this file only *calls* it.
// Struct-only; dmd class instances held as opaque void* outside this
// module, or as typed imports used locally in free functions.

import core.stdc.stdarg : va_list, va_copy, va_end;
import core.stdc.stdio : vsnprintf;
import core.stdc.string : strncmp;

import dmd.frontend : initDMD, deinitializeDMD, parseModule, addImport, addStringImport;
import dmd.common.charactertables : IdentifierCharLookup, IdentifierTable;
import dmd.dsymbolsem : dsymbolSemantic, importAll,
    runDeferredSemantic, runDeferredSemantic2, runDeferredSemantic3;
import dmd.semantic2 : semantic2;
import dmd.semantic3 : semantic3;
import dmd.errors : DiagnosticHandler, FatalErrorHandler;
import dmd.astcodegen : ASTCodegen;
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

// Stepped semantic mirroring stock main.d gates: import (load) errors
// stop before semantic. A scope search over a failed import (mod == null)
// segfaults, stock only avoids it via the gate — so must we.
// NOTE: parse errors do NOT stop us: dmd recovers from them and an LSP
// must analyse broken code (mixins expand via CTFE, `auto` infers, ...).
// Only errors *introduced by importAll* gate semantic.
// Returns: semantic-phase error count (parse errors excluded).
uint dmdSemantic(void* modp)
{
    import dmd.dmodule : Module;

    auto m = cast(Module)modp;
    uint beforeImport = global.errors;
    m.importAll(null);
    if (global.errors != beforeImport)
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

    Type.stringtable.removeWhere((const(StringValue!Type)* sv)
        => containsSlice(sv.toString(), tok));
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
void dmdResetRequest(ref DmdState st, DiagSink* sink)
{
    auto saved = st.importPaths;
    auto savedStr = st.stringPaths;
    if (st.inited)
        deinitializeDMD();
    dmdResetGlobals();
    st.inited = false;
    st.importPaths = saved;
    st.stringPaths = savedStr;
    dmdInit(st);
    gSink = sink;
    if (sink)
        sink.reset();
    global.gag = 0;
    global.gaggedErrors = 0;
}

// ---- Cross-request module cache (hit support) ----
//
// The last analysis's dmd universe is kept alive across requests. A request
// with identical inputs (same root text, same dep disk bytes, same config)
// is served from cache with zero dmd work (see server.Universe).
// Deps are fingerprinted from DISK bytes (what dmd consumes). Unsaved dep
// edits in open docs therefore disable the cache until save — same cost as
// the old always-rebuild behavior, never stale results.

// One recorded dependency: path + content hash of what the parser consumed
// (Module.src, i.e. exact disk bytes for deps).
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
        deps ~= DepRec(p, fnv1a64(cast(const(ubyte)[])m.src));
    }
}

// True when any recorded dep's current disk bytes differ (missing file
// counts as changed — the rebuild then reports the proper error).
bool universeDepsChanged(const DepRec[] deps)
{
    import session : hashFileDisk;

    foreach (ref d; deps)
    {
        ulong h;
        if (!hashFileDisk(d.path, h) || h != d.hash)
            return true;
    }
    return false;
}

module dmdwrap;

// Thin wrappers around the dmd frontend: the diagnostic sink, parse and
// semantic entry points, and flag handling. Which memory level any of this
// lands on is decided by the caller (engine.d / layers.d).
// Struct-only; dmd class instances held as opaque void* outside this
// module, or as typed imports used locally in free functions.

import core.stdc.stdarg : va_list, va_copy, va_end;
import core.stdc.stdio : vsnprintf;
import core.stdc.string : strncmp;
import dmd.frontend : addImport, addStringImport;
import dmd.dsymbolsem : dsymbolSemantic, importAll,
    runDeferredSemantic, runDeferredSemantic2, runDeferredSemantic3;
import dmd.semantic2 : semantic2;
import dmd.semantic3 : semantic3;
import dmd.errors : DiagnosticHandler, FatalErrorHandler, ErrorSinkCompiler;
import dmd.errorsink : ErrorKind;
import dmd.astcodegen : ASTCodegen;
import dmd.dmodule : Module;
import dmd.console : Color;
import dmd.globals : global, FeatureState;
import dmd.location : SourceLoc;


// Diagnostic sink (single-threaded daemon).
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
    // Messages outlive the level that reports them: allocate on level 0.
    import layers : levelSuspend, levelResume;

    auto lt = levelSuspend();
    scope (exit)
        levelResume(lt);
    try
    {
        if (gSink is null)
            return true; // nobody listening: still never print
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

// dmd's compiler sink prints plain messages (`pragma(msg)`, `-v`) straight to
// stdout, bypassing the diagnostic handler. In the server, stdout is the LSP
// stream: send them to stderr (the log) instead, like any other chatter.
extern (C++) final class LspErrorSink : ErrorSinkCompiler
{
    override void emit(const SourceLoc loc, const(char)* format, va_list ap,
        ErrorKind kind, bool supplemental, bool gagged)
    {
        if (kind != ErrorKind.message || supplemental)
            return super.emit(loc, format, ap, kind, supplemental, gagged);
        import core.stdc.stdio : fprintf, vfprintf, fputc, stderr;

        if (loc.filename.length)
            fprintf(stderr, "%.*s(%u): ", cast(int) loc.filename.length, loc.filename.ptr, loc.line);
        vfprintf(stderr, format, ap);
        fputc('\n', stderr);
    }
}

ErrorSinkCompiler newLspErrorSink()
{
    auto s = new LspErrorSink();
    s.errorLimit = 0; // unlimited: a daemon must survive error storms
    return s;
}

DiagnosticHandler diagHandler()
{
    return (const ref SourceLoc loc, Color hc, const(char)* header, const(char)* fmt,
        va_list args, const(char)* p1, const(char)* p2) {
        return onDiag(loc, hc, header, fmt, args, p1, p2);
    };
}

FatalErrorHandler fatalHandler()
{
    return () { return onFatal(); };
}

struct ParseOut
{
    void* module_ = null; // opaque dmd Module*
    uint errors = 0;
    bool ok = false;
}

// Parse a module WITHOUT registering it: no `Package.resolve` (so `parent`
// stays null), no `Module.modules`/`amodules` insertion, errors to a null sink
// and the global counters restored. A registered parse would collide with a
// module of the same name already loaded on a lower level (and return that
// one). Callers run it on a scratch level (`engineScratch`), which drops
// everything it allocated. The FQN is rebuilt from `md.packages` + `ident`.
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
    import dmd.parse : Parser;

    auto id = Identifier.idPool(FileName.removeExt(FileName.name(path)));
    auto m = new Module(path, id, 1, 0);
    auto fb = cast(ubyte[]) text.dup ~ '\0';
    m.src = fb;
    m.importedFrom = m;
    // `Module.parseModule` minus its registration step (package tree, module
    // table): drive the parser directly. Editor text is UTF-8, so the only
    // source processing left is dropping a byte-order mark.
    auto buf = cast(const(char)[]) fb;
    if (buf.length >= 3 && buf[0 .. 3] == "\xEF\xBB\xBF")
        buf = buf[3 .. $];
    scope p = new Parser!ASTCodegen(m, buf, false, global.errorSink, &global.compileEnv, false);
    p.nextToken();
    p.parseModuleDeclaration();
    m.md = p.md;
    if (m.md)
        m.ident = m.md.id;
    m.members = p.parseModuleContent();
    m.numlines = p.linnum;
    r.module_ = cast(void*)m;
    r.errors = global.errors - savedErrors;
    r.ok = true;
    return r;
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
        // `ident` and the string literal share a union in `Token`: pick by
        // token kind, never by which pointer happens to be non-null.
        string s;
        if (t.value == TOK.identifier && t.ident)
            s = t.ident.toString().idup;
        else if (t.value == TOK.string_ && t.ustring && t.len)
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

void applyDmdFlags(string[] flags)
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

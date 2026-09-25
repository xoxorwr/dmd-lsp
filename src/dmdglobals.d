// The static variables of the vendored dmd frontend, as byte ranges.
//
// A memory level (layers.d) snapshots these at push and restores them at pop.
// Heap state needs no list: the write-protected lower heaps capture it. Static
// state is the one part the MMU cannot scope to dmd, so it is enumerated here:
//
//   * module-level variables and static members of aggregates, found by
//     compile-time reflection over every module in dmdmodules.d, so a new
//     global upstream is covered by regenerating that list;
//   * function-local statics, which reflection cannot reach, declared below by
//     their mangled names. `make check-statics` fails when the vendored tree
//     has one that is not listed.
module dmdglobals;

import dmdmodules : dmdModules;

// Every range, sorted and merged. Computed once; the addresses are static
// (and the only TLS variable is used on the analysis thread).
const(void[])[] dmdGlobalRanges() nothrow
{
    __gshared const(void[])[] cached;
    if (cached is null)
        cached = collect();
    return cached;
}

size_t dmdGlobalBytes() nothrow
{
    size_t n = 0;
    foreach (r; dmdGlobalRanges())
        n += r.length;
    return n;
}

private:

import core.stdc.stdlib : malloc, realloc, qsort;

struct R
{
    size_t lo;
    size_t hi;
}

__gshared R* gRanges;
__gshared size_t gCount;

void add(const void* p, size_t n) nothrow @nogc
{
    if (n == 0)
        return;
    gRanges = cast(R*) realloc(gRanges, (gCount + 1) * R.sizeof);
    gRanges[gCount++] = R(cast(size_t) p, cast(size_t) p + n);
}

template isStaticVar(alias sym)
{
    // `&f` of a @property is a function pointer, not the address of data.
    static if (!__traits(isStaticFunction, sym) && !is(typeof(sym) == function)
        && is(typeof(&sym) == U*, U) && !is(U == function))
        enum isStaticVar = !is(U == immutable) && !is(U == const);
    else
        enum isStaticVar = false;
}

// Module-level variables, and the statics of aggregates declared in `Scope`
// (recursively, for nested aggregates). Members inherited from a base class
// show up in every subclass; the merge below removes the duplicates.
void walk(alias Scope)() nothrow @nogc
{
    static foreach (name; __traits(allMembers, Scope))
    {{
        static if (__traits(compiles, __traits(getMember, Scope, name)))
        {
            alias S = __traits(getMember, Scope, name);
            static if (is(S == class) || is(S == struct) || is(S == union))
            {
                static if (__traits(compiles, __traits(parent, S))
                    && __traits(isSame, __traits(parent, S), Scope))
                    walk!S();
            }
            // Declared here: allMembers also lists selectively imported
            // symbols (e.g. libc's `stderr`), which are not dmd's to restore.
            else static if (!is(S) && __traits(compiles, isStaticVar!S)
                && isStaticVar!S && __traits(isSame, __traits(parent, S), Scope))
            {
                add(cast(const void*) &S, typeof(S).sizeof);
            }
        }
    }}
}

// Function-local statics (see `make check-statics`). Declared with the type's
// size only; the snapshot copies bytes.
mixin template Local(string mangled, size_t size)
{
    mixin("extern extern(C) __gshared pragma(mangle, \"" ~ mangled ~ "\") ubyte[" ~ size.stringof
        ~ "] local_" ~ mangled ~ ";");
}

enum string[2][] locals = [
    ["_D3dmd10dsymbolsem18loadCoreStdcConfigFZ16core_stdc_configCQCf7dmodule6Module", "8"],
    ["_D3dmd10dsymbolsem19runDeferredSemanticFZ6nestedi", "4"],
    ["_D3dmd10dsymbolsem22DsymbolSemanticVisitor5visitMRCQBx9dtemplate13TemplateMixinZ4nesti", "4"],
    ["_D3dmd10expression10IntegerExp10createBoolRbZ7trueExpCQCaQBzQBq", "8"],
    ["_D3dmd10expression10IntegerExp10createBoolRbZ8falseExpCQCbQCaQBr", "8"],
    ["_D3dmd10expression10IntegerExp__T7literalVii0ZQnRZ11theConstantCQCkQCjQCa", "8"],
    ["_D3dmd10expression10IntegerExp__T7literalVii1ZQnRZ11theConstantCQCkQCjQCa", "8"],
    ["_D3dmd10expression10IntegerExp__T7literalViN1ZQnRZ11theConstantCQCkQCjQCa", "8"],
    ["_D3dmd10identifier10Identifier17generateIdWithLocFNbAyaSQCc8location3LocxPvbZ8countersHSQDiQDhQCyQCpFNbQBzQBzxQBlbZ3Keyk", "8"],
    ["_D3dmd10identifier10Identifier9newSuffixFNbZ1im", "8"],
    ["_D3dmd11templatesem12trySemantic3FCQBh9dtemplate16TemplateInstancePSQCo6dscope5ScopeZ4nesti", "4"],
    ["_D3dmd11templatesem16tryExpandMembersFCQBl9dtemplate16TemplateInstancePSQCs6dscope5ScopeZ4nesti", "4"],
    ["_D3dmd13expressionsem25ExpressionSemanticVisitor5visitMRCQCd10expression7CallExpZ4nesti", "4"],
    ["_D3dmd5clone12buildXtoHashFCQBa7dstruct17StructDeclarationPSQCg6dscope5ScopeZ8tftohashCQDh5mtype12TypeFunction", "8"],
    ["_D3dmd6errors18colorHighlightCodeFNbKSQBk6common9outbuffer9OutBufferZ6nestedi", "4"],
    ["_D3dmd6traits13traitNotFoundFCQBc10expression9TraitsExpZ11initializedb", "1"],
    ["_D3dmd6traits13traitNotFoundFCQBc10expression9TraitsExpZ6identsG60PCQCo10identifier10Identifier", "480"],
    ["_D3dmd7arrayop7arrayOpFCQw10expression6BinExpPSQBt6dscope5ScopeZQByCQCo9dtemplate19TemplateDeclaration", "8"],
    ["_D3dmd7dmodule7Package6__ctorMFNbSQBg8location3LocCQBx10identifier10IdentifierZ10packageTagk", "4"],
    ["_D3dmd7funcsem23funcDeclarationSemanticFPSQBo6dscope5ScopeCQCf4func15FuncDeclarationZ11printedMainb", "1"],
    ["_D3dmd7funcsem8genCfuncFPSQy4root5array__T5ArrayTCQBw5mtype9ParameterZQBcCQCuQy4TypeCQDf10identifier10IdentifierEQEh8astenums3STCZ2stCQFc7dsymbol12DsymbolTable", "8"],
    ["_D3dmd7typesem12typeSemanticFCQBc5mtype4TypeSQBr8location3LocPSQCj6dscope5ScopeZ11visitAArrayMFCQDqQCo10TypeAArrayZ3feqCQEo4func15FuncDeclaration", "8"],
    ["_D3dmd7typesem12typeSemanticFCQBc5mtype4TypeSQBr8location3LocPSQCj6dscope5ScopeZ11visitAArrayMFCQDqQCo10TypeAArrayZ4fcmpCQEp4func15FuncDeclaration", "8"],
    ["_D3dmd7typesem12typeSemanticFCQBc5mtype4TypeSQBr8location3LocPSQCj6dscope5ScopeZ11visitAArrayMFCQDqQCo10TypeAArrayZ5fhashCQEq4func15FuncDeclaration", "8"],
    ["_D3dmd7typesem21getComplexLibraryTypeFSQBl8location3LocPSQCd6dscope5ScopeEQCu8astenums2TYZ12complex_realCQDz5mtype4Type", "8"],
    ["_D3dmd7typesem21getComplexLibraryTypeFSQBl8location3LocPSQCd6dscope5ScopeEQCu8astenums2TYZ13complex_floatCQEa5mtype4Type", "8"],
    ["_D3dmd7typesem21getComplexLibraryTypeFSQBl8location3LocPSQCd6dscope5ScopeEQCu8astenums2TYZ14complex_doubleCQEb5mtype4Type", "8"],
    ["_D3dmd7typesem6dotExpFCQv5mtype4TypePSQBk6dscope5ScopeCQCb10expression10ExpressionCQDd10identifier10IdentifierEQEfQDl10DotExpFlagZ8noMemberMFQEpQEeQDpQCqiZ4nesti", "4"],
    ["_D3dmd9semantic315search_toStringFCQBh7dstruct17StructDeclarationZ10tftostringCQCz5mtype12TypeFunction", "8"],
    ["_D3dmd7typesem9Type_initFZ7basetabPEQBi8astenums2TY", "8"],
    ["_D3dmd7globals6Global5_initMRNbZ4dateG12a", "12"],
    ["_D3dmd7globals6Global5_initMRNbZ4timeG9a", "9"],
    ["_D3dmd7globals6Global5_initMRNbZ9timestampG25a", "25"],
    ["_D3dmd4root4rmem13BumpPointerGC10initializeFZ3bufG40h", "40"],
    ["_D3dmd4root4rmem13BumpPointerGC6__ctorMFZ3bufG32h", "32"],
    // Not listed: `dmd.errors.printDiagnostic().old_loc` (its mangled name
    // embeds the platform's va_list type). It is written only on the stderr
    // printing path, which the diagnostic handler replaces.
];

static foreach (l; locals)
    mixin Local!(l[0], mixin(l[1]));

const(void[])[] collect() nothrow
{
    static foreach (M; dmdModules)
        walk!M();
    static foreach (l; locals)
        add(cast(const void*) &mixin("local_" ~ l[0]), mixin(l[1]));

    // Sort and merge overlapping/adjacent ranges.
    extern (C) static int cmp(scope const void* a, scope const void* b) nothrow @nogc
    {
        auto x = (cast(const R*) a).lo, y = (cast(const R*) b).lo;
        return x < y ? -1 : x > y ? 1 : 0;
    }

    qsort(gRanges, gCount, R.sizeof, &cmp);
    size_t k = 0;
    foreach (i; 0 .. gCount)
    {
        if (k && gRanges[i].lo <= gRanges[k - 1].hi)
        {
            if (gRanges[i].hi > gRanges[k - 1].hi)
                gRanges[k - 1].hi = gRanges[i].hi;
        }
        else
            gRanges[k++] = gRanges[i];
    }
    auto res = (cast(const(void[])*) malloc(k * (const(void[])).sizeof))[0 .. k];
    foreach (i; 0 .. k)
        (cast(const(void)[]*) res.ptr)[i] = (cast(const(void)*) gRanges[i].lo)[0 .. gRanges[i].hi - gRanges[i].lo];
    return res;
}

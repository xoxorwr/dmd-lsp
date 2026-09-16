# Findings: dmd session state, memory retention, and in-process reclamation

Engineering notes from making the dmd frontend work as a long-lived library
(an LSP daemon) that re-analyzes a changing file many times in one process.

Scope: why the naive "init once / reset between requests" approaches leak,
what the retention actually is, what we tried, what worked, and the current
recommendation.

## 1. The problem

`dmd.frontend` exposes `initDMD()` / `deinitializeDMD()` / `parseModule()`,
intended for one-shot compiler runs. A daemon wants a fresh semantic
universe per document change. Two obvious approaches both failed:

| Approach | Result |
|---|---|
| `deinitializeDMD()` + `initDMD()` per request (full reset) | **~117 MB leaked per rebuild** (three 380 KB files → 490 MB peak) |
| `initDMD()` once, re-parse the changed root in the live universe | dmd returns the stale module / collides on re-declared types |

The load-bearing fact: dmd is architecturally a singleton compiler whose
mutable state is process-global, and `deinitializeDMD()` is an **incomplete**
reset.

## 2. Diagnosis

Measurements used `GC.stats().usedSize` and `/usr/bin/time -v` `Maximum
resident set size`, on `compiler/src/dmd/dsymbolsem.d` (~380 KB, full
frontend closure).

### 2.1 GC is enabled and works

`-version=NoMain` excludes dmd's own `main`, which is where
`rt_options = [ "gcopt=disable:1" ]` and `mem.disableGC()` happen. Verified
with an in-process probe: a dropped 64 MB array is reclaimed on
`GC.collect()` (`before=549488 afterAlloc=67662448 afterNull=549488`).
So the leak is real retention, not a disabled collector.

### 2.2 The leak is per reset, and not a dmd global

Scanning every word of the executable's `.data`/`.bss` that points into the
GC heap, once after universe A and once after universe B (two different
files), the only constants were:

- `Identifier.stringtable` and the `Id::*` predefined identifiers.

`Identifier` is `const(char)[] name` + `TOK value` — it holds **no AST
references**, so it is not what keeps the module graph alive. TLS
(`&` a thread-local probe) held **0** stale roots. Disposing the analysis
thread did not free the universe either.

Conclusion: the dominant retention is **conservative-runtime** (stale
pointers in stack/registers that the conservative GC treats as roots) plus
the reset cycle itself — not a `__gshared` we can enumerate. That is why
"just complete `deinitializeDMD`" is not sufficient: the GC can root through
the stack regardless of how complete the global reset is.

## 3. A real upstream bug found: the identifier pool is never reset

`deinitializeDMD()` resets `Id`, `Type`, `Module`, `target`, `Expression`,
`Objc`, `Dsymbol`, `EscapeState`, `DFAAllocator` — but **not**
`Identifier.stringtable`. Identifiers (including `Identifier.generateId`
temporaries, whose counters also persist) accumulate forever in a
long-lived consumer.

Fix (implemented in `../dmd`, 3 files):

- `identifier.d`: `Identifier.deinitialize()` → `stringtable.reset(28_000)`.
- `tokens.d`: extract keyword registration from the `shared static this()`
  into `initializeKeywords()`; keep a static ctor that calls
  `Identifier.initTable(); initializeKeywords();`.
- `frontend.d` `deinitializeDMD()`: call `Identifier.deinitialize();
  initializeKeywords();`.

The keyword part matters: `Token`'s static ctor registers each keyword with
`Identifier.idPool(word, TOK)`, and the `TOK` value lives on the identifier.
Resetting the table without re-registering keywords makes the lexer lose
`import`, `struct`, etc. (observed as bogus "semicolon needed to end
declaration of `dmd` instead of `.`" errors).

Note: this fixes unbounded identifier growth, but it is *not* the AST leak
(batch RSS stayed ~490 MB for three files).

## 4. In-process re-analysis: init-once + eviction

Goal: keep one live universe for speed, and update only the changed root.

### 4.1 Init-once alone

`initDMD()` once; re-parse the root each request. Measured leak dropped from
~117 MB/request to **~3 MB/edit** — the reset cycle was the bulk of the
leak. Edits *are* picked up (`parseModule` builds a fresh `Module` object;
the stale-module behavior only applies to the `Module.load` path).

But re-parsing the same module name in a live universe collides:

- Without eviction: `module X from file ... is specified twice`.
- After evicting the root from `Module.modules`/`amodules`: `struct X
  already exists` (from `Type.merge` interning by mangled deco).
- After evicting the root's interned types too: `merge2` asserts.

### 4.2 Eviction that works for correctness

- Evict the root module: null its symtab entry (module or `package.d`
  wrapper) along its parent chain, and remove it from `amodules`.
- Evict types by the module's **mangled name token** (`module a.b` →
  `1a1b`): every deco of a type declared in the module contains that token,
  including types declared inside function bodies. Using the module token
  (rather than walking declared members) is what fixed the
  "class `dmd.dsymbolsem.X` already exists" errors for local/nested types.
- `merge2` fallback: if a `deco` is set but its table entry is gone, clear
  `deco` and re-`merge()` instead of `assert(0)`.

Result: **correct** re-analysis on `dsymbolsem.d` — error set matched the
baseline (the remaining `visit`/`-J` errors are pre-existing for that repo
source), with no spurious collisions.

### 4.3 Residual

Memory still grew **~4.3 MB/edit** even with correct eviction, and the
global scan again showed no dmd global holding it. That is consistent with
conservative stack/register retention of the old module. Under a
conservative GC, that cannot be removed by eviction.

Also: no amount of clearing accessible caches (`Dsymbol.deinitialize`,
`ClassDeclaration.object`, `Type.typeinfo*`, `Scope.freelist`, …) reduced it,
and some clears raised the error count (deps rely on `object`/`TypeInfo`).

## 5. Region GC (exact reclamation)

Idea: allocate each universe in a bump region and free it wholesale, so no
root scanning is involved — which sidesteps conservative retention entirely.

### 5.1 What worked

A custom GC (`core.gc.gcinterface.GC` subclass registered via
`core.gc.registry.registerGCFactory` and selected by setting
`core.gc.config.config.gc` in a `pragma(crt_constructor)`) with:

- three regions (permanent / universe / request),
- per-block header `{capacity, used, attr}`,
- `malloc/calloc/realloc/free`, and
- the druntime array-append protocol
  (`getArrayUsed`/`expandArrayUsed`/`reserveArrayCapacity`/`shrinkArrayUsed`).

In isolation and in **batch mode** (`--check`), this gave **flat in-process
memory**: analyzing 1, 2, 3, 4 large files all peaked at ~278 MB instead of
124 → 241 → 358 MB. Exact reclamation, no fork, no root scanning. But bump
allocation does not reuse within a universe, so the peak (~278 MB) is higher
than the conservative GC's live set (~125 MB).

### 5.2 What blocked it

Integrating with dmd + druntime requires a *complete* reset and a *fully
correct* GC contract, and every layer revealed the next:

1. `deinitializeDMD` + region free left `Identifier.stringtable` dangling
   (fixed by §3). Order matters: recreate the pool *after* the region reset,
   with `initTable()` (not `deinitialize()`, which calls `freeMem()` on
   already-freed pools).
2. Universe-holding globals must be nulled before the free or universe 2
   dereferences freed universe-1 memory (`setScope` on a
   `ConditionalDeclaration` crashed this way).
3. druntime's associative-array internals assert under the simplified GC
   (`core/internal/newaa.d` `assert(used >= deleted)`), i.e. the GC's block
   semantics do not match what AA requires.

That last one is the real blocker: a correct implementation must satisfy
druntime's full array **and** AA block contract, which is a proper GC port,
not a bump allocator with a header.

## 6. Current solution: warm worker + fork per root edit

Process isolation avoids the whole class of problems: the parent holds no
dmd state, and the OS reclaims a discarded universe wholesale. The worker
builds one universe (dependency closure + root) and keeps it warm. On a
**root-text-only** edit it forks a child over the warm universe: the child
evicts the previous root module and its interned types, re-analyzes only the
new root, answers and exits. The eviction leak (§4.3) and the mutations die
with the child; the warm universe is untouched. On any other invalidation
(dependency/config/root change) the worker replies `needRespawn` and is
replaced. Results crossing the boundary are plain data.

- Per-edit cost on the dmd frontend: ~420 ms full build → ~43 ms incremental
  re-analysis in-process (~110 ms once fork/COW and the completion work are
  included). The closure (`importAll` + `dsymbolSemantic` over ~200 modules,
  ~330 ms) is never re-run.
- Parent RSS flat; the worker keeps exactly one warm universe; children are
  short-lived (reaped by `waitpid`).
- Eviction works only because `removeWhere` keeps the string pools alive
  (§7 patch 4): `Type.deco` points into the pool, so rebuilding the strings
  would dangle every surviving type.
- Portability caveat: `fork`/`socketpair` are POSIX-only; WASM has no
  processes (its cheap isolation primitive is a fresh module instance).

## 7. Upstream patches in `../dmd`

1. `dsymbolsem.d`: null guard in `SearchVisitor::visit(Import)` — scope
   search over a failed import load dereferenced null `imp.mod`.
2. `frontend.d`: phobos-free rewrite (no `import std.*`; `ParsedModule`
   struct; `string[]` import paths). Consumer std closure 58 → ~13 modules.
3. `identifier.d` + `tokens.d` + `frontend.d`: reset the identifier pool in
   `deinitializeDMD` (§3).
4. `root/stringtable.d`: `removeWhere` — compact the hash slots of a
   `StringTable` without freeing its pools (a plain null-out would break
   quadratic probing; rebuilding the strings would dangle `Type.deco`, which
   points into the pool). Enables type eviction for incremental re-analysis.
5. `typesem.d`: `merge2` fallback — when a type still carries `deco` but its
   table entry was evicted, clear `deco` and `merge()` instead of `assert(0)`.

Until these land, `dmd-lsp` vendors the exact frontend closure under
`src/dmd/` (refresh with `make vendor`), so the shipped build is
self-contained and carries the patches. It is a snapshot, not a fork —
delete it and restore `-I../dmd/compiler/src` once upstream merges.

## 8. Recommendations

- **Keep dmd's semantic** (it is the product's value); treat the process /
  instance as the isolation boundary. Put it behind an `Analyzer` seam so a
  WASM fresh-instance backend can be added.
- **Submit patch 3** (identifier pool) regardless — it is correct and
  independent.
- If in-process is later required: the missing piece is a **druntime-
  conformant GC** (array + AA + block metadata), not merely completing
  `deinitializeDMD`. Treat it as a GC port with its own test suite.
- Incremental AST patching is not available: `Module.parse` caches by path,
  `Type.merge` interns by deco with no eviction, and template instances are
  cached. Eviction (§4.2) gets correctness but not reclamation under a
  conservative GC.

## 9. Semantic pitfalls when driving the frontend from an LSP

Working around broken buffers (the normal state while typing) surfaced
behaviour that any frontend-as-library consumer should know:

- **Gate semantic on import errors, not on `global.errors`.** The obvious
  `if (global.errors) return;` also trips on *parse* errors; stock dmd
  keeps going after them. The correct gate is "errors introduced by
  `importAll`". The reason a failed import must gate is that a scope
  search over a null `imp.mod` segfaults — fixed upstream by §7 patch 1.
- **Any statement error collapses the whole function body** to a single
  `ErrorStatement` (`visitCompound` propagates the failure up to
  `fbody`). Every local declared in that body disappears from the tree.
- **Inferred local types live in `semantic3`, which is also the phase that
  collapses.** `dsymbolSemantic` leaves `auto x = ...` with `vd.type`
  null; `semantic3` (function-body semantic) fills it. There is no
  intermediate tree that has both an intact body and resolved local
  types, so "snapshot after declaration semantic" does not help.
- The error-immune structure is therefore the **pre-semantic snapshot**
  (function ranges, local names, explicit type idents only). It cannot
  recover `auto` types.
- **Consequence for completion:** analyse a *neutralised variant* that
  makes the incomplete construct valid, and key the cached universe on the
  real document text. We use three neutralisations — dangling dot →
  `x.__dmd_lsp_ph()` plus an appended unconstrained UFCS template; a lone
  partial identifier → dropped; an unfinished call/array argument →
  the expression statement blanked to `;`. (The void-returning placeholder
  cannot be a call argument, hence the third case.)
- **Flags change semantics, not just codegen.** The analyser must mirror
  the project's build flags. `-preview=rvaluerefparam` is the sharpest:
  a library like `format(ref Writer, ...)` called with a temporary
  (`stream.writer()`) only resolves with it; without it overload
  resolution fails and cascades into `template instance ... error
  instantiating` at unrelated call sites.
- **`public import` re-exports** are part of an imported module's
  interface regardless of whether the *importing* statement is public;
  completion must follow them transitively (the visibility of the outer
  import only governs re-export to third modules).

## 10. LSP-side ownership footgun

Unrelated to dmd, but found while chasing a bogus
`... source file must start with BOM or ASCII character, not \xC8`: the
session's document buffer is malloc'd, and the "replace text" helper
freed the old buffer *before* copying the new text. On `didSave` without
a `text` field the new text *was* the old buffer, so the copy read freed
memory and handed dmd random heap bytes (hence a different `\xNN` each
run). Fix: copy before free, and never feed the session's own buffer back
through the replace path.

## Appendix: representative reset surface (frontend)

`deinitializeDMD` covers global counters, `Type`/`Id`/`Module`/`target`/
`Expression`/`Objc`/`Dsymbol`/`EscapeState`/`DFAAllocator`. It misses (or
missed) at least:

- `Identifier.stringtable` (fixed), `Identifier.generateId` counters.
- `Module.amodules` / `deferred{,2,3}` / `rootModule` / `moduleinfo`.
- `ClassDeclaration.object` / `throwable` / `exception` / `errorException` /
  `cpp_type_info_ptr`.
- `Type.dtypeinfo` / `typeinfo*` / `rtinfo` / `basic`.
- `TemplateValueParameter.edummies`, `TemplateStats.stats`.
- `Scope.freelist`, `StructDeclaration.xerreq` / `xerrcmp`.
- Function-local statics (not resettable from outside without refactor):
  `typesem` `feq`/`fcmp`/`fhash`/`complex_*`, `funcsem` `st`,
  `dsymbolsem` `tfgetmembers`/`core_stdc_config`, `clone.tftohash`,
  `arrayop.arrayOp`, `semantic3.tftostring`, `templatesem.emptyArrayElement`.

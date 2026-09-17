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

### 5.3 Prototype: region GC in-process (local, opt-in)

> Revived as `src/regiongc.d` (not part of the shipped build): a partitioned
> GC with a resettable arena for dmd allocations and a normal pool for
> druntime. With the reset fixes (patches 2 and 4, including
> `Package.packageTag`) it replays full universe rebuilds flat over 200 runs
> (arena ~162 MB, RSS ~276 MB, persistent flat). The measurements below are the
> earlier bump-only attempt and are kept for reference.

It was a non-collecting allocator: each block is an
individually `malloc`'d header+payload threaded onto a per-region list;
`regionFreeUniverse()` frees the universe region in one pass, ignoring roots.
Two regions (permanent / universe); `--check` opens a universe per file and
frees it after printing.

Two dead ends, measured:

- **Bump allocation**: dmd allocates ~GB of temporaries per file and relies on
  collection, so with no reuse the peak is the allocation volume — `dsymbolsem.d`
  hit **5.9 GB**.
- **`malloc`-per-block without the array protocol**: every `~=` reallocates
  (×1.8 because `expandArrayUsed` fails), so it also allocated **5.9 GB**.

The fix is druntime's **array-capacity protocol**: implement `getArrayUsed` /
`expandArrayUsed` / `reserveArrayCapacity` / `shrinkArrayUsed` with slack
allocation (`alloc` gives `APPENDABLE` blocks ~1.5× capacity) and used/capacity
in the header. That brought `dsymbolsem.d` to **157 MB allocated / 149 MB live**,
on par with the conservative GC (175 / 118 MB).

`--check` peak RSS on large dmd files:

| files | conservative | region |
|---|---|---|
| 4 | 634 MB | 390 MB |
| 8 | 1192 MB | 390 MB |

The region peak is flat in the file count (each universe reclaimed); the
conservative peak grows linearly. Region is also faster: 1.15 s vs 1.81 s for
four files.

Outstanding: the region path **crashes intermittently**, for the §5.2 reason —
frontend globals not reset by `deinitializeDMD` (function-local statics such as
`funcsem.st`, `dsymbolsem.tfgetmembers`, `typesem.feq/fcmp/fhash`,
`dsymbol.docUnittestHashTable`, `templatesem.emptyArrayElement`) hold universe
memory that the next file dereferences after the free. Closing that gap means a
`deinitialize` hook per offending module, called before `regionFreeUniverse()`.
The `DMD_LSP_REGION_GC` flag keeps the risk off the default build.

## 6. Current solution: warm worker (cross-platform)

The LSP front end holds only documents/config. Analysis runs in a worker
process (`worker.d`): POSIX `fork()`s the server; Windows spawns this
executable with `--worker`; either way it speaks length-prefixed frames over
pipes. The worker keeps one warm universe; on a **root-text-only** edit it
re-parses the root *in place* on the warm closure (`serverAnalyzeIncremental`
→ `dmdReparseModule`): it evicts the previous root module and its interned
types, then parses into the same `Module` so importers' `imp.mod` and
template-instance links stay valid. On any other invalidation
(dependency/config/root change) it replies `needRespawn`; the parent replaces
it and the OS reclaims the discarded universe.

- Per-edit cost on the dmd frontend: ~420 ms full build → ~43 ms incremental
  re-analysis (~110 ms including the completion work). The closure
  (`importAll` + `dsymbolSemantic` over ~200 modules, ~330 ms) is never
  re-run.
- Parent RSS is flat (one warm universe held by the child).
- Eviction works only because `removeWhere` keeps the string pools alive
  (§7 patch): `Type.deco` points into the pool, so rebuilding the strings
  would dangle every surviving type.

**Why not in-process (kept as a future path).** Process isolation is the
reclamation boundary: the conservative GC cannot prove a discarded universe
unreachable in-process, so distinct roots retain ~one universe each.
`Mem.enableZero()` (§7 patch) fixes the worst case (uninitialized `xmalloc`
words acting as false roots), but stale stack/register roots remain, so an
in-process host still grows with distinct roots and doesn't return pools.

## 7. Upstream patches in `../dmd`

Branch `lsp-fixes` (on top of upstream `master`); details in
[upstream.md](upstream.md):

1. `frontend.d`: drop the phobos dependency.
2. `deinitialize()` hooks across the frontend modules, plus
   `Loc.checkpoint/rollback`, `StringTable.removeWhere`, and
   `Identifier`/`dinterpret` `reinitAfterRegion`.
3. `root/scratch.d` + `common/outbuffer.d`: scratch allocator for transient
   `OutBuffer` stores (behind `version (DMDLIB)`).
4. `root/rmem.d` arena option, plus reset `Package.packageTag`,
   `IntegerExp` caches and `Type.typeinfoconst`.

The null-`imp.mod` guard is **already upstream** (PR #23843). Module
replacement and type eviction are consumer-side (`src/dmdwrap.d`).

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

## 11. Follow-up (measured): why a finite reset list cannot stop the leak

After the process-isolated design landed, the in-process incremental path (evict
the root module + its types, re-parse only the root) was re-measured to
decide whether `fork` could be dropped for a single portable model. It
cannot.

### 11.1 In-process incremental leak

Fixture: `compiler/src/dmd/expressionsem.d` (20k lines), a self-contained
4k-line / 2k-declaration module, and the same with the file unimported by
its deps (acyclic). Per edit: `dmdEvictRoot` + `dmdParseOnly` +
`dmdSemantic`, `GC.collect()` after each.

| root | full build | incremental | leak |
|---|---|---|---|
| `expressionsem.d` | 419 ms | 44–46 ms | +7.9 MB/edit (GC-live), ~8% reclaimable |
| 2k-decl synthetic | 55 ms | 46 ms | +16 MB/edit |
| 4k-decl acyclic synthetic | 54 ms | — | +24 MB/edit (so: not the import cycle) |

Growth is proportional to the root's GC footprint (~8 MB per 1000
declarations in the synthetic): the *entire* previous root is retained each
edit.

### 11.2 GC options do not help

- `gc:precise` is the **same** `ConservativeGC` with `isPrecise = true`; it
  needs compiler-emitted pointer bitmaps for stack ranges
  (`ScanRange!true.pbase/ptrbmp`) and dmd does not emit them, so it still
  scans conservatively. Measured identical leak. (`gc:manual` is
  malloc/no-collect; `minPoolSize`/`maxPoolSize`/`incPoolSize`/
  `heapSizeFactor` tune retention, not reachability.)
- Overwriting reused stack with a large local buffer before collecting
  changed the leak by **zero bytes**.
- Running the re-analysis on a fresh thread (so its stack/registers die)
  makes dmd's parse fail on the spawned thread (`module_ == null`,
  `global.path` still populated) — not a usable isolation primitive.

### 11.3 Reverse-pointer tracing

A conservative reachability tracer (forward from the executable's writable
data with `GC.addrOf`/`GC.query`, backward from the module) found chains
ending at `Module.deferred2`, `Module.amodules`, `Module.modules`,
`Module.moduleinfo`, `global.path` and `location.locFileTable`. Two real
frontend bugs surfaced:

- `root/stringtable.d` `removeWhere` dropped the hash slot but left the
  removed `Value` in the pool. Pools are GC memory and are scanned, so the
  value stayed rooted; it is now cleared on removal.
- `root/array.d` `Array.remove` (and `setDim` shrink) only decrement
  `length`; the vacated slot still holds the removed element, and with GC
  enabled `mem.xmalloc` is `GC.malloc`, so the backing is GC-scanned. This
  is a general "removed element stays reachable" bug, though only a minor
  contributor to this leak.

### 11.4 Is it a bug in the GC? No.

A minimal druntime reproducer (no dmd) rules that out:

- a 200k-node cyclic ring (29 MB) is fully reclaimed by `GC.collect()` after
  the head is dropped (delta 12 KB);
- 20 rounds of a 50k-node "central object + nodes pointing at it" graph
  plateau at a one-time ~2.8 MB residual (the first round's frame/register
  residue), i.e. every round is reclaimed, nothing accumulates.

So the collector correctly frees unreachable cyclic and repeated graphs; the
dmd retention is **roots**, not a sweep bug.

### 11.5 The real wall: you cannot drop the last reference under a conservative GC

Isolating those roots is itself defeated by the semantics: to test whether the
old universe is reclaimable you must not hold its address, but *any* copy of
the address (a pointer, an integer, a `size_t` local, even the tracer's own
working set) is a conservative root. Storing the address only in `malloc`
memory, nulling `Module.moduleinfo`/`rootModule`/`modules`/`amodules`, running
`Loc._init()`, dropping `global.path`, clearing the `deferred` queues and
`Type.stringtable`, nulling the `ParseOut`, and scrubbing the stack still
leaves the block live; a conservative reachability tracer over the
executable's writable data then finds **no** static root reaching it.

That is the conclusion the measurements support: under a conservative collector
there is always a stack/register/residual root you cannot enumerate or clear,
so a long-lived process cannot deterministically supersede a universe. It is
inherent to conservative collection, not a bug, and no reset list fixes it.
Exact reclamation is the only way:

- process teardown, or
- a druntime-conformant region/arena GC (§5), which frees a universe wholesale
  without scanning roots, or
- a precise GC with compiler-emitted root maps (a compiler change).

The two frontend bugs above (`Array` vacated slots, `stringtable` pool values)
are worth fixing on their own merits, but neither changes this conclusion.

### 11.6 Correction: the residual is a real reference (the module's imports)

A later, bounded reverse-reference scan changes the §11.5 conclusion. Scanning
writable memory for the evicted module's address and resolving each referrer's
vtable with `dladdr` shows the retainers are `dmd.dimport.Import` objects, each
holding the old module in `imp.mod` — the closure's `import <root>` links,
including local imports inside function bodies. So the residual growth is a
**real reference**, not conservative stack/register noise (a fresh-thread run
of the same loop gives identical numbers).

Attacking it directly: nulling `imp.mod` crashes the next analysis (the import
is dereferenced), and swapping in the new module aborts in
`templatesem.appendToModuleMember`. What works is to re-parse into the *same*
`Module` object (identity preserved, so every `imp.mod` stays valid). On
`expressionsem.d`:

| model | leak/edit | time/edit |
|---|---|---|
| full `dmdResetRequest` | ~104 MB | 497 ms |
| evict + fresh `Module` | ~7.5 MB | 94 ms |
| re-parse in place | ~2.6 MB | 46 ms |

A residual ~2.6 MB/edit remains from a member reference held by the `Module`
itself; see upstream.md patch 6.

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

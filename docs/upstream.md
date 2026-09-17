# Upstream work & roadmap

## Patches in `../dmd`

These changes live in the `../dmd` dev tree and are copied verbatim into
`src/dmd/` by `make vendor` — see [vendoring.md](vendoring.md). The numbering
matches [findings.md](findings.md) §7 so cross-references stay stable. Each is
meant to be submitted upstream on its own; the *Review notes* record what a
maintainer is likely to ask.

They exist because the consumer is a **frontend-as-library**: the LSP daemon
never calls dmd's `main`, keeps the frontend alive across many documents and
edits, and deliberately continues analysing broken code. The CLI does none of
those, which is why several of these bugs are unreachable in stock dmd.

### The series (branch `lsp-fixes`, on top of master)

| # | Commit subject | Files | Purpose |
|---|----------------|-------|---------|
| 1 | `Remove dependency on phobos` | `frontend.d` | let library consumers link without phobos |
| 2 | `Add the mechanism to reset frontend state between analyses` | `frontend.d`, `funcsem`/`dsymbolsem`/`typesem`/`semantic3`/`templatesem`/`dtemplate`/`clone`/`arrayop`/`dinterpret`.d, `location.d`, `root/stringtable.d`, `identifier.d`, `tokens.d` | `deinitialize()` hooks, `Loc.checkpoint/rollback`, `StringTable.removeWhere`, `reinitAfterRegion` |
| 3 | `Add scratch allocator so non gc tracked leaks can be cleared between runs` | `root/scratch.d` (new), `common/outbuffer.d` | reclaim transient `OutBuffer` stores (behind `version (DMDLIB)`) |
| 4 | `Add arena support and reset state that leaked between sessions` | `dmodule.d`, `expression.d`, `mtype.d`, `root/rmem.d`, `root/scratch.d` | `mem` arena option for wholesale reclamation; reset `Package.packageTag`, `IntegerExp` caches, `Type.typeinfoconst` |
| 5 | `Add an option to zero dmd's scanned allocations` | `root/rmem.d` | `Mem.enableZero()` makes `xmalloc` return zeroed memory so the conservative GC has no garbage roots retaining a discarded universe |

Notes:

- The null-`imp.mod` guard discussed below is **already upstream** (PR
  #23843); it is no longer part of this series.
- Module replacement / root eviction (`dmdReparseModule`, `dmdEvictRoot`) is
  **consumer-side** (`src/dmdwrap.d`), built on patch 2's `Loc.checkpoint`,
  `StringTable.removeWhere` and the `deinitialize()` hooks. It is not a dmd
  patch itself.
- The detailed sections below are the original write-ups and keep their old
  numbering; use the table above for the reviewed set.

### 1. `dsymbolsem.d` — don't deref a null `imp.mod` in scope search

**Symbols**: `SearchVisitor.visit(Import)` (`compiler/src/dmd/dsymbolsem.d`).

**Problem**: resolving a name through an `Import` calls `load` and then
unconditionally dereferences `imp.mod`:

```d
if (!imp.pkg)
{
    imp.load(null);
    imp.mod.importAll(null);        // imp.mod is null if the load failed
    imp.mod.dsymbolSemantic(null);
}
```

`load` returns non-zero when the import cannot be loaded (missing file, failed
parse), so `imp.mod` stays null and the dereference segfaults.

**Fix**: check `load`'s result, propagate the failure onto the module, and end
the search instead of continuing:

```d
if (imp.load(null))
{
    if (imp.mod)
        imp.mod.errors = true;
    return setResult(null);
}
if (!imp.mod)
    return setResult(null); // Failed
```

`setResult(null)` reports "name not found"; `imp.mod.errors = true` marks the
module failed for later passes.

**Why stock dmd doesn't hit it**: the CLI gates semantic on import-load errors
(`if (global.errors) return;`), so by the time scope search runs every import
has loaded or compilation has stopped. This consumer skips that gate on purpose
(an editor must keep answering while the file is broken), which is what makes
the null reachable.

**Review notes**: confirm `load` returns "true on failure" and that
`setResult(null)` (rather than an empty result) is the right not-found signal;
the `imp.mod.errors` write matters for downstream gating.

### 2. `frontend.d` — phobos-free `dmd.frontend`

**Symbols**: config discovery, `parseModule`, `initDMD`/`deinitializeDMD`
(`compiler/src/dmd/frontend.d`).

**Problem**: `dmd.frontend` is the library entry point, and it imported
`std.path`, `std.file`, `std.process`, `std.string`, `std.array` (and
`std.algorithm`). A consumer that links `dmd.frontend` therefore links the whole
std/phobos closure it drags in (~58 modules) even though it never uses phobos.

**Fix**:

- `parseModule` returns a small `struct ParsedModule { Module module_;
  Diagnostics diagnostics; }` instead of `Tuple!(Module, "module_",
  Diagnostics, "diagnostics")`; member names are unchanged, but `std.typecons`
  is no longer needed.
- Config discovery (`.dmd.conf` / `ldc2.conf` lookup, `$DMD`/`$LDC`, `%`
  variable expansion) is reimplemented on `dmd.root` + `core.stdc`, with small
  private helpers added at the end of the file: `isPathSep`, `dirNameOf`,
  `replaceAll`, `normalizeImportPath`, `expandConfigVariables`, `sortDedup`,
  `endsWithAny`, `readFileBytes`, `currentDir`, `getenvOr` (each with a
  unittest).
- Import-path parameters become `string[]` instead of lazy ranges, dropping the
  `std.range`/`std.algorithm` dependency.

**Result** (measured when the patch was written): consumer standard-library
closure 58 → ~13 modules, no source-level `std.` importer left; binary −19%.

**Intentional API deltas**: `Tuple` → struct; lazy ranges → `string[]`. Callers
keep reading `.module_` / `.diagnostics`; anything that passed a range must now
materialise it.

**Review notes**: upstream uses phobos freely and may judge the duplicated
path/file helpers as a maintenance cost. Frame it as opt-in for the `frontend`
dub package (or gate the helpers behind a version) and point at the unittests.
Windows is covered by the nightly CI (see releases.md).

### 3. `identifier.d` + `tokens.d` + `frontend.d` — reset the identifier pool

**Symbols**: `Identifier.deinitialize` (`identifier.d`), `initializeKeywords`
(`tokens.d`), `deinitializeDMD` (`frontend.d`).

**Problem**: `Identifier.stringtable` is process-global and `deinitializeDMD`
never reset it, so a frontend-as-library consumer accumulates every identifier
ever interned (and the `Identifier.generateId` counters) for the life of the
process — unbounded growth in a long-lived daemon.

**Fix**:

- `identifier.d`: add `static void deinitialize() nothrow
  { stringtable.reset(28_000); }`, mirroring `Type.deinitialize`.
- `tokens.d`: move keyword registration out of `shared static this()` into
  `extern (D) static void initializeKeywords()`; the static ctor now calls
  `Identifier.initTable(); initializeKeywords();`.
- `frontend.d`: `deinitializeDMD` calls `Identifier.deinitialize();
  initializeKeywords();`.

**Why the keyword half is required**: each keyword is interned with
`Identifier.idPool(word, TOK)`, and the `TOK` value lives on the identifier.
Resetting the table without re-registering keywords makes the lexer forget
`import`, `struct`, … — observed as `semicolon needed to end declaration of
'dmd' instead of '.'`.

**Review notes**: `reset(28_000)` is a capacity hint matching `initTable`'s
default; the name parallels the other `*.deinitialize` resets. Confirm the
reset-then-re-register ordering, or whether upstream would rather have
`deinitializeDMD` call `initTable()` itself.

**dmd-lsp relevance**: findings.md §3.

### 4. `root/stringtable.d` — `removeWhere` (pool-preserving delete)

**Symbols**: `StringTable.removeWhere` (`compiler/src/dmd/root/stringtable.d`).

**Problem**: a consumer that needs to drop entries from a `StringTable` (to
evict a module's interned types before re-analysing it) has no delete. A plain
"clear the slot" is wrong: the table is open-addressed with quadratic probing
and `findSlot` stops at the first empty slot, so clearing a slot in the middle
makes every later colliding key unreachable.

**Fix**: `size_t removeWhere(bool delegate(const(StringValue!T)*) pred)`
rebuilds the hash array, re-probing survivors into a fresh `StringEntry[]` and
dropping the matches. It deliberately **does not free the pools**: a stored
value may cache a pointer into its string (`Type.deco` points at
`StringValue.toDchars`), so freeing or moving the strings would dangle every
surviving type's `deco`. Returns the number of entries removed.

**Review notes**: the pool-retention contract is the subtle part (stated in the
doc comment). `nothrow`; allocates with `mem.xcalloc_noscan` to match `grow()`.
Upstream may prefer a tombstone or an `apply`-that-can-remove; the pool caveat
applies to any design.

**dmd-lsp relevance**: root eviction for incremental re-analysis — findings.md
§4.2, §6.

### 5. `typesem.d` — `merge2` fallback when the entry was evicted

**Symbols**: `merge2` (`compiler/src/dmd/typesem.d`).

**Problem**: `merge2` looks a type's `deco` up in `Type.stringtable` and
`assert(0)`s when the type still carries a `deco` but the table has no entry.
Stock dmd can never reach that combination (nothing removes entries), but a
consumer using patch 4 can, and an assert is a hard abort.

**Fix**: on a miss, clear the cached `deco` and re-run `merge()` — which is a
no-op while `deco` is set, hence the clear — so the type is re-mangled and
re-inserted:

```d
t.deco = null;
return t.merge();
```

**Review notes**: unreachable upstream today; it is defensive for library
consumers that evict. A maintainer may want it behind an explicit API rather
than relaxing the invariant. The added `return t;` in the hit branch is a
reshape with no behaviour change.

**dmd-lsp relevance**: findings.md §4.2, §6 (eviction).

### 6. `dmodule.d` — re-parse a module in place (module replacement)

**Symbols**: `Module.parseModule` (`compiler/src/dmd/dmodule.d`); consumer
helper `dmdReparseModule` (`src/dmdwrap.d`).

**Problem**: a frontend-as-library consumer that re-analyses one module in a
live universe cannot parse a fresh `Module`: the closure's `import <root>`
symbols (`Import.mod`) keep pointing at the old `Module`, so the whole old
universe stays reachable and can never be reclaimed. Measured with a
reference scan after evicting the root: the referrers are `dmd.dimport.Import`
objects (including local imports inside function bodies), each holding the old
module in `imp.mod`. Nulling `imp.mod` crashes the next analysis (the import is
dereferenced), and swapping it to the new module aborts in
`templatesem.appendToModuleMember` — dmd's module/template-instance bookkeeping
does not survive a pointer swap.

**Fix**: don't create a new `Module`. Re-parse into the *same* object: evict the
module and its interned types (patches 4–5), then set `Module.src` and call
`Module.parseModule` again — it parses fresh members and re-inserts the same
object into the package symtab. Object identity is preserved, so `imp.mod` and
every template-instance link stay valid; the previous members are replaced and
become collectable.

```d
// src/dmdwrap.d, dmdReparseModule()
auto m = cast(Module) modp;
dmdEvictRoot(modp);            // registry entry + interned types
m.symtab = new DsymbolTable(); // drop references to the previous members
m.src = cast(const(ubyte)[]) (text.dup ~ '\0');
return cast(void*) m.parseModule!ASTCodegen();
```

**Measured** (`expressionsem.d`, 20k lines, warm closure, `GC.collect()`/edit):

| model | leak/edit | time/edit |
|---|---|---|
| full `dmdResetRequest` (today) | ~104 MB | 497 ms |
| evict + fresh `Module` | ~7.5 MB | 94 ms |
| **re-parse in place** | **~2.6 MB** | **46 ms** |

### 6a. What in-place re-parse requires (corrections)

Getting this correct and stable needed more than swapping the module pointer:

- **`Module.symtab` must be set to `null`**, not to a fresh `DsymbolTable`.
  Pre-installing an empty table stops dmd populating the module scope (the
  scope is only built when `symtab` is null), which breaks forward lookup of
  free templates (`cfg.helper()` → "no property `helper` for `cfg`").
- **Reset the semantic state** (`semanticRun = PASS.initial`, `_scope = null`,
  `aimports = .init`, `errors = 0`) or `visit(Module)` short-circuits and the
  re-parse is never analysed.
- **Clear the symbol-bearing fields** the previous semantic filled:
  `members`, `symtab`, `importedScopes` (imported modules + template mixins),
  `userAttribDecl`, `decldefs`, `tagSymTab`, `contentImportedFiles`,
  `searchCacheIdent/Symbol/Flags`, `Package.mod`.
- **Do not call `Loc._init()` mid-universe** — it corrupts locations of live
  definitions (broke goto-definition). Call it only as part of a real
  `initDMD`.
- **Reset the frontend caches** the previous analysis filled, without touching
  the live closure: `Module.{deferred,deferred2,deferred3}`, `Scope.freelist`,
  and every module-scoped cache that has a `deinitialize()` (`funcsem`,
  `dsymbolsem`, `typesem`, `semantic3`, `templatesem`, `dtemplate`, `clone`,
  `arrayop`). `Type.stringtable` is *not* cleared here (re-initialising the
  basic `Type` singletons breaks identity against the closure);
  `dmdEvictRoot` handles the module-specific entries.
- **CTFE caches declarations**: `ctfeGlobals.stack.globalValues` caches every
  evaluated global constant, keyed by the declaration's `ctfeAdrOnStack`, and
  keeps the declaration (and its module) alive. Added
  `dmd.dinterpret.deinitialize()` (tracks the saved `VarDeclaration`s, resets
  their `ctfeAdrOnStack` to `AdrOnStackNone`, clears `globalValues`), called
  from `deinitializeDMD`.
- **`Array.pop()` left the vacated slot populated** (the release path just
  `data[--length]`), so the GC-scanned backing store kept dead elements alive.
  Same class as the `remove`/`setDim` fixes; now cleared.
- **`locFileTable` (`dmd.location`) leaks a file copy per parse.** The lexer
  calls `newBaseLoc` for every parse, appending a `BaseLoc` that holds the
  *entire file contents* plus its line index, and advances the global
  `locIndex` forever. Long-lived consumers need an explicit checkpoint:
  `Loc.checkpoint()` / `Loc.rollback()` were added; the consumer records one
  after the initial full build and rolls back before each incremental
  re-parse. This cut measured RSS growth by ~15%.
- **Do not clear `TemplateDeclaration.instances`.** An earlier version of this
  patch walked all live declarations and nulled their instance tables. A/B
  measurement showed that is actively harmful: it forces full
  re-instantiation on every edit (more allocation, not less) and breaks
  semantic analysis (the incremental re-parse went from 5 to 25 errors on
  `expressionsem.d`). It was removed.

**Measured with semantic actually running** (`make check` green, 13/13):
re-parse-in-place is ~33 ms/edit on a 20k-line file (vs ~497 ms full reset),
and TS growth dropped from ~104 MB/edit (full reset) to ~6 MB/edit.

**Residual and how to measure it**: a real ~5 MB/edit RSS growth remains. Two
measurement traps were found the hard way:

- `GC.stats.usedSize` is **not live bytes** — freeing an 80 MB array and
  collecting leaves it unchanged (it counts committed pools). Growth must be
  measured by RSS, or by a reachability census.
- A conservative pointer scan over the heap is polluted by GC address reuse
  (freed blocks are not zeroed) and by uninitialized `Array` capacity. It
  produced false "retainers".

The reliable tool is an **RTTI census**: walk GC blocks, classify each by
resolving its vtable to a `TypeInfo` name, and count only blocks marked
reachable by a BFS from roots. Over 10 edits on `expressionsem.d`:

```
AST-ish (Exp*)      934975 -> 1166097   (+23112/edit)
FuncDeclaration      18949 ->   20384   (+143/edit)
TemplateInstance      5566 ->    8850   (+328/edit)
TemplateDeclaration   1659 ->    1690   (+3/edit)      <- flat
ScopeDsymbol          3734 ->   13487   (+975/edit)
```

**Source identified.** Per-module attribution shows the growth roots at the
*dependency* modules `dmd.arraytypes` and `dmd.traits` (not the root): their
cached template instantiations (`Array!(...)`, `__traits` helpers) hold the
instantiated bodies, i.e. the growing expressions/scopes/functions. The cause
is structural: re-parsing the root allocates **fresh symbols**, so a template
instantiation whose arguments mention them can no longer be de-duplicated
(`TemplateInstanceBox` compares the arguments) and a new instance — with a full
copy of its instantiated body — is cached on the owning declaration each edit.
`TemplateDeclaration` count is flat, so the instances accumulate *inside*
existing declarations, not as new declarations.

What does **not** fix it (all measured):
- clearing `TemplateDeclaration.instances` on live modules — forces full
  re-instantiation every edit (5× more AST churn: 165k vs 34k per module) and
  breaks semantic analysis;
- evicting `TypeInstance` entries from `Type.stringtable` — no change;
- keeping the interned types (no eviction) so instances can dedupe — only a
  small drop and it breaks completion;
- `GC.minimize()` / `GC.collect()` — no change (live data, not fragmentation);
- full `dmdResetRequest` per edit — 120 MB/edit, far worse.

**Scoped splice-reuse prototype (falsified).** The obvious cheap fix is to
keep symbol identity for *unchanged* top-level declarations: before re-parsing,
hash each member's source slice; after re-parsing, splice the old `Dsymbol`
back in where the slice is byte-identical, so instantiations that mention it
de-duplicate. Prototyped and measured:

- re-parsing **identical** text already leaks (+18.5k AST/edit), confirming the
  identity-churn mechanism independent of edits;
- splice reuses **226/227** top-level members (only `isBitField` re-parsed) and
  keeps completion working (reused imports must have `semanticRun`/`_scope`
  reset so they are re-imported; reused declarations must have their overload
  links cleared), **yet growth is unchanged** (+18.5k AST/edit);
- the only configuration that collapsed growth (+132/edit) was with imports
  left stale — i.e. incomplete semantics (completion returned empty). That was
  a false positive.

So preserving top-level symbol identity is **not sufficient**: the
instantiations are (re)created while the module passes run over dependencies /
instantiated bodies, not while the root's declarations are parsed. The scoped
splice does not fix the dedup misses.

**Dedup key analysis.** `TemplateInstanceBox` (the template-instance cache key)
`toHash`s `ti.enclosing` (pointer), `arrayObjectHash(ti.tdtypes)` and, for
`opEquals`, `equalsx` → `arrayObjectMatch` → `match`:

- `match` compares `Type` args with `Type.equals` (**structural**), but
  `arrayObjectHash` hashed `cast(size_t)t1.deco` — the deco **pointer**.
  Interned types normally share that pointer, so this usually holds; our
  evict+re-merge breaks interning and violates the "`equals` implies equal
  hash" contract. **Fixed** to hash the deco *content* (`calcHash(deco)`),
  both trees. Measured effect is small (+23k→+21.5k AST/edit), so Type-identity
  churn is not the dominant key.
- `match` compares `Dsymbol` args by identity (`equals` + `parent` pointer) and
  `arrayObjectHash` hashes `ident`/`parent` pointers — correct contract, but
  every re-parse gives fresh symbols, so any instantiation mentioning a root
  symbol is a new key. Top-level splice-reuse addressed exactly this and still
  did not reduce growth, which points at `ti.enclosing`: it is hashed/compared
  by **pointer** and is the enclosing `TemplateInstance`/scope, itself
  re-created by recursive re-instantiation each edit.

**Dedup-key probes.** Instrumented `findExistingInstance`/`addInstance`.
A first probe compared proposed instances against up to 64 arbitrary existing
ones and appeared to show dominant `Type`-argument differences — but sampling
the raw args showed `double` vs unrelated `float`/`real`, i.e. it was comparing
*different* instantiations. That conclusion was an artifact.

The decisive probe logs newly added instances per edit. The **exact same**
instantiations recur every edit:

```
edit 2: __lambda_L2555_C27!(Dsymbol)  __lambda_L3191_C40!(DtorDeclaration) ...
edit 3: __lambda_L2555_C27!(Dsymbol)  __lambda_L3191_C40!(DtorDeclaration) ...
```

Ruled out along the way (each with an apples-to-apples check — same printed
instance name, edit N vs N+1, **asserted equal before comparing**):
- **Counter drift falsified**: `Identifier.generateIdWithLoc` produced the same
  names each edit (`__lambda_L1241_C28`), only the `parent` pointer differed.
- **Blanket semantic reset falsified** (code read): `dmdReparseModule` resets
  only the *module's* `semanticRun`; members' is preserved and every pass
  guards on it (`semantic3.d:303` `>= PASS.semantic3`, `:1481`
  `= semantic3done`; pass1/pass2 likewise), so a reused declaration really is
  skipped.
- **`enclosing` falsified**: for the recurring instances it is `nil`. `parent`
  changes each edit but is not part of the box key.
- **Hash contract fixed** (`arrayObjectHash` now hashes `Type` deco *content*).

A promising lead was `RTInfo!(BitInfo)` (where `BitInfo` comes from the
`dmd.common.bitfields.generateBitFields` mixin), which appeared to be the same
instance re-added every edit. **But this was an artifact of ambiguous
`toChars()`**: keying by the full **deco** shows those are *different*
instantiations of `generateBitFields` for different structs
(`Expression`, `StructLiteralExp`, `SliceExp`, …), all of which render as
`BitInfo`. Grouping by deco and checking `Type.equals` across edits yielded
**zero** unequal-same-deco cases — i.e. identical instantiations compare equal,
so the "compare struct types by deco instead of `sym`" fix would change
nothing. That path is **falsified** (and the mixin is not the problem; removing
it would be invasive and would not address the mechanism).

Lesson for the remaining work: identify instances by **deco**, never by
`toChars()` (it is not unique). With deco-keyed grouping, the dedup misses seen
so far are accounted for by genuinely *different* instantiations (fresh
arguments per edit), not by a failed comparison of identical ones.

A further timing hypothesis — that an argument `Type.deco` is null/partial at
the moment the hash/lookup runs, so two later-identical instantiations are
inserted under different keys — was checked by logging `deco` on every argument
at lookup time: **null=0** across 3000+ lookups. Falsified too.

So the local/dedup-key hypotheses are exhausted: `Type` hash contract (fixed),
struct-equals-by-deco (falsified), generated-name drift (falsified), semantic
gating (correct), `enclosing` (nil), null/partial deco at insertion
(falsified).

**(i) sizing — argument-deco recurrence.** Keyed by (template declaration,
argument decos) across 10 edits, of 836 added instances: `novel=653`,
`recurPriorEdit=40` (~5%), `sameEdit=143`. So the accumulating instantiations
are **predominantly genuinely new argument content** each edit, not
failed comparisons of recurring ones — which closes the tension check (high
recurrence would have contradicted the falsifications; it is low). Identity
stability (i) would therefore have to cover nearly all instantiation inputs,
i.e. be broad; exact reclamation (ii) is the practical candidate. The
`sameEdit=143` is a caveat (possible within-edit miss or `toChars()`
key imprecision) that does not change the fork.

The remaining growth is therefore **genuinely new instantiations** whose
argument symbols/types are freshly parsed. That leaves the two structural
options: broad identity stability of instantiation inputs across edits, or
exact reclamation.

**(ii) viability check** (measured with the pinned dmd-2.113.0):
- The accumulators are reachable from a bounded global root set —
  `Module.amodules` dominates (≈170k AST blocks over 10 edits; ctfeGlobals
  ≈3k; locFileTable now 0 after the checkpoint fix). So a collector *could*
  enumerate them.
- But they are **live, intentionally cached**: held by
  `TemplateDeclaration.instances`, a **druntime AA**
  (`TemplateInstance[TemplateInstanceBox]`). They are not garbage, so no
  collector (conservative *or* precise) reclaims them without dropping the
  references.
- Dropping them directly (clearing instance tables every edit) is **worse**:
  RSS 181→425MB over 40 edits (≈6.3 MB/edit) vs baseline 181→376MB
  (≈5.0 MB/edit) — re-instantiation churn exceeds what it frees.
- A wholesale region/GC reset is gated by §5.2: druntime AA internals assert
  under a simplified allocator (`core/internal/newaa.d:272`
  `assert(used >= deleted)`), so a region must first satisfy the full
  druntime array **and** AA block contract — a proper GC port.

So (ii) is blocked twice over: the data is live-cached (no collector reclaims),
and the wholesale route needs a real GC port. Neither (i) (broad identity
stability) nor (ii) is a cheap fix; the in-process in-place re-parse remains the
best operating point unless true incremental analysis (stable identities for
all instantiation inputs) or a full druntime GC port is undertaken.

**Direct dmd instrumentation (the source, named).** Instrumenting
`addInstance` by *(instantiating module | template)* shows the accumulators are
**CTFE/helper templates declared in closure modules**, re-instantiated every
edit and cached on the closure declaration's `instances`:

```
148 bitfields|toString   122 expression|OpType   71 lifetime|hasIndirections
 65 expressionsem|_dnewclassT   26 arraytypes|Array   25 object|RTInfoU ...
```

Targeted fixes tried and their outcomes:
- generational eviction of un-used `instances` entries — only ~6% (bodies stay
  reachable via `tnext`/`inst`/`tinst`/`minst`);
- skip caching when the instantiating module is the re-parsed root — no effect
  (for CTFE helpers the instantiating scope's module is the helper's own
  module; the fresh part is the CTFE/`enclosing` context);
- null the body (`members`/`symtab`) and unlink chains on stale instances —
  **breaks semantics** and no memory win.

**Last loose end closed.** The recurrence probe's `sameEdit=143` (same
`(template, args)` key added twice in one edit) was chased: instrumenting
same-edit re-adds showed they divide into remove-then-re-add (legitimate) and
function-template instances (`toString(uint)`) with identical box hash and the
first entry *not* removed. That is `TemplateInstanceBox.opEquals`'s special
branch — when both instances have `inst` set it compares by pointer identity
(`ti is s.ti`) instead of `equalsx`. It is a within-edit quirk of dmd's
function-template caching, not a cross-edit identity bug, and does not change
the structural conclusion.

All of the above was re-measured with the pinned compiler `dmd-2.113.0`
(earlier runs had accidentally used the nightly `dmd` on `PATH`).

Making this flat needs **stable identity across edits** (true incremental
parsing, down through nested instances) or **exact reclamation** (precise GC
with root maps, or a region reset per whole-universe rebuild). Under a
conservative GC the in-place re-parse is still by far the best operating point
(≈5 MB/edit, 33 ms/edit) versus a full rebuild (≈120 MB/edit). `-profile=gc` cannot build dmd's own source
(`_darray*Trace` mixes in an undefined `TOK`), and `--DRT-gcopt=profile:1`
only reports collection timing in this druntime; RTTI is the usable tool.

**Review notes**: re-parsing an already-registered module works only because
the consumer evicted it first — otherwise dmd's "specified twice" check fires.
Recommend a supported `Module.reparse`/`replace` entry point that does the
eviction/re-registration *and* clears the member-referencing state, so consumers
do not reach into `Module.src`/`symtab`.

**dmd-lsp relevance**: findings.md §11; the in-process, fork-free re-analysis
path.

## Vendoring

Until these land, the repo [vendors](vendoring.md) the exact frontend closure
under `src/dmd/` so the shipped build is self-contained and carries the
patches. It is a snapshot, not a fork: `make vendor` re-copies it from
`../dmd` (branch `lsp-fixes`), so every patch above must be present in
`../dmd` first (the two trees are kept byte-identical for the vendored set).
The snapshot therefore tracks upstream `master` plus the four patches, and no
longer carries the old `fork` feature commits.

## What to do next

Ordered by value/effort:

1. **Finish module replacement (patch 6)**: identify and clear the `Module`
   field (offset 360) that still references the replaced member list, so a
   re-parsed root is fully reclaimable; then add a supported
   `Module.reparse`/`replace` API and wire it into the worker's in-process path
   (drop `fork`). This is the fork-free, cross-platform re-analysis path.
2. **Follow through upstream**: submit the four patches and handle review
   (likely questions: patch 1's `load`/`setResult` semantics; patch 2's
   `ParsedModule` vs `Tuple`, `string[]` vs ranges, duplicated path helpers and
   Windows branches; patch 3's reset ordering; patches 4–5's eviction-oriented
   API; patch 6's `reparse` surface vs reaching into `src`/`symtab`). See the
   *Review notes* above.
3. **Per-symbol selective-import pruning** (`import m : unused` quickfix) and
   **unused locals** via the snapshot walker (names already collected; needs
   def-use over the range).
4. **dub support**: derive import/string-import paths and `-version` flags
   from `dub describe`, and re-read them when `dub.json`/`dub.sdl` changes,
   so dub projects need no manual `dls.json`.
5. **UFCS candidates** for dot completion (the placeholder already proves the
   technique).
6. **Hit-path IPC trim**: send a content hash (or version) instead of the
   whole document to the worker when it already holds that universe.
7. Revisit remaining gaps only if they bite: unparseable-region fallback,
   `auto` condition-var dot types, Windows worker port (`threads` or
   `CreateProcess`).

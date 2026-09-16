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

| # | File(s) | Change | Needed for |
|---|---------|--------|------------|
| 1 | `dsymbolsem.d` | Null guard in the import scope search | Analysing after import errors |
| 2 | `frontend.d` | Phobos-free `dmd.frontend` | Library consumers without phobos |
| 3 | `identifier.d`, `tokens.d`, `frontend.d` | Reset the identifier pool in `deinitializeDMD` | Long-lived daemon memory |
| 4 | `root/stringtable.d` | `removeWhere` (pool-preserving delete) | Incremental root eviction |
| 5 | `typesem.d` | `merge2` fallback for an evicted entry | Incremental root eviction |

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
Windows branches cannot be CI-checked here.

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

## Vendoring

Until these land, the repo [vendors](vendoring.md) the exact frontend closure
under `src/dmd/` so the shipped build is self-contained and carries the
patches. It is a snapshot, not a fork: `make vendor` re-copies it from
`../dmd`, so every patch above must be present in `../dmd` first (the two
trees are kept byte-identical for the vendored set).

## What to do next

Ordered by value/effort:

1. **Follow through upstream**: submit the five patches and handle review
   (likely questions: patch 1's `load`/`setResult` semantics; patch 2's
   `ParsedModule` vs `Tuple`, `string[]` vs ranges, duplicated path helpers and
   Windows branches; patch 3's reset ordering; patches 4–5's eviction-oriented
   API). See the *Review notes* above.
2. **Per-symbol selective-import pruning** (`import m : unused` quickfix) and
   **unused locals** via the snapshot walker (names already collected; needs
   def-use over the range).
3. **dub support**: derive import/string-import paths and `-version` flags
   from `dub describe`, and re-read them when `dub.json`/`dub.sdl` changes,
   so dub projects need no manual `dls.json`.
4. **UFCS candidates** for dot completion (the placeholder already proves the
   technique).
5. **Hit-path IPC trim**: send a content hash (or version) instead of the
   whole document to the worker when it already holds that universe.
6. Revisit remaining gaps only if they bite: unparseable-region fallback,
   `auto` condition-var dot types, Windows worker port (`threads` or
   `CreateProcess`).

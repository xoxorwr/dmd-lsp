# Hacks on the vendored dmd

This file documents the edits we make **directly to the vendored frontend**
(`src/dmd/`) that are *not* candidate upstream patches. The upstream-bound
patches live in [upstream.md](upstream.md) (the `lsp-fixes` series); packaging
and the copy procedure live in [vendoring.md](vendoring.md).

Rule of thumb:

- If it is a real frontend fix that could be submitted to dmd as its own
  commit, it belongs in [upstream.md](upstream.md), on the `lsp-fixes` branch.
- If it exists only so a *language server* can work — a mode, a global, an
  escape hatch no compiler user would want — it belongs here.

`make vendor` overwrites `src/dmd/` from the branch, so **every hack here is
lost on refresh**. We accept that because losing one is loud, not silent:

- dmd-lsp imports the hack's frontend symbol, so dropping the patch is a
  **compile error**, not a behavior change;
- a regression test pins the behavior, so re-adding the patch but breaking the
  semantics is also caught by `make check`.

After a `make vendor` that drops a hack, re-apply it (and fix the doc/tests if
the frontend moved under it).

---

## H1. `lspNoManifestExpand` — keep manifest constants in the AST

**Files**: `src/dmd/optimize.d`, `src/dmd/initsem.d`
**Consumer**: `src/worker.d` (`computeRefs`)
**Tests**: `tests/test_references.py` (`enum-compound-member-refs`,
`enum-compound-type-refs`, `const-manifest-refs`), `tests/test_rename.py`
(`rename-enum-compound-member`)
**Status**: not upstreamable.

### Problem

dmd substitutes **manifest constants** with their value during semantic:

- function bodies: `dmd.optimize.fromConstInitializer` → `expandVar` replaces a
  `VarExp` that refers to a literal-valued `enum`/`const`/`immutable` with the
  literal (`src/dmd/optimize.d`); note `e.loc = e1.loc`, so the folded value
  keeps the *use* location;
- initializers: `ExpInitializer.initializerSemantic` runs `INITinterpret`
  (`src/dmd/initsem.d`), whose `ctfeInterpret()` folds the same constants, so
  module-level `Test t = Test.A;` is folded even though `fromConstInitializer`
  would have stopped.

A `VarExp` to an `EnumMember` is what gives references and rename their
identity. Once folded, the member link is gone and one `IntegerExp` can stand
for several accesses (`Test.A + Test.B`), so:

- `Test.A` uses are simply not found;
- rename renames the declaration and *some* uses and silently leaves the
  compound ones — a broken rename.

Simple accesses (`Test.A` alone) are additionally recovered from the folded
`IntegerExp` in `src/references.d` (`emitEnumAccess`), but that cannot recover a
compound expression whose result type is no longer the enum, nor the general
`const` case.

### Hack

A process-global `__gshared bool lspNoManifestExpand` in `dmd.optimize`
(default `false`):

- `fromConstInitializer` returns the expression unchanged when it is set;
- `initsem.d`'s `visitExp` downgrades `needInterpret` from `INITinterpret` to
  `INITnointerpret` when it is set, so initializers are not CTFE-folded either.

`src/worker.d` sets it **only around the per-candidate analyses** in
`computeRefs` and resets it with `scope (exit)`, so diagnostics, completion,
hover and lint keep the normal folded AST. It also sets `s.uni.valid = false`
first, so the request module is re-analysed unfolded instead of being served
from the warm (folded) universe cache.

```d
// src/worker.d (computeRefs)
import dmd.optimize : lspNoManifestExpand;
lspNoManifestExpand = true;
s.uni.valid = false;
scope (exit) lspNoManifestExpand = false;
```

### Why it is a hack

It is a mutable global in the compiler that makes semantic produce a
deliberately non-standard AST, toggled by the consumer. No compiler build
wants this; upstream would reject it. It is the price of doing semantic-only
references without a parse-time fallback.

### Cost

Measured on a fold-heavy 60k-line module (60k functions, 6 manifest references
each), 5 runs each, via `./dmd-lsp --check`:

| build | mean |
|---|---|
| no flag (baseline) | 1.662 s |
| flag present, false | 1.648 s |
| flag **enabled** | 1.644 s |

The added branch is one always-false, well-predicted `__gshared` read in
`fromConstInitializer`; the difference is run noise.

### Keeping it honest

`src/worker.d` imports `dmd.optimize : lspNoManifestExpand` on purpose: if a
`make vendor` drops the frontend half, the build fails here. If the frontend
half survives but stops doing its job, `enum-compound-*` and
`const-manifest-refs` fail. Both are required before merging a vendor refresh.

---

## H2. `BaseClass.loc` — keep base-clause locations

**Files**: `src/dmd/dclass.d` (field), `src/dmd/dsymbolsem.d` (capture)
**Consumer**: `src/references.d` (`RefWalker.baseUses`)
**Tests**: `tests/test_references.py` (`typehierarchy-base-list`)
**Status**: not upstreamable.

### Problem

`semanticBaseClasses` resolves each base-clause type in place:

```d
b.type = resolveBase(b.type.typeSemantic(cldec.loc, sc));
```

Before that line, `b.type` is the parsed `TypeIdentifier`/`TypeInstance`, whose
`Loc` is the base-clause usage. After it, `b.type` is a symbolic `TypeClass`
with no location, so the only record of *where* the base clause is written is
gone. A language server then cannot resolve a cursor on `class C : Base` or
`class C : Read!(T)` — which is exactly where "go to definition", "show type
hierarchy" and rename are invoked.

### What it does

Adds `Loc loc` to `BaseClass` and fills it in `semanticBaseClasses` (class and
interface paths) from `b.type` before the type is overwritten. `RefWalker`
emits an occurrence at `bc.loc` for each base, so base clauses participate in
references, rename, `typeDefinition`, `implementation` and type hierarchy.

### Keeping it honest

`src/references.d` reads `BaseClass.loc`, so a `make vendor` that drops the
field is a **compile error**. `typehierarchy-base-list` fails if the field
survives but stops being filled.

---

## H3. `parseModule(registerModule)` — parse without registering

**Files**: `src/dmd/dmodule.d` (`Module.parseModule`)
**Consumer**: `src/dmdwrap.d` (`dmdParseNoRegister`), `src/worker.d`
(`buildIndexNow`)
**Tests**: `tests/test_index.py` (`index-keeps-universe`, `index-module-fqn`)
**Status**: not upstreamable as-is.

### Problem

`Module.parseModule` registers the module it parses: `Package.resolve` inserts
`Package` objects into the global `Module.modules` table, `dst.insert` inserts
the module itself (and on a duplicate name calls `eSink.error(... conflicts
with another module ...)` and returns the *previously parsed* module), and
`amodules.push(this)` appends to the global module list.

The workspace index parses every project file. With registration, that collides
with the live semantic universe: re-parsing a module the universe already holds
would emit a spurious conflict and hand back the live `Module*`. That is why
`buildIndexNow` called `dmdResetRequest` first — which **evicts the warm
universe** (`s.uni.valid = false`), forcing a full re-analysis on the next
request. The index needs the parse-level AST only (names, kinds, `Loc`), none of
the registration.

### Hack

`parseModule(AST)(bool registerModule = true)`. When `false`, it skips the two
`Package.resolve` calls and the entire symbol-table/`amodules`/`Compiler`
registration tail. `dmdParseNoRegister` builds the `Module`, runs it with the
flag off, gags the compiler sink (`global.gag = 1`) and restores the error
counters; the caller (`buildIndexNow`) rolls the `Loc` table back with
`dmdLocCheckpoint`/`dmdLocRollback`. Without a package parent, the FQN is
rebuilt from `md.packages` + `ident` (`worker.indexModuleName`).

```d
// src/dmdwrap.d
m = m.parseModule!ASTCodegen(false); // registration-free
```

### Why it is a hack

A "parse but do not register" mode is a library-consumer escape hatch, not
something the compiler wants; upstream should get a supported
`Module.reparse`/library API instead. It is the enabling piece for the index
(and the persistent-store plan) but changes no compiler behaviour by default.

### Keeping it honest

`src/dmdwrap.d` calls `m.parseModule!ASTCodegen(false)`: if a `make vendor`
drops the flag, `parseModule` takes no arguments and the **build fails**.
`tests/test_index.py` pins the semantics — `index-keeps-universe` fails if an
index build evicts the warm universe (`analyze.full > 1`), and
`index-module-fqn` fails if the FQN rebuild is wrong.

---

## H4. `FileManager.setFileContents` — replaceable file contents (open-doc mirror)

**Files**: `src/dmd/file_manager.d` (`setFileContents`, `removeFileContents`)
**Consumer**: `src/dmdwrap.d` (`g_docMirror`, `dmdSetDoc`, `dmdRemoveDoc`,
`dmdReapplyDocMirror`, mirror-aware `universeDepsChanged`), `src/worker.d`
(`setDoc` op), `src/main.d` (push on open/change/save/close + prime on spawn)
**Tests**: `tests/test_mirror.py` (`unsaved-dep-reflected`)
**Status**: not upstreamable.

### Problem

dmd reads a dependency's source through `Module.read` →
`FileManager.getFileContents` (`file_manager.d`), which is cache-first but
disk-only. A language server holds the *open, unsaved* buffer; without an
overlay, `app.d` importing an edited-unsaved `lib.d` is analysed against the
stale on-disk `lib.d` until the user saves. `FileManager.add` cannot fix this:
it uses `StringTable.insert`, which returns null (no-op) when the key exists
(`root/stringtable.d`), so it can only populate, never update. And
`dmdResetRequest` → `global.deinitialize()` → `_init()` builds a **new**
`FileManager`, so anything stored there is lost on every full rebuild.

### Hack

Two methods on `FileManager`: `setFileContents` (insert-or-update via
`StringTable.update`) and `removeFileContents` (evict via `removeWhere`, so a
closed document falls back to disk). `src/dmdwrap.d` keeps the overlay in a
worker-global `g_docMirror` that **survives resets** and re-installs it from
`dmdResetRequest`; `universeDepsChanged` compares a mirrored dep against the
mirror hash and everything else against disk, so an unsaved edit invalidates
the warm universe exactly like a disk change would. Dep hashes go through
`depHash`, which ignores a trailing NUL: mirrored buffers are NUL-terminated
(like the root parse) while disk reads are not, and hashing verbatim made
opening a dependency flip its hash and respawn the worker on the next
completion.

### Why it is a hack

An editor open-document overlay is meaningless to a compiler; upstream would
want a general virtual-file-system/`FileManager` injection point, not an
LSP-shaped API.

### Keeping it honest

`src/dmdwrap.d` calls `setFileContents`/`removeFileContents`: dropping the
methods is a **compile error**. `tests/test_mirror.py` fails if the overlay
stops being applied — `app.d` must report `libValue` as undefined after `lib.d`
is edited unsaved (it resolves from disk without the overlay).

---

## H5. `lspKeepErroredBodies` — keep a body past a broken statement

**Files**: `src/dmd/statementsem.d` (global + `visitCompound`)
**Consumer**: `src/dmdwrap.d` (`dmdInit` sets it)
**Tests**: `tests/test_realworld.py` (`typing-completion-items`),
`tests/test_completion_scope.py`, `tests/test_recovery_scope.py`
**Status**: not upstreamable.

### Problem

`statementSemanticVisit`'s `visitCompound` flattens a compound and, on the
first child that semantically fails (an `ErrorStatement`), **replaces the whole
compound with that one error** and returns. So a single bad statement – exactly
what a half-typed line is – discards the entire enclosing function body.

A language server analysing the real, unsaved buffer loses the function's
locals, scopes and `with`/`foreach` structure the moment the user is mid-edit.
Previously the server papered over this by re-analysing a *neutralised* buffer
on every completion request, which is the per-keystroke cost this hack removes.

### Hack

A process-global `__gshared bool lspKeepErroredBodies` in `dmd.statementsem`
(default `false`). When set, `visitCompound` does not collapse: it walks the
statements, replaces each `ErrorStatement` with a no-op
`new ExpStatement(s.loc, cast(Expression) null)`, and keeps the body. The
function's scope survives, so the warm real-text analysis can answer
completion. `dmdInit` sets it once at startup.

```d
// src/dmdwrap.d (dmdInit)
import dmd.statementsem : lspKeepErroredBodies;
lspKeepErroredBodies = true;
```

### Why it is a hack

Error recovery that deliberately keeps semantically broken bodies is the wrong
default for a compiler (it hides errors), and it changes what semantic leaves
behind. It is only wanted by a consumer that must stay useful while the buffer
does not compile.

### Keeping it honest

`src/dmdwrap.d` imports `lspKeepErroredBodies`, so a `make vendor` that drops
the global is a **compile error**. `tests/test_realworld.py`
(`typing-completion-items`) completes a member chain on a struct local in a
function whose next line is a dangling `w.assets.`: it yields nothing if the
body is collapsed away.

---

## Adding a hack

1. Keep it as small and self-contained as possible; put the toggle in the
   module that already owns the behavior.
2. Reference it from the dmd-lsp side, so a dropped patch is a compile error.
3. Add a regression test that fails when the hack is removed or broken.
4. Document it here: files, consumer, tests, problem, what it does, why it
   cannot go upstream.

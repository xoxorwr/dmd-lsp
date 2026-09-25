# Hacks on the vendored dmd

This file documents the edits we make to the vendored frontend (`src/dmd/`)
that are *not* candidate upstream patches. The upstream-bound patch is in
[upstream.md](upstream.md); packaging lives in [vendoring.md](vendoring.md).

Rule of thumb:

- If it is a real frontend fix that could be submitted to dmd as its own
  commit, it belongs in [upstream.md](upstream.md).
- If it exists only so a *language server* can work — a mode, a global, an
  escape hatch no compiler user would want — it belongs here.

Each lives as a patch file in `patches/` (`h1-no-manifest-expand.patch`,
`h2-baseclass-loc.patch`, `h5-keep-errored-bodies.patch`), applied by
`make vendor` on top of stock dmd; every edited spot carries a
`dmd-lsp Hn (docs/hacks.md)` comment. A patch that no longer applies fails the
vendor step. Beyond that:

- dmd-lsp imports the hack's frontend symbol, so a missing patch is a
  **compile error**, not a behavior change;
- a regression test pins the behavior, so a patch that applies but stops
  working is caught by `make check`.

---

## H1. `lspNoManifestExpand` — keep manifest constants in the AST

**Files**: `src/dmd/optimize.d`, `src/dmd/initsem.d`
**Consumer**: `src/ops.d` (`computeRefs`)
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

`src/ops.d` sets it **only around the per-candidate analyses** in
`computeRefs`, so diagnostics, completion, hover and lint keep the normal
folded AST. The candidates get levels of their own: the overlay and the
dependency level are dropped before (a candidate may live in either, analysed
folded) and again after, so nothing unfolded is served to later requests.

```d
// src/ops.d (computeRefs)
import dmd.optimize : lspNoManifestExpand;
engineReset(s.engine, true);
lspNoManifestExpand = true;
scope (exit)
{
    engineReset(s.engine, true);
    lspNoManifestExpand = false;
}
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

`src/ops.d` imports `dmd.optimize : lspNoManifestExpand` on purpose: if a
`make vendor` drops the frontend half, the build fails here. If the frontend
half survives but stops doing its job, `enum-compound-*` and
`const-manifest-refs` fail. Both are required before merging a vendor refresh.

---

## H2. `BaseClass.loc` — keep base-clause locations

**Files**: `src/dmd/dclass.d` (field), `src/dmd/dsymbolsem.d` (capture; the
parse-time base type is checked by tag — `Tident`/`Tinstance`/`Ttypeof`/
`Treturn` — before it is read as a `TypeQualified`, since an extern(C++) cast is
unchecked and a base can be a `TypeMixin`)
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

## H3, H4 (removed)

H3 (`parseModule(registerModule)`, parse without registering) and H4
(`FileManager.setFileContents`, replaceable file contents for open documents)
existed to parse and serve buffers inside one live, never-reset universe.
Neither is needed on memory levels: `dmdParseNoRegister` drives dmd's `Parser`
directly (registration is a separate step it skips), and open documents are
added with the stock `FileManager.add` when each overlay is pushed — the next
overlay starts from a clean file table anyway.

---

## H5. `lspKeepErroredBodies` — keep a body past a broken statement

**Files**: `src/dmd/statementsem.d` (global + `visitCompound`)
**Consumer**: `src/engine.d` (`ensureInit` sets it)
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
completion. The engine sets it on level 1, so every analysis sees it.

```d
// src/engine.d (ensureInit)
import dmd.statementsem : lspKeepErroredBodies;
lspKeepErroredBodies = true;
```

### Why it is a hack

Error recovery that deliberately keeps semantically broken bodies is the wrong
default for a compiler (it hides errors), and it changes what semantic leaves
behind. It is only wanted by a consumer that must stay useful while the buffer
does not compile.

### Keeping it honest

`src/engine.d` imports `lspKeepErroredBodies`, so a `make vendor` that drops
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

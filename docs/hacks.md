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

## Adding a hack

1. Keep it as small and self-contained as possible; put the toggle in the
   module that already owns the behavior.
2. Reference it from the dmd-lsp side, so a dropped patch is a compile error.
3. Add a regression test that fails when the hack is removed or broken.
4. Document it here: files, consumer, tests, problem, what it does, why it
   cannot go upstream.

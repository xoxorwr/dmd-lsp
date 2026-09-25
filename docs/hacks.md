# Hacks on the vendored dmd

This file documents the edits we make to the vendored frontend (`src/dmd/`)
that are *not* candidate upstream patches. The upstream-bound patch is in
[upstream.md](upstream.md); packaging lives in [vendoring.md](vendoring.md).

Rule of thumb:

- If it is a real frontend fix that could be submitted to dmd as its own
  commit, it belongs in [upstream.md](upstream.md).
- If it exists only so a *language server* can work — a mode, a global, an
  escape hatch no compiler user would want — it belongs here.

Each lives as a patch file in `patches/` (`h1-record-const-folds.patch`,
`h2-baseclass-loc.patch`, `h5-keep-errored-bodies.patch`), applied by
`make vendor` on top of stock dmd; every edited spot carries a
`dmd-lsp Hn (docs/hacks.md)` comment. A patch that no longer applies fails the
vendor step. Beyond that:

- dmd-lsp imports the hack's frontend symbol, so a missing patch is a
  **compile error**, not a behavior change;
- a regression test pins the behavior, so a patch that applies but stops
  working is caught by `make check`.

---

## H1. `lspConstFolded` — record the uses constant folding erases

**Files**: `src/dmd/optimize.d` (`patches/h1-record-const-folds.patch`)
**Consumer**: `src/engine.d` (`engineBeginUnfolded`, `analyzeFresh`),
`src/references.d` (`walkModule`), `src/ops.d` (`computeRefs`)
**Tests**: `tests/test_references.py` (`enum-compound-member-refs`,
`enum-compound-type-refs`, `const-manifest-refs`), `tests/test_rename.py`
(`rename-enum-compound-member`)
**Status**: not upstreamable as is (a tooling hook), but harmless: it changes
nothing dmd computes.

### Problem

dmd substitutes **manifest constants** with their value during semantic
(`dmd.optimize.fromConstInitializer` → `expandVar`, and the struct-constant
field path in `visitDotVar`). A `VarExp` to an `EnumMember` or a constant is
what gives references and rename their identity; once folded, the link is gone
and one literal can stand for several uses (`Test.A + Test.B`), so those uses
are not found and a rename would silently leave them behind. Simple enum
accesses are also recovered from the folded, enum-typed `IntegerExp`
(`emitEnumAccess` in `src/references.d`), but not compound expressions or
plain constants.

### Hack

A hook, `__gshared void function(VarExp) nothrow lspConstFolded` in
`dmd.optimize`, null by default. When set, it is called with each `VarExp`
that folding is about to replace. Folding is unchanged.

The engine sets it only during workspace reference search for a *foldable*
target (an enum, an enum member, a manifest/const/immutable variable), around
each candidate root's own analysis, and keeps the recorded `VarExp`s in
`Analysis.folds`; the references walker visits them as if they were still in
the tree (restricted to the module being searched). For such a search the
candidate modules are analysed as roots in a fresh overlay — kept out of the
dependency and warm levels, which were analysed without recording — and that
overlay is dropped afterwards. Other targets need none of this: their
candidates are just further roots of the current overlay.

```d
// src/engine.d (analyzeFresh, the root's semantic only)
import dmd.optimize : lspConstFolded;
g_folds = null;
lspConstFolded = e.recordFolds ? &noteFold : null;
scope (exit)
    lspConstFolded = null;
```

The earlier version of this hack *disabled* folding (and CTFE of initializers)
instead. That made dmd compute something else: Phobos CTFE met uninterpreted
initializers and asserted (`copyRegionExp`), so references failed on any
Phobos-heavy module. Recording leaves dmd's results alone.

### Why it is a hack

A consumer callback inside the optimizer, for tooling only. Upstream might
accept a general "folded" notification, but not in this form.

### Cost

One null-pointer test per substitution when unset. When set (reference search
only), one array append per substitution.

### Keeping it honest

`src/engine.d` imports `dmd.optimize : lspConstFolded`: a vendor refresh that
loses the patch fails to build. If the hook stops firing, `enum-compound-*` and
`const-manifest-refs` fail.

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

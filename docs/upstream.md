# Upstream work & roadmap

## Patches in `../dmd` (submitted manually)

1. **Null guard in `SearchVisitor::visit(Import)`** (`dsymbolsem.d`): scope
   search over a failed import load dereferenced null `imp.mod`. Reachable by
   any frontend-as-library consumer that continues semantic without stock's
   fatal gates.
2. **Phobos-free `dmd.frontend`**: dropped all `import std.*` (config
   discovery rewritten on `dmd.root`/`core`; `parseModule` returns a
   `ParsedModule` struct with the same `.module_` / `.diagnostics` members).
   Consumer std closure went 58 modules → ~13 with no source-level importer
   left; binary −19%. Two intended API deltas: `Tuple` → struct, lazy
   import-path ranges → `string[]`.
3. **Identifier-pool reset**: `deinitializeDMD` now calls
   `Identifier.deinitialize()` (`identifier.d`) and `initializeKeywords()`
   (`tokens.d`). Without it a long-lived frontend-as-library consumer grows
   the intern table unboundedly (keywords' `TOK` values live on their
   identifiers, so they must be re-registered after the reset).

Until these land, the repo [vendors](vendoring.md) the exact frontend closure
under `src/dmd/` so the shipped build is self-contained and carries the
patches. It is a snapshot, not a fork.

## What to do next

Ordered by value/effort:

1. **Follow through upstream**: submit the three patches, handle review
   (likely questions: `ParsedModule` vs `Tuple`, `string[]` vs ranges,
   Windows branches which can't be CI-checked locally).
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

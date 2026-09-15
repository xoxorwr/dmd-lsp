# Design

How `dmd-lsp` works and the conventions it is built on.

## Ground rules

- The dmd frontend is **vendored** under `src/dmd/` so the build is
  self-contained ([vendoring](vendoring.md)). `../dmd` is a read-only
  reference/dev tree — refresh with `make vendor`, never edit `src/dmd/`.
- Do not edit `../dmd` without explicit permission.
- Our code is `struct`-only (no `class`/`interface`/inheritance).
- Our code uses no phobos (`std.*`): JSON comes from the vendored
  `src/json.d` (kdom's `rt.json` adapted: `Arena` allocator, `core.stdc`
  libc, plus a serializer); files via C stdio.
- Never D-`cast` dmd AST nodes down: `extern(C++)` classes have no runtime
  type check, so a bogus cast reads wrong field offsets (a crasher once
  came from `cast(ConditionalDeclaration)` on a `MixinDeclaration`).
  Tag-check (`dsym`, `ty`, `isX()`) first.
- Hot paths allocate from arena/bump allocators, not the GC.
- Toolchain targets the 2.113.0 line (never system dmd). LDC's `ldmd2` is
  supported (`make DC=ldmd2`) and is what CI/nightlies use.

## Memory model: one universe per worker

The LSP front end holds no dmd state — only session docs, config and the
debounce bookkeeping. **Analysis runs in a forked worker process, one
universe per worker** (`worker.d`).

dmd's process-global state is never fully reset by `deinitializeDMD` (it is
written for one-shot compiler runs): reusing one universe across rebuilds
retained a whole module graph per rebuild (~140 MB/request, growing without
bound). A worker performs exactly **one** full build and then serves cache
hits from it; on any invalidation it replies `needRespawn` and the parent
kills it and forks a fresh one, so nothing accumulates and the OS reclaims
everything on exit. Bounded to ~one universe.

The isolation decision (measurements, the identifier-pool bug, eviction
experiments, a region-GC spike) is written up in
[findings.md](findings.md).

## Semantic pipeline

- Parse errors do **not** stop analysis (an LSP must serve broken code);
  import-load errors do — a scope search over a failed import segfaults
  otherwise (guarded upstream, see [upstream.md](upstream.md)).
- Lint: unused imports (post-semantic exported-name sets incl. transitive
  public re-exports, vs a lexical identifier use-set with import spans
  excluded; skips baseline errors, string mixins, risky `__traits`,
  public/export re-exports) and unused params (declare-before-use counting;
  skips `out` params, generated `__param_N`, files with errors).
- Completion merges a pre-semantic structure snapshot (function ranges,
  local names — immune to `ErrorStatement` rewrites) with semantic types;
  unresolved identifier types resolve via scope lookup.
- The worker's stdout is rerouted to stderr: dmd message-kind output
  bypasses `DiagnosticHandler` straight to stdout, which would corrupt LSP
  framing. `initDMD` leaves the lexer identifier tables unset (stock sets
  them from CLI flags), which segfaults on the first non-ASCII identifier —
  initialized like stock does.

## Universe cache

Inside a worker the universe stays alive (`server.Universe`): a request with
identical inputs — same root text (`fnv1a64`), same dep disk bytes (hashes
recorded from `Module.src`), same config generation — is served with zero
dmd work. Completions/codeActions after an analysis are cheap (measured
13×: 33 ms vs 427 ms on the 378 KB stress file); the residual cost is piping
the document to the worker. Anything else is a miss and triggers a respawn.

Deps are fingerprinted from disk bytes, so unsaved dep edits disable the
cache until save — same cost as before, never stale results. Dep changes are
noticed on the dependent's next analysis (no file watching); a same-text
`didChange` still marks pending for exactly that reason.

### Neutralised variants

dmd collapses a whole function body to one `ErrorStatement` on any statement
error, wiping every local's inferred `auto` type. To keep completion working
while typing, the request is analysed against a **neutralised variant** of
the buffer (keyed on the *real* document text): a dangling dot becomes
`x.__dmd_lsp_ph()` plus an appended unconstrained UFCS template; a lone
partial identifier is dropped; an unfinished call/array argument blanks its
expression statement.

The universe records both hashes (`Universe.rootHash` = document,
`Universe.analysisHash` = what was parsed, `serverWouldHitAnalysis`), so the
debounced analyze for that same document text is a hit: one build per
document version, not one per request. Only **completion** needs the exact
analysis text (it walks the AST at the cursor); **hover, definition and
signature help** match on document identity alone (`serverWouldHit`), since
neutralisation rewrites only the incomplete statement, never declarations —
so a symbol request after a placeholder completion reuses that universe
instead of rebuilding. Placeholder diagnostics are rewritten back to document
columns (`mapFixDiags`). `tests/test_spawn.py` locks the spawn accounting in
by counting worker spawns.

## Request loop

The stdio loop is poll-gated (single-threaded, no preemption): pending docs
are analysed after the debounce idle timeout, so superseded work is never
started — that coalescing is the cancellation story, since dmd offers no safe
mid-analysis abort point. stdin runs unbuffered so kernel pipe state (what
`poll` observes) and stdio agree; mixing `poll` with buffered stdio silently
strands messages in the userspace buffer.

## Status

Verified by `make check` (94 assertions across the LSP, universe-cache,
debounce, config and memory suites) plus stress runs against real dmd
sources (378 KB file, full frontend semantic):

- Diagnostics (compiler errors as you type, incl. broken code), unused
  import/parameter hints, remove-import quickfixes.
- Scope-aware completion with types, docs and sorting; dot-chains incl.
  pointer deref and array element access (`xs[0].`); selective-import
  symbol lists (`import mod : a, b|` completes `mod`'s members); comment/string
  suppression; trailing-dot completion (including inside an unclosed call
  argument list); CTFE string-mixin declarations; symbols re-exported
  through `public import` chains.
- LSP 3.17 `labelDetails` when the client opts in: functions render as
  label + `(params)` + return type (`dist(Point, int) int`); variables and
  fields show their type (`p Point`, `x int`); other declarations their
  kind (`Point struct`, `ptrdiff_t alias`).
- `textDocument/signatureHelp` (trigger `(`, `,`) for calls and struct
  literals (`Entry(target, hate)`), active parameter by comma nesting.
- `textDocument/definition` for locals/params, module members, imported
  symbols and members of dotted chains. Cross-file locations are turned into
  absolute `file://` URIs (`absolutePath`/`pathToUri`), Windows-aware (drive
  letters, backslash normalisation).
- `textDocument/hover`: functions/types/templates/aliases are rendered by
  dmd's own `hdrgen` (`toCBuffer` with `hdrgen=true, doFuncBodies=false`,
  indented), so no source reading or brace-matching is needed. Variables/
  fields/locals use a synthesized `type name` instead, because hdrgen's
  header form marks declarations `extern` (locals become `extern S s;`).
  Modules are excluded (a Module would dump the whole file). Doc comment
  appended as Markdown.
- Semantic survives parse-errored buffers (only import-load errors gate it),
  so mixin expansion, `auto` inference and visibility work while typing.
- Universe cache: repeated requests ~free (13× on the stress file); edits
  rebuild via a fresh worker; parent RSS flat over dozens of rebuilds
  (~16 MB); worker memory reclaimed by the OS on respawn.
- `--check` batch mode for CI.

## Known limitations

- Changed inputs rebuild the whole universe in a fresh worker: re-analysis
  costs full dep semantic (~0.4 s on the stress file, ~10 ms on small files).
  Deliberate: dmd interns canonical types by mangled deco, so re-parsing a
  changed root in a live universe collides with its own previous
  declarations, and template instantiations over root-local types would
  reuse stale instances — module-level eviction is unsound without dmd-side
  type-table support.
- Hit requests still pipe the whole document (~380 KB here), ~20 ms of the
  33 ms hit; hashing instead of shipping the text is a later optimisation.
- Whole-line import granularity (selective `import m : a, b` is
  used-if-any-bound-used); no unused-local lint yet.
- Graceful degradations fall back to empty: UFCS candidates, dot-completion
  on `auto` condition variables (no stored type), unparseable regions
  (e.g. unclosed brace at EOF).
- A genuine semantic error anywhere in a function body still collapses the
  body, so `auto` locals lose their types until it is fixed; explicitly
  typed locals resolve via the snapshot.

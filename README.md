# dmd-lsp

A minimal, dmd-frontend-native language server for D. No DCD, no libdparse
heuristics — diagnostics, completion and lint run on real `dmd` semantic,
used read-only as a library.

Rules this repo lives by:

- The dmd frontend is **vendored** under `src/dmd/` so the build is
  self-contained (see "Vendored dmd"). `../dmd` stays a read-only
  reference/dev tree — refresh the snapshot with `make vendor`, never edit
  `src/dmd/` by hand.
- Never edit `../dmd` without explicit permission.
- Our code is `struct`-only (no `class`/`interface`/inheritance).
- Our code uses no phobos (`std.*`): JSON comes from vendored
  `src/json.d` (kdom's `rt.json` adapted: `Arena` allocator, `core.stdc`
  libc, `key` member renamed, plus a serializer), files via C stdio.
  Upstream `dmd.frontend` itself is now phobos-free too (see
  "Upstream work" below); a few small template-only std modules still
  surface in the build closure with no source-level importer.
- Never D-`cast` dmd AST nodes down: `extern(C++)` classes have no
  runtime type check, so a bogus cast reads wrong field offsets
  (crasher found via `cast(ConditionalDeclaration)` on a
  `MixinDeclaration`). Tag-check (`dsym`, `ty`, `isX()`) first.
- Hot paths allocate from arena/bump allocators, not the GC.
- Toolchain is pinned to the 2.113.0 line (never system dmd). LDC's
  `ldmd2` is supported (`make DC=ldmd2`) and is what CI/nightlies use.

## Build

```sh
make            # builds ./dmd-lsp (from the vendored src/dmd/)
make check      # struct-only guard + batch fixtures + LSP regression suite
make check-no-oop
make deps       # audit exactly which dmd modules got pulled in
make vendor     # re-copy the frontend closure from ../dmd
```

`make` uses `dmd -i`, so only transitively-imported frontend modules
compile — no backend/glue. Needs `stringimp/SYSCONFDIR.imp` (present) and
`-J` paths from the Makefile. The compiler is overridable: `make DC=ldmd2`
builds with LDC's dmd-compatible driver (produces a smaller binary; the
LDC frontend must be new enough to compile `src/dmd`).

## Nightly builds

`.github/workflows/nightly.yml` builds a rolling prerelease tagged
`nightly` (LDC `ldmd2`, on a schedule + manual dispatch). Asset names are
stable so a VS Code client can fetch and verify:

- `dmd-lsp-linux-x64.tar.gz`
- `dmd-lsp-darwin-arm64.tar.gz`
- `dmd-lsp-darwin-x64.tar.gz`
- `dmd-lsp.vsix` (VS Code extension; downloads the right binary on first run)
- `SHA256SUMS`

Each archive contains the `dmd-lsp` binary at its root. Download base:
`https://github.com/<owner>/<repo>/releases/download/nightly/`.

The VS Code client lives in [`editor/vscode/`](editor/vscode/) and is
published as `dmd-lsp.vsix`; on first activation it downloads the binary
for the host platform into the extension's global storage (set
`dmdLsp.serverPath` to use a local build).

Windows is not built: the worker (`fork`/`socketpair`) and the poll-gated
stdio loop are POSIX-only, so a Windows binary would not run. Porting the
worker (threads or `CreateProcess`) is a prerequisite.

## Vendored dmd

`src/dmd/` is a snapshot of `../dmd/compiler/src/dmd` containing the exact
`-i` closure plus the two string imports it needs (`VERSION`,
`res/default_ddoc_theme.ddoc`): 145 files, ~6.9 MB. It includes the fixes
below, so `make` needs no `../dmd` at all — only the D compiler's
druntime/phobos are external. This is packaging, **not a fork**: do not
edit files under `src/dmd/`.

The set is exactly what the frontend imports (nothing extra to strip).
Cross-platform notes:

- **Windows**: one extra module, `root/strtold.d` (the MSVC `strtold`
  used by `root/ctfloat.d` under `version(CRuntime_Microsoft)`), copied
  from `PLATFORM_EXTRA` in the Makefile.
- **macOS/BSD**: no extra dmd modules; their code uses `core.sys.*` from
  druntime.
- `dmd/iasm.d` and `dmd/backend/symbol.d` are intentionally absent — the
  build sets `-version=NoBackend`, so those imports are compiled out.

- Refresh: `make vendor` re-derives the closure from `../dmd` and
  re-copies it (plus `PLATFORM_EXTRA`). Run it after pulling the dev tree,
  or once the patches land upstream, delete `src/dmd/` and restore
  `-I../dmd/compiler/src`.

## Usage

Batch check (exit 1 on errors, 0 otherwise; hints never fail the build):

```sh
./dmd-lsp --check --import=tests tests/u1.d
# tests/u1.d(4:8): Hint: unused import `libb`
# tests/u1.d(7:1): Hint: unused parameter `unused`
```

```sh
./dmd-lsp --check FILE...          # batch mode
./dmd-lsp --stdio                  # LSP over stdio (default)
./dmd-lsp --import=DIR...          # module import paths (-I)
./dmd-lsp --string-import=DIR...   # string import paths (-J, for import("..."))
./dmd-lsp --flag=-preview=NAME     # pass a supported dmd flag to the analyzer
./dmd-lsp --debounce-ms=N          # diagnostics idle delay (default 300)
./dmd-lsp --version
```

Diagnostics are debounced: `didChange` only marks the doc pending;
analysis + `publishDiagnostics` run after N ms of stdin idle, so a
keystroke burst costs one analysis, not N. `didOpen`/`didSave` publish
immediately; completion serves the current buffer without publishing;
codeAction refreshes its cache silently (its edits carry ranges).

Editor setup: point any LSP client at `dmd-lsp` for `source.d` files.
Supported: `initialize`, `textDocument/{didOpen,didChange,didClose,didSave}`,
`completion` (LSP 3.17 `labelDetails` when the client opts in),
`signatureHelp`, `codeAction` (remove unused import, single +
remove-all), `publishDiagnostics` (compiler errors + lint hints).
Incremental `didChange` ranges are applied client-independently (some
clients ignore the advertised full-sync kind).

Completion is scope-aware: function params (incl. `if`/`while`/`switch`/
`with`/`foreach` condition variables) and block locals (prefix-
filtered, locals sort first), module members, symbols re-exported through
`public import` chains, and dotted chains (`mod.member`, `var.member`,
`Alias.member`, `arr[0].member`) resolved through variable/return types,
including transparent pointer dereference (`Scope*` works) and
pre-semantic identifier types. Attribute blocks (`private:`, `@safe:`,
...) are descended everywhere — most real-world members hide inside them.
Items carry kind, type detail, doc comments, sort text and (LSP 3.17)
`labelDetails` for functions. Completion is suppressed inside comments and
strings; CTFE string-mixin declarations are visible.

Because dmd collapses a whole function body to one `ErrorStatement` on
any statement error — wiping every local's inferred `auto` type —
completion analyses a **neutralised variant** of the buffer, keyed on the
real document text (see "How it works"): a dangling dot becomes
`x.__dmd_lsp_ph()` plus an appended unconstrained UFCS template, a lone
partial identifier is dropped, and an unfinished call/array argument
blanks its expression statement.

Import paths: repeat `--import=DIR`, or configure from the editor:

```jsonc
// initializationOptions or workspace/didChangeConfiguration settings:
{
  "dmd-lsp": {
    "importPaths": ["/path/to/phobos", "/path/to/druntime"],
    "stringImportPaths": ["/path/to/res"],  // for import("...") files (-J)
    "flags": ["-preview=rvaluerefparam", "-betterC", "-version=Foo"]
  }
}
// ("d" / "D" top-level keys and bare objects also accepted)

Project config: `dls.json` at the workspace root (root from the
`initialize` request's first workspace folder, else `rootUri`, else
`rootPath`) so a bare `dmd-lsp` launch just works in any editor:

```jsonc
// <root>/dls.json (flat schema, relative paths resolve against <root>):
{
  "importPaths": ["src/", "sandbox/"],
  "stringImportPaths": ["views/"],  // optional, for import("...") files
  "debounceMs": 300,                // optional, diagnostics idle delay
  // dmd flags the project's build uses. Important: previews change
  // overload resolution / template constraints, so a build that omits
  // one here produces spurious errors (e.g. `-preview=rvaluerefparam`
  // lets rvalues bind to `ref` parameters).
  "flags": ["-preview=rvaluerefparam", "-preview=bitfields", "-betterC"]
}
```

Supported flag forms: `-preview=NAME`, `-revert=NAME`, `-version=NAME`,
`-betterC`, `-I<path>`, `-J<path>`; unknown flags are ignored. Same
flags are settable per-launch with `--flag=...` (e.g.
`--flag=-preview=rvaluerefparam`).

Precedence is explicit-first: editor settings (replacing CLI wholesale
when present), then CLI flags, then `dls.json`, then builtin defaults
(repo `druntime/src`, then 2.113.0 `phobos` + `druntime/import`). Each
layer appends what earlier ones lack, so project paths always precede
the stdlib defaults. A `--debounce-ms=` flag likewise beats the file. The file loads at `initialize` (a
`window/showMessage` Log confirms, Error on malformed JSON) and reloads
whenever it is saved — including when created after startup. `dls.json`
itself is never analyzed as D. `--check` batch mode ignores it
(CLI/defaults only).

## How it works

The LSP front end holds no dmd state — only session docs, config and the
debounce bookkeeping. **Analysis runs in a forked worker process, one
universe per worker** (`worker.d`). dmd's process-global state is never
fully reset by `deinitializeDMD` (it is written for one-shot compiler
runs): reusing one universe across rebuilds retained a whole module
graph per rebuild (~140 MB/request, growing without bound). A worker
performs exactly **one** full build and then serves cache hits from it;
on any invalidation it replies `needRespawn` and the parent kills it and
forks a fresh one, so nothing accumulates and the OS reclaims everything
on exit. That is the whole memory story: bounded to ~one universe.

Each build runs stepped semantic: parse errors do **not** stop analysis
(an LSP must serve broken code), but import load errors stop before
semantic — a scope search over a failed import segfaults otherwise
(guarded upstream in `dsymbolsem.d` `SearchVisitor::visit(Import)`).

Why isolation rather than an in-process reset (measurements, the
identifier-pool bug, eviction experiments, and a region-GC spike) is
written up in [`docs/findings.md`](docs/findings.md).

Within a worker, the universe is kept alive (universe cache,
`server.Universe`): a request with identical inputs — same root text
(fnv1a64), same dep disk bytes (content hashes recorded from `Module.src`),
same config generation — is served with zero dmd work. Completions and
codeActions following an analysis are cheap (measured 13×: 33 ms vs
427 ms on the stress file); the residual cost is piping the document to
the worker. Anything else is a miss and triggers a respawn. Deps are
fingerprinted from disk bytes, so unsaved dep edits disable the cache
until save — same cost as before, never stale results. Dep changes are
noticed on the dependent's next analysis (no file watching); a same-text
`didChange` still marks pending for exactly this reason.

When a completion analyses a *neutralised* variant rather than the
document text, the universe is keyed on the real document
(`Universe.rootHash`) while recording which text was parsed
(`Universe.analysisHash`, `serverWouldHitAnalysis`). So the debounced
analyze for that same text is a hit: one build per document version, not
one per request. Placeholder diagnostics are rewritten back to document
columns (`mapFixDiags`). `tests/test_spawn.py` locks this in by counting
worker spawns.

The stdio loop is poll-gated (single-threaded, no preemption): pending
docs are analyzed after the debounce idle timeout, so superseded work is
never started — that coalescing is the cancellation story, since dmd
offers no safe mid-analysis abort point. stdin runs unbuffered so
kernel pipe state (what poll observes) and stdio agree; mixing poll with
buffered stdio silently strands messages in the userspace buffer.

- Unused imports: post-semantic exported-name sets (incl. transitive
  public re-exports) vs a lexical identifier use-set with import spans
  excluded. Skips: baseline errors, string mixins, risky `__traits`,
  public/export re-exports.
- Unused params: declare-before-use counting (unused iff < 2
  occurrences); skips `out` params, generated `__param_N`, files with
  errors.
- Completion merges a pre-semantic structure snapshot (function ranges,
  local names — immune to `ErrorStatement` rewrites) with semantic
  types; unresolved identifier types resolve via scope lookup.

The worker's stdout is redirected to stderr; dmd message-kind output
bypasses `DiagnosticHandler` straight to stdout, so analysis also runs
with fd 1 rerouted to stderr to protect LSP framing. `initDMD` leaves
the lexer identifier tables unset (stock sets them from CLI flags), which
segfaults on the first non-ASCII identifier — worked around by
initializing them like stock does.

## Status: what's working

Verified by `make check` (76 assertions across the LSP, universe-cache,
debounce, config, and memory suites) plus stress runs against real dmd
sources (378 KB file, full frontend semantic):

- Diagnostics (compiler errors as you type, incl. broken code), unused
  import/parameter hints, remove-import quickfixes.
- Scope-aware completion with types, docs, sorting; dot-chains incl.
  pointer deref and array element access (`xs[0].`); comment/string
  suppression; trailing-dot completion (including inside an unclosed call
  argument list, where the incomplete expression statement is neutralised
  rather than injected); CTFE string-mixin declarations; symbols
  re-exported through `public import` chains.
- LSP 3.17 `labelDetails` for functions when the client opts in
  (`completionItem.labelDetailsSupport`): rendered as label + `(params)`
  + return type, e.g. `dist(Point, int) int`. Clients without support get
  the full signature in `detail` as before.
- `textDocument/signatureHelp` (trigger `(`, `,`): function/method calls
  and struct literals (`Entry(target, hate)`), with the active parameter
  tracked by comma nesting and resolved through locals, module members and
  `public import` chains.
- Semantic runs even on parse-errored buffers (only import-load errors
  gate it), so mixin expansion, `auto` inference and visibility survive
  while typing broken code. Incomplete constructs are neutralised in the
  analysis copy (`analysisText`: dangling-dot call, lone-identifier drop,
  unfinished-call/array statement blank) so they cannot collapse the
  function body and drop resolved local types.
- Universe cache inside each worker: repeated requests ~free (13× on
  the stress file: 33 ms vs 427 ms full); edits and dep changes rebuild
  via a fresh worker; no crashes, no hangs; parent RSS flat over dozens
  of rebuilds (~16 MB), worker memory reclaimed by the OS on respawn.
- `--check` batch mode for CI.

## Known limitations

- Changed inputs rebuild the whole universe in a fresh worker: re-analysis
  costs full dep semantic (~0.4 s on the stress file, ~10 ms on small
  files). Deliberate: dmd interns canonical types by mangled deco, so
  re-parsing a changed root in a live universe collides with its own
  previous declarations, and template instantiations over root-local
  types would silently reuse stale instances — module-level eviction is
  unsound without dmd-side type-table support. Process isolation is the
  sound way to reuse a universe across requests.
- Hit requests still pipe the whole document to the worker (~380 KB
  here), ~20 ms of the 33 ms hit; hashing instead of shipping the text
  is a possible later optimisation.
- Whole-line import granularity (selective `import m : a, b` is
  used-if-any-bound-used); no unused-local-variable lint yet.
- Known graceful degradations: UFCS candidates, dot-completion on
  `auto` condition variables (no stored type), unparseable regions
  (e.g. unclosed brace at EOF) fall back to empty.
- A semantic error anywhere in a function body collapses the whole body
  (dmd `visitCompound` propagates one ErrorStatement up), so `auto`
  locals in genuinely broken bodies lose their types until the error is
  fixed; explicitly-typed locals still resolve via the snapshot.

## Upstream work (in `../dmd`, submitted manually)

1. Null guard in `SearchVisitor::visit(Import)` (`dsymbolsem.d`):
   scope search over a failed import load dereferenced null `imp.mod`.
   Reachable by any frontend-as-library consumer that continues semantic
   without stock's fatal gates.
2. Phobos-free `dmd.frontend`: dropped all `import std.*` (config
   discovery rewritten on `dmd.root`/`core`, `parseModule` returns a
   `ParsedModule` struct with the same `.module_` / `.diagnostics`
   members). Consumer std closure went 58 modules → ~13 with no
   source-level importer left; binary −19%. Two intended API deltas:
   `Tuple` → struct, lazy import-path ranges → `string[]`.
3. `deinitializeDMD` now resets the process-global **identifier pool**
   (`identifier.d` `Identifier.deinitialize()` → `stringtable.reset()`,
   `tokens.d` `initializeKeywords()`, called from `frontend.d`). Without
   it, a long-lived frontend-as-library consumer grows the intern table
   unboundedly across sessions (keywords' `TOK` values live on their
   identifiers, so they must be re-registered after the reset).

## What to do next

Ordered by value/effort:

1. **Follow through upstream**: submit the three patches, handle review
   (likely questions: `ParsedModule` vs `Tuple`, `string[]` vs ranges,
   Windows branches which can't be CI-checked locally).
2. **Hover + goto-definition** from resolved `toAlias()` symbols; the
   resolution machinery already exists for completion.
3. **Per-symbol selective-import pruning** (`import m : unused` quickfix)
   and **unused locals** via the snapshot walker (names already
   collected; needs def-use over the range).
4. **Editor packaging**: VSCode client config (server path, import paths
   settings schema), progress reporting.
5. **UFCS candidates** for dot completion (the placeholder already proves
   the technique).
6. **Hit-path IPC trim**: send a content hash (or version) instead of the
   whole document to the worker when it already holds that universe.
7. Revisit remaining gaps only if they bite: unparseable-region fallback,
   `auto` condition-var dot types, Windows CI.

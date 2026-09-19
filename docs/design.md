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

## Memory model: warm workers, in-place re-parse

The LSP front end holds only session docs, config and the debounce
bookkeeping. Analysis runs in worker processes (`worker.d`, cross-platform):
POSIX `fork()`s the server, Windows spawns this executable with `--worker`;
either way each child owns one warm dmd universe and speaks length-prefixed
frames over pipes. The parent keeps a pool of up to `maxWorkers` single-root
workers, one per analyzed root, least-recently-used evicted — so switching back
to a file you already opened reuses its warm universe instead of rebuilding.
(Workers must close the other pool members' pipe fds in the child, or a killed
worker never sees EOF and the server blocks in `waitpid`.)

The expensive part is the *dependency closure* (for the dmd frontend, ~420 ms:
~110 ms parse + ~220 ms `dsymbolSemantic` + root bodies), and it is identical
on every keystroke, so it is kept warm. A **root-text-only** edit does not
rebuild it: the worker re-parses the root **in place** on the warm closure
(`dmdReparseModule`), which **evicts the previous root module and its interned
types** and parses into the same `Module` object so importers' `imp.mod` and
template-instance links stay valid (~43 ms for the same frontend). The
per-generation frontend caches are reset by the patches in
[upstream.md](upstream.md).

A dependency or config change replies `needRespawn` (or drops every worker on a
config change): the parent discards the affected worker and starts a fresh one,
so the OS reclaims the discarded universe. A root switch is absorbed by the
pool when the root is warm, and otherwise spawns/binds a worker (evicting the
LRU when full). Process isolation is the reclamation boundary because the
conservative GC cannot prove a discarded universe unreachable in-process (see
[findings.md](findings.md)). The decision, the policy any in-process store must
supply, and the checklist to re-run on every dmd bump are in
[reclamation.md](reclamation.md).

The universe records which buffer it parsed (`analysisHash`) and which
document version it was keyed to (`rootHash`): that decides whether a request
is served from the warm universe (`reuse`), re-parsed in place
(`incremental`) or rebuilt (`miss`). A neutralised (completion) parse and a
real (diagnostics/semantic) parse share the one universe. See *Neutralised
variants*.

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
- Semantic tokens (`semanticTokens/full`) lex identifiers, resolve each
  through the same symbol machinery as goto-definition, and walk the symbol
  tree for declaration names the use-pass can't reach (fields, enum
  members, template parameters). Batch resolution hoists module
  member/import-name indexes and function ranges so a whole file costs one
  pass, not one walk per token. A lexical hint layer covers what resolution
  can't: `import std.conv;` path segments render `namespace`, `@safe`/`@nogc`
  render `modifier`, other `@uda`s `decorator`, and references to template
  parameters (from the AST) render `typeParameter`. Template functions test
  their member so `save`/`empty`/`popFront` render `function`, not `type`. A
  function-pointer/delegate variable renders `function`/`method` where it is
  called (`state.fn_on_tick()`) and `property`/`variable` where it is only
  read. On real Phobos this lifts identifier coverage from ~45% to ~55-78%.
  A pull that arrives while an edit is still debounced is answered from the
  cached token set (keyed on the buffer hash) instead of forcing a build.
  The idle flush computes and caches the token set for the fresh buffer
  *before* it sends `workspace/semanticTokens/refresh`, so the client's
  re-pull is a pure cache hit — the editor never waits on a scan/resolve.
  So the debounce governs analysis even though tokens are pulled eagerly.
  Token resolution requires a universe built from the real text
  (`serverWouldHitAnalysis`), never a completion placeholder: the
  placeholder is a neutralised buffer with synthetic `__dmd_lsp_ph` code,
  and resolving against it would make highlighting depend on completion
  request order. The cost is one extra build when a placeholder completion
  precedes a token pull; the precompute above absorbs it during the idle
  flush. Locals the pre-semantic snapshot knows but semantic dropped (a
  body collapsed by a syntax error) are classified from the snapshot, so
  the real, potentially-invalid buffer still highlights. The snapshot also
  recovers an `auto` local's constructed type from its initializer
  (`auto q = Point(...)`, `new Point(...)`, `auto s = factory!(State)()`),
  so member access above the error keeps its `property`/`method` colour.
- dmd's message-kind output is rerouted to stderr: it
  bypasses `DiagnosticHandler` straight to stdout, which would corrupt LSP
  framing. `initDMD` leaves the lexer identifier tables unset (stock sets
  them from CLI flags), which segfaults on the first non-ASCII identifier —
  initialized like stock does.

## Universe cache

The warm universe (`server.Universe`) is reused while inputs are identical —
same root text (`fnv1a64`), same dep disk bytes (hashes recorded from
`Module.src`), same config generation. A request the warm universe can answer
is served with zero dmd work; the residual cost is piping the document in. A
**root-text-only** miss is handled by `serverAnalyzeIncremental`
(evict root, re-analyze it in place on the warm closure), see *Memory model*. A miss for any other reason (different
root, config generation, dep bytes) replies `needRespawn`.

Deps are fingerprinted from disk bytes, so unsaved dep edits are not seen
until save — never stale results, but a dep edit in an open doc does not
invalidate the closure until it is saved. Dep changes are noticed on the
dependent's next analysis (no file watching); a same-text `didChange` still
marks pending for exactly that reason.

### Neutralised variants

dmd collapses a whole function body to one `ErrorStatement` on any statement
error, wiping every local's inferred `auto` type. To keep completion working
while typing, the request is analysed against a **neutralised variant** of the
buffer: a partial member after a dot has its whole segment replaced with
`__dmd_lsp_ph()` plus an appended unconstrained UFCS template; a lone partial
identifier is dropped; a partial identifier after other code (`auto x = st`)
or an unfinished call/array argument blanks its statement. The last two make
the parsed text identical for every prefix length, so a whole word costs one
build, not one per keystroke. Import/module lines are never blanked — their
path/selective lists drive completion from the AST.

The universe records both hashes (`Universe.rootHash` = document identity,
`Universe.analysisHash` = what was parsed). `serverWouldHit` matches on
identity (diagnostics, hover, definition, signature, semantic);
`serverWouldHitAnalysis` matches on the analysis text (completion). Because
`s.a`, `s.ab`, `s.abc` all neutralise to the same buffer, completion reuses
one universe while a member name grows; it also refreshes `rootHash` to the
current document version, so the debounced analyze for the same text hits
that universe instead of rebuilding the real one. The cursor and prefix still
come from the real text, so filtering is live. Placeholder diagnostics are
rewritten back to document columns (`mapFixDiags`). `tests/test_spawn.py`,
`test_completion_prefix.py`, `test_completion_burst.py` and
`test_realworld.py` lock the spawn accounting in.

## Request loop

The stdio loop is poll-gated (single-threaded, no preemption): a document is
analysed after `debounceMs` of stdin idle — dmd offers no safe mid-analysis
abort point, so debouncing is the cancellation story. The default is 500 ms
(`--debounce-ms`, `dls.json`, editor setting): a fixed debounce only coalesces
keystrokes whose gap is *below* it, and a realistic typing cadence has
300–500 ms thinking pauses, so 300 ms analysed most characters individually.
The idle clock is restarted *after* each message is handled, so a slow request
(a completion's build) can't make the debounce look elapsed the instant
it returns and trigger a flush between keystrokes. Typing with the suggest
widget open never relies on the debounce at all: completion neutralises the
partial token, so the flush hits the same universe (see *Neutralised
variants*). Each pending path is always unmarked by
the flush, even on failure — a pending path that survives makes the idle loop
retry it immediately (timeout 0). stdin runs
unbuffered so kernel pipe state (what `poll` observes) and stdio agree; mixing
`poll` with buffered stdio silently strands messages in the userspace buffer.
Semantic pulls during an edit are served from the token cache; the debounced
build precomputes the new set before its `workspace/semanticTokens/refresh`.

## Status

Verified by `make check` (141 assertions across the LSP, semantic-token,
completion-burst/prefix/scope, real-world session, broken-body, universe-cache,
debounce, config and memory suites) plus stress runs against real dmd sources
(378 KB full frontend semantic, and the kdom game):

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
  re-parse in place; RSS flat over dozens of rebuilds.
- `--check` batch mode for CI.

## Known limitations

- Changed dependencies/config rebuild the whole universe: re-analysis
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

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
bookkeeping. Analysis runs in a worker process (`worker.d`, cross-platform):
POSIX `fork()`s the server, Windows spawns this executable with `--worker`;
either way the child speaks length-prefixed frames over pipes. By default there
is **one** worker, which keeps every loaded module resident and serves every
root (`sharedRegistry`); switching files re-analyses only the file's own body,
not the closure. When a dependency/config changes or the `maxModules` cap is
exceeded the worker is rebuilt. Setting `sharedRegistry: false` restores the
older pool of up to `maxWorkers` single-root workers, least-recently-used
evicted. (Pool workers must close the other members' pipe fds in the child, or
a killed worker never sees EOF and the server blocks in `waitpid`.)

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
(`incremental`) or rebuilt (`miss`). Completion does not participate in this
classification: it reads the per-root cache the debounce leaves behind (see
*Completion never analyses*).

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
  local names — immune to `ErrorStatement` rewrites) with semantic types from
  the cached analysis (H5 keeps the body usable); unresolved identifier types
  resolve via scope lookup. It never builds.
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
  Token resolution runs against the universe built from the real text, so
  highlighting never depends on completion request order. Locals the
  pre-semantic snapshot knows but semantic dropped are classified from the
  snapshot, so the real, potentially-invalid buffer still highlights. The
  snapshot also recovers an `auto` local's constructed type from its
  initializer (`auto q = Point(...)`, `new Point(...)`,
  `auto s = factory!(State)()`), so member access above the error keeps its
  `property`/`method` colour.
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

Deps are fingerprinted from the bytes dmd consumed (`Module.src`): disk bytes
for an unopened file, and the pushed **open-doc mirror** for a draft (H4,
[hacks.md](hacks.md#h4-filemanagersetfilecontents--replaceable-file-contents-open-doc-mirror)),
so an unsaved dependency edit invalidates the closure immediately. A same-text
`didChange` still marks pending, so a change on disk under an open buffer is
re-checked.

### Completion never analyses

Completion answers from the **warm universe**, never by re-parsing the buffer
mid-typing. The worker keeps a per-root cache (`ServerState.roots`, path → the
last `Analysis` of that file), written by every open/save/debounce analysis. The
`complete` op looks the document's path up there and completes against it — it
touches no semantic state and forks no child. A document with no cached
analysis highlights/decorates as empty rather than forcing a build.

The one freshness cost is a **debounce**: as-you-type completion can be one idle
cycle behind the last edit. That is invisible in practice because a member name
growing after a dot does not change the enclosing declarations, and it is the
price of removing the per-keystroke process. `tests/test_realworld.py` locks the
spawn accounting, and `tests/test_spawn.py` waits for the flush before asserting
an edit is reflected.

Keeping bodies of a broken buffer usable is H5
([hacks.md](hacks.md#h5-lspkeeperroredbodies--keep-a-body-past-a-broken-statement)):
`visitCompound` no longer discards the whole function on the first bad
statement, so the real-text analysis keeps the function's scope. Neutralisation
still exists and is still used by **signature help** (and `mapFixDiags` rewrites
placeholder columns back): the request is analysed against a variant of the
buffer where a partial member after a dot is replaced with `__dmd_lsp_ph()`
plus an appended unconstrained UFCS template. Completion no longer uses it.

The debounce itself refreshes the universe: re-parse the edited root in place
(`serverAnalyzeIncremental`) when it is the live universe's root, otherwise warm
the shared registry (`serverAnalyzeShared`, or a full `serverAnalyze` when a
dependency changed). For the pool (`sharedRegistry: false`) the same logic runs
against the worker's single universe.

## Request loop

The stdio loop is poll-gated (single-threaded, no preemption): a document is
analysed after `debounceMs` of stdin idle — dmd offers no safe mid-analysis
abort point, so debouncing is the cancellation story. The default is 500 ms
(`--debounce-ms`, `dls.json`, editor setting): a fixed debounce only coalesces
keystrokes whose gap is *below* it, and a realistic typing cadence has
300–500 ms thinking pauses, so 300 ms analysed most characters individually.
The idle clock is restarted by `didChange` **only**, so a read-only request
(hover, completion, inlay hints, token pulls) never postpones a pending
analysis. The debounced analysis is the only thing that advances the semantic
universe — and it publishes its result, so live diagnostics include semantic
errors, not just syntax. Completion reads the cache it leaves behind (see
*Completion never analyses*). Each pending path is always unmarked by the
flush, even on failure — a pending path that survives makes the idle loop retry
it immediately (timeout 0). stdin runs unbuffered so kernel pipe state (what
`poll` observes) and stdio agree; mixing `poll` with buffered stdio silently
strands messages in the userspace buffer. On POSIX the loop waits in `poll`;
on Windows a pipe handle is not a reliable `WaitForSingleObject` target, so it
polls `PeekNamedPipe` (falling back to the wait when the handle isn't
peekable). Semantic pulls during an edit are served from the token cache; the
debounced build precomputes the new set before its
`workspace/semanticTokens/refresh`.

## Status

Verified by `make check` (384 assertions across the LSP, semantic-token,
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
  through `public import` chains. Imported module interfaces are enumerated for
  bare completion, where reserved implementation names (`__*`, `_d_*`) and
  `__unittest_*` thunks are hidden (the root's own symbols are kept, so a
  user's `__`-prefixed code still completes).
- LSP 3.17 `labelDetails` when the client opts in: functions render as
  label + `(params)` + return type (`dist(Point, int) int`); variables and
  fields show their type (`p Point`, `x int`); other declarations their
  kind (`Point struct`, `ptrdiff_t alias`).
- `textDocument/signatureHelp` (trigger `(`, `,`) for calls and struct
  literals (`Entry(target, hate)`), active parameter by comma nesting.
- `textDocument/definition` for locals/params, module members, imported
  symbols and members of dotted chains. Resolved from dmd's own symbol at the
  cursor when the semantic walk has one (so an identifier inside an index
  expression is not confused with the array), falling back to a text chain for
  declaration sites. Cross-file locations are turned into
  absolute `file://` URIs (`absolutePath`/`pathToUri`), Windows-aware (drive
  letters, backslash normalisation).
- `textDocument/hover`: aggregates and enums show a short, fully-qualified
  declaration (`struct mod.Name`), never their body — hdrgen renders the whole
  member list (and enum values as `cast(T)0`), which reads as source. Functions
  and aliases are rendered by dmd's own `hdrgen` (`toCBuffer` with
  `hdrgen=true, doFuncBodies=false`, indented), so no source reading or
  brace-matching is needed. Variables/fields/locals use a synthesized
  `type name` instead, because hdrgen's header form marks declarations
  `extern` (locals become `extern S s;`). Modules are excluded (a Module would
  dump the whole file). Doc comment appended as Markdown.
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

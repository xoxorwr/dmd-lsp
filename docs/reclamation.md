# Reclamation boundary & vendor updates

Status: **decided.** The process is the reclamation boundary. Do not keep a
superseded dmd universe in a long-lived process and assume it will be freed.

This is the operational counterpart to [findings.md](findings.md) (the
evidence) and [upstream.md](upstream.md) (the patches). Read it before any work
that entertains a persistent in-process universe — e.g. the shared
module store in `PLAN2.md` — and re-run its checklist on every `make vendor`.

## The decision

| Boundary | Reliability | Cost |
|---|---|---|
| **Process teardown** (current) | deterministic, `fork`/`CreateProcess` | N universes resident (worker pool) |
| In-process region/arena GC | needs a druntime-conformant GC | not built |
| In-process conservative GC | **not reliable** (stack/register roots) | abandoned, findings §11 |

`dmdResetRequest` + process exit is what makes memory flat today. The worker
pool keeps up to `maxWorkers` universes warm *only because* eviction can kill a
process and the OS reclaims it.

## The policy we must design if we ever go in-process

A persistent store (parsed + semantically-analysed modules that survive across
roots) cannot use process exit. It must therefore supply a reclamation policy,
and that policy inherits the exact bug class that killed the earlier
in-process model:

1. **Exact reclamation, not reachability.** The conservative GC roots through
   stale stack/register values, so an address you no longer hold can still be
   live (`findings.md` §11.5). A store can only be bounded by *freeing whole
   regions* (region/arena GC, §5) or by a precise GC with compiler-emitted root
   maps — neither exists.
2. **Live-cached accumulators are not garbage.** Template instances are cached
   on their declarations (`TemplateDeclaration.instances`, a druntime AA) and
   grow with every re-parse because fresh symbols defeat dedup
   (`upstream.md` §6a). No collector reclaims them without dropping references,
   and dropping them is *worse* (re-instantiation churn). A store policy must
   bound this explicitly (a module cap, a periodic fork-rebuild + swap, or a
   reset on idle) — pick one and record it here.
3. **Config changes change semantics.** Flags/`-version`/import paths alter the
   analysed result, not just codegen. Any store must be dropped wholesale on a
   config change (`s.uni.configGen` today).
4. **`Loc` tables grow per parse** unless checkpointed
   (`dmdLocCheckpoint`/`Loc.rollback`).

If a store is ever built, its **bound** is the design decision to write down
here; "unbounded until the process exits" is the failure mode we are avoiding.

## Triggers that would reopen this

Any one of these, landing upstream or locally, moves the boundary and should be
recorded here with a re-measurement:

- a druntime-conformant region/arena GC (arrays **and** AA block contract,
  `findings.md` §5.2);
- a precise GC with compiler-emitted root maps (requires a compiler change);
- reentrant dmd globals / multiple compiler instances ("dmd as a library");
- a supported `Module.reparse`/`replace` API plus **stable symbol identity
  across edits** for instantiation inputs (`upstream.md` §6a, findings §11).

## Vendor-update checklist

Run on every dmd bump / `make vendor`. Each item is "verify, and if changed,
do X".

- [ ] **Patch series present.** The [upstream.md](upstream.md) series is
      applied in `../dmd` and copied verbatim; `src/dmd/` matches it. If a
      patch was dropped/rewritten, fix the consumer (`src/dmdwrap.d`) or the
      patch before shipping.
- [ ] **Reset surface.** Grep the vendored diff for new module-level mutable
      state (`__gshared`, `shared static`, function-local `static` caches). Any
      new universe-holding cache must be added to `deinitializeDMD` or
      `dmdResetGlobals` (see the reset-surface appendix in `findings.md`), or
      proven never to hold AST. This is how the `Identifier.stringtable` and
      `Module.deferred*` leaks were found.
- [ ] **`dmdReparseModule` field list.** `upstream.md` §6a lists the `Module`
      fields that must be cleared/reset for in-place re-parse. A new `Module`
      field that holds members, scope, imports or package state is a silent
      leak/stale-symbol bug: add it to `src/dmdwrap.d::dmdReparseModule` and
      re-run the in-process measurement.
- [ ] **Identifier reset.** `Identifier.deinitialize` + keyword
      re-registration still present and ordered correctly (`upstream.md` §3);
      losing it reintroduces unbounded identifier growth.
- [ ] **`Loc` checkpoint.** `Loc.checkpoint`/`rollback` still match
      `dmd.location` internals; `dmdLocCheckpoint` still cuts the per-parse
      file-copy growth.
- [ ] **Dedup keys.** `TemplateInstanceBox` (`arrayObjectHash` /
      `opEquals` / `equalsx`) is the residual in-process growth mechanism
      (`upstream.md` §6a). If upstream changes how instances are keyed or
      deduped, the in-place leak changes: re-measure before assuming parity.
- [ ] **Upstream landed a trigger?** Check release notes / PRs for region GC,
      precise root maps, `dmd.frontend`-as-library, reentrant globals, or a
      `Module` reparse/replace API. If so, open the corresponding trigger above
      and re-measure the shared-store plan (`PLAN2.md` Task 0).
- [ ] **Region GC prototype.** If `src/regiongc.d` is present/revived, confirm
      it still compiles against the vendored tree and still satisfies the
      druntime array **and** AA contract (`findings.md` §5.2); keep it behind
      `DMD_LSP_REGION_GC` until it has its own test suite.
- [ ] **Re-run the regression.** `tests/test_memory.py` (part of `make check`)
      must stay green. For the in-process path specifically, re-measure
      RSS/edit on `expressionsem.d` against the §11 baseline
      (~33–46 ms, ~5 MB/edit) — a jump means a reclamation invariant broke.

## Watch list

Upstream signals worth a look when they appear (log the outcome here):
incremental/reparsing APIs, `Module` lifecycle/replacement, dmd-as-library
efforts, GC/region work, and anything touching `TemplateInstance` caching or
`Identifier`/`Loc`/`StringTable` state. When one lands, update the triggers and
re-run Task 0 of `PLAN2.md` before changing any boundary.

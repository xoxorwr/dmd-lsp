# Reclamation: memory levels & vendor updates

Status: **decided.** The reclamation boundary is the **memory level**
([design.md](design.md#memory-levels), `src/layers.d`), in the server process.
The earlier decision — the process is the boundary, with a worker pool — is
superseded; the evidence for both is in [findings.md](findings.md) (§6/§11 for
the old one, §12 for levels).

## The invariants

Popping a level must leave the levels below byte for byte as they were at its
push. That holds when:

1. **Every write dmd makes to lower-level memory is captured.** Lower levels'
   GC pools are write-protected; the fault handler saves each page on first
   write. This needs no knowledge of dmd.
2. **All dmd memory is GC memory of a dmd level.** Memory from C `malloc` is
   not versioned (the `OutBuffer` patch, [upstream.md](upstream.md)); memory on
   level 0 is not protected, so dmd code only runs in dmd mode (`levelEnter`,
   `ops.d` `serveRequest`) and dmd's static-constructor state is rebuilt on
   level 1.
3. **Every mutable static of dmd is in the snapshot** (`src/dmdglobals.d`):
   reflection over `src/dmdmodules.d` plus the function-local list.
4. **Nothing outside dmd keeps a pointer into a level across its pop.** Results
   are serialised (JSON replies) or copied to level 0 (`levelSuspend`) first.
5. **druntime state tied to a heap is reset with it**: the array-append block
   cache, `Gcx.toscanRoots`, `Gcx.instance`.

A breach shows up as a dangling pointer (a crash, not a leak). `LAYERS_CHECK=1`
checks dmd's identifier table after every pop and around every op; it is the
first thing to run when a crash smells of a level.

## Vendor-update checklist

Run on every dmd bump / `make vendor`.

- [ ] **Module list.** `make vendor` regenerates `src/dmdmodules.d`
      (`tools/gen-dmdmodules.sh`). A module missing from it has unsnapshotted
      globals.
- [ ] **Function-local statics.** `make check-statics` compares the binary's
      mutable dmd function-local statics with the list in `src/dmdglobals.d`.
      Add new ones (mangled name + size); a changed signature changes the
      mangled name.
- [ ] **Patches applied.** `make vendor` applies `patches/` and stops if one
      fails; nothing else in `src/dmd/` may differ from stock
      ([vendoring.md](vendoring.md)).
- [ ] **New `malloc` users.** `grep -rn 'malloc(' src/dmd` for new direct C
      allocations whose result dmd keeps (a transient buffer freed in the same
      call is fine).
- [ ] **New static constructors.** `grep -rn 'static this' src/dmd`: state they
      build lives on level 0 and must be rebuilt on level 1 (`engine.d`
      `ensureInit`) if dmd mutates it later.
- [ ] **druntime.** On a compiler bump, re-check `ConservativeGC`'s lifecycle
      (`Gcx.Dtor` releasing all mappings, `toscanRoots`), the block cache
      (`core.internal.gc.blkcache`) and the `GC` interface `LayeredGC`
      implements.
- [ ] **Re-run.** `make check` (includes `tests/test_memory.py` and
      `tests/test_crash.py`), then `LAYERS_CHECK=1 python3
      tests/test_references.py` and the probe on a large file:
      `make probe && ./layers-probe <file> -I... --iters 30 --full 3` — RSS must
      stay flat and the dirty-page count identical across iterations.

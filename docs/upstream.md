# Upstream work

The vendored frontend (`src/dmd/`) is stock upstream `master` at the commit
recorded in [vendoring.md](vendoring.md), plus the patches in `patches/`:

- the LSP-only hacks H1, H2, H5, H6 ([hacks.md](hacks.md)), which are not meant for
  upstream;
- one allocator patch, below (`patches/outbuffer-mem.patch`), which is. It has
  not been submitted, and is not applied in `../dmd`.

The previous patch series (`deinitialize()` hooks, `Loc.checkpoint/rollback`,
`StringTable.removeWhere`/checkpoints, template-instance tracking, the
`merge2` eviction fallback, the scratch allocator, `Mem.enableZero`) existed to
reset or evict state inside one long-lived universe. Memory levels
([design.md](design.md#memory-levels)) roll back every mutation with the MMU
and restore globals from a snapshot, so none of it is needed and it was dropped.

## `OutBuffer`: allocate through `Mem` under `version (DMDLIB)`

**File**: `compiler/src/dmd/common/outbuffer.d`

**Problem**: `OutBuffer` is the one frontend container that allocates with C
`malloc`/`realloc`/`free` directly; everything else goes through `Mem`, which is
the GC when it is enabled. A library host that manages the frontend's memory
through the GC (to reclaim an analysis wholesale, or just to have one heap) sees
two kinds of memory with different lifetimes. Concretely here: a global
`OutBuffer` (`Lexer.stringbuffer`) reallocated during an analysis and then
restored from a snapshot pointed at a freed `malloc` chunk; and extracted
buffers (`extractSlice`, kept by the AST) leak outside any heap the host can
free.

**Fix**: under `version (DMDLIB)` (the library build), `pureMalloc`,
`pureRealloc` and `pureFree` in `outbuffer.d` forward to `Mem.xmalloc_noscan`,
`Mem.xrealloc_noscan` and `Mem.xfree`. The buffers hold no pointers, hence
`_noscan`. `Mem` is not `@nogc`, `OutBuffer` is; the calls are made through
function pointers typed `@nogc` — a typing concession, the buffers were never
GC-scanned. The pointer types must be `extern (C++)` like `Mem`'s statics (a
D-linkage pointer reverses the argument registers).

**Review notes**: it changes nothing for the compiler (no `DMDLIB`). A
maintainer may prefer a hook (`__gshared` allocator functions) over a version
switch; either works for this consumer. With the GC disabled (dmd's own
`main`), `Mem` falls back to `malloc`, so even an unconditional switch would be
behaviour-preserving for the compiler.

## Would help, not required

- Hoisting the ~30 function-local `static` caches (e.g.
  `typesem.getComplexLibraryType`, `arrayop.arrayOp`) to module scope would let
  reflection find them, replacing the mangled-name list in `src/dmdglobals.d`.
- A supported way to parse without registering (`Module.parseModule` does both;
  `dmdParseNoRegister` drives `Parser` itself).

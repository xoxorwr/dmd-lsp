# Vendoring

`src/dmd/` is stock upstream dmd — `../dmd-stock`, `master` at `fb655c9`
(source-identical to `4edd2c3f77`) — cut to the exact `-i` closure plus the two
string imports it needs (`VERSION`, `res/default_ddoc_theme.ddoc`), with the
patches in `patches/` applied:

| patch | what | doc |
|---|---|---|
| `h1-record-const-folds.patch` | `optimize.d` | [hacks.md](hacks.md) H1 |
| `h2-baseclass-loc.patch` | `dclass.d`, `dsymbolsem.d` | [hacks.md](hacks.md) H2 |
| `h5-keep-errored-bodies.patch` | `statementsem.d` | [hacks.md](hacks.md) H5 |
| `h6-record-ctfe-calls.patch` | `dinterpret.d` | [hacks.md](hacks.md) H6 |
| `outbuffer-mem.patch` | `common/outbuffer.d` | [upstream.md](upstream.md) |

No other file differs from stock. The build needs no dmd checkout; only the D
compiler's druntime/phobos are external.

This is packaging, **not a fork**: never edit `src/dmd/` directly. Change a
patch (edit the vendored file, then regenerate the patch against stock with
`diff -u`), or add one to `patches/` and document it.

## Cross-platform

The closure was derived on Linux/x86_64. Extras needed elsewhere:

- **Windows**: `root/strtold.d` (the MSVC `strtold` used by `root/ctfloat.d`
  under `version(CRuntime_Microsoft)`), listed in `PLATFORM_EXTRA` in the
  Makefile.
- **macOS/BSD**: no extra dmd modules; their code uses `core.sys.*` from
  druntime.
- `dmd/iasm.d` and `dmd/backend/symbol.d` are intentionally absent: the
  build sets `-version=NoBackend`, so those imports are compiled out.

`dmd-lsp` is a single process on every platform; the memory levels protect
pages with `mprotect` + a SIGSEGV handler on POSIX and `VirtualProtect` + a
vectored exception handler on Windows.

## Refreshing

```sh
make vendor                  # from ../dmd-stock: copy the closure, apply patches/, regenerate src/dmdmodules.d
make vendor DMD_DIR=~/dmd    # from another checkout
make vendor BRANCH=master    # a ref of $(DMD_DIR), via a temporary worktree
make check-statics           # the function-local statics list in src/dmdglobals.d is complete
```

A patch that no longer applies stops the vendor step; refresh it against the
new stock file and re-check its behaviour (`make check`).

**Always run the [reclamation.md](reclamation.md) vendor-update checklist after
a refresh**: a new global or a new `malloc` user in dmd is what can break a
memory level.

## Makefile

```sh
make                # builds ./dmd-lsp (from the vendored src/dmd/)
make check          # struct-only guard + batch fixtures + LSP regression suite
make check-no-oop   # guard: src/ (outside the vendor) has no class/interface
make check-statics  # guard: every mutable dmd function-local static is snapshotted
make probe          # tests/layers_probe.d: level push/pop timing and RSS on a file
make deps           # audit exactly which dmd modules got pulled in
make vendor         # re-copy the closure from ../dmd-stock and apply patches/
make clean
```

- Build uses `dmd -i`: only transitively-imported frontend modules compile,
  no backend/glue.
- Compiler is overridable: `make DC=ldmd2` builds with LDC's dmd-compatible
  driver (smaller binary; the LDC frontend must be new enough to compile
  `src/dmd`).
- Needs `stringimp/SYSCONFDIR.imp` (present) and the `-J` paths set in the
  Makefile.

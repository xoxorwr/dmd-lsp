# Vendoring

`src/dmd/` is a snapshot of `../dmd/compiler/src/dmd` (branch `lsp-fixes`:
upstream `master` + the patches in [upstream.md](upstream.md)) containing the
exact `-i` closure plus the two string imports it needs (`VERSION`,
`res/default_ddoc_theme.ddoc`): **146 files, ~6.9 MB**. It carries the fixes
listed in [upstream.md](upstream.md), so the build needs no `../dmd` at all —
only the D compiler's druntime/phobos are external.

This is packaging, **not a fork**: do not edit files under `src/dmd/`. Fix
in `../dmd` (with permission), then re-copy. The one exception is the
tooling-only hacks listed in [hacks.md](hacks.md); those are edited in place
and are lost (loudly) on the next `make vendor`.

The set is exactly what the frontend imports (nothing extra to strip).

## Cross-platform

The closure was derived on Linux/x86_64. Extras needed elsewhere:

- **Windows**: `root/strtold.d` (the MSVC `strtold` used by `root/ctfloat.d`
  under `version(CRuntime_Microsoft)`), listed in `PLATFORM_EXTRA` in the
  Makefile.
- **macOS/BSD**: no extra dmd modules; their code uses `core.sys.*` from
  druntime.
- `dmd/iasm.d` and `dmd/backend/symbol.d` are intentionally absent: the
  build sets `-version=NoBackend`, so those imports are compiled out.

`dmd-lsp` is cross-platform: on POSIX the worker is `fork()`ed; on Windows it
is spawned via `CreateProcess` with `--worker` and the stdio loop waits on the
stdin handle.

## Refreshing

```sh
make vendor   # re-derive the closure from ../dmd and re-copy (+ PLATFORM_EXTRA)
```

Run it after pulling the dev tree. Once the patches land upstream, delete
`src/dmd/`, point `-I` at `../dmd/compiler/src` again, and drop `make vendor`.

## Makefile

```sh
make              # builds ./dmd-lsp (from the vendored src/dmd/)
make check        # struct-only guard + batch fixtures + LSP regression suite
make check-no-oop # guard: src/ (outside the vendor) has no class/interface
make deps         # audit exactly which dmd modules got pulled in
make vendor       # re-copy the frontend closure from ../dmd
make clean
```

- Build uses `dmd -i`: only transitively-imported frontend modules compile,
  no backend/glue.
- Compiler is overridable: `make DC=ldmd2` builds with LDC's dmd-compatible
  driver (smaller binary; the LDC frontend must be new enough to compile
  `src/dmd`).
- Needs `stringimp/SYSCONFDIR.imp` (present) and the `-J` paths set in the
  Makefile.

# dmd-lsp (VS Code)

Minimal VS Code client for the `dmd-lsp` language server: D syntax
highlighting, diagnostics, completion, signature help and
unused-import/parameter hints, all computed with the real `dmd` frontend.

## Install

Install the `dmd-lsp.vsix` from the
[nightly release](https://github.com/xoxorwr/dmd-lsp/releases/tag/nightly)
(`Extensions: Install from VSIX…`).

On first activation the extension downloads the `dmd-lsp` binary for your
platform (Linux x64, macOS arm64/x64) into the extension's global storage.
Set `dmdLsp.serverPath` to use a local build instead.

> Windows is not supported yet: the server's worker and stdio loop are
> POSIX-only.

## Settings

| Setting | Meaning |
|---|---|
| `dmdLsp.serverPath` | Path to the `dmd-lsp` binary; empty = download nightly |
| `dmdLsp.importPaths` | Module import paths (`-I`) |
| `dmdLsp.stringImportPaths` | String import paths (`-J`) |
| `dmdLsp.flags` | Extra dmd flags, e.g. `-preview=rvaluerefparam` |
| `dmdLsp.debounceMs` | Diagnostics idle delay (default 300) |

Project defaults belong in `dls.json` at the workspace root; it is read by
the server and overrides these per-run.

## Build

```sh
npm install
npm run compile
npm run package   # -> dmd-lsp.vsix
```

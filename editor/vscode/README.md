# dmd-lsp (VS Code)

Minimal VS Code client for the `dmd-lsp` language server: D syntax
highlighting, diagnostics, completion, signature help and
unused-import/parameter hints, all computed with the real `dmd` frontend.

## Install

Install the `dmd-lsp.vsix` from the
[nightly release](https://github.com/xoxorwr/dmd-lsp/releases/tag/nightly)
(`Extensions: Install from VSIX…`).

On first activation the extension downloads the `dmd-lsp` binary for your
platform (Linux x64, macOS arm64/x64, Windows x64) into the extension's
global storage.
Set `dmdLsp.serverPath` to use a local build instead.

The binary is refreshed automatically: on each activation the extension
fetches the nightly release's `SHA256SUMS` (a few hundred bytes) and
re-downloads only when the hash changed. If the release can't be reached
it falls back to the cached binary. Disable with `dmdLsp.autoUpdate`
= `false`.

> On Windows the server is a `.exe`; the extension picks
> `dmd-lsp-win-x64.zip` automatically.

## Settings

| Setting | Meaning |
|---|---|
| `dmdLsp.serverPath` | Path to the `dmd-lsp` binary; empty = download nightly |
| `dmdLsp.autoUpdate` | Re-download the binary when the nightly changed (default true) |
| `dmdLsp.importPaths` | Module import paths (`-I`) |
| `dmdLsp.stringImportPaths` | String import paths (`-J`) |
| `dmdLsp.flags` | Extra dmd flags, e.g. `-preview=rvaluerefparam` |
| `dmdLsp.debounceMs` | Diagnostics idle delay (default 300) |

Project defaults belong in `dls.json` at the workspace root; it is read by
the server and overrides these per-run.

## Commands

- **dmd-lsp: Create dls.json** — writes a starter `dls.json` at the
  workspace root (seeding `importPaths` from `src/`, `source/`, `sandbox/`
  when they exist, plus any `dmdLsp.*` settings) and restarts the server so
  it takes effect. If the file already exists it is just opened.

## Build

```sh
npm install
npm run compile
npm run package   # -> dmd-lsp.vsix
```

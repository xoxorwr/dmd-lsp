# Releases & editor integration

## Nightly builds

**[Grab the latest prebuilt →](https://github.com/xoxorwr/dmd-lsp/releases/tag/nightly)**
(download the tarball for your platform, or `dmd-lsp.vsix` for VS Code).

`.github/workflows/nightly.yml` builds a rolling prerelease tagged
`nightly` (LDC `ldmd2`), on a schedule (06:00 UTC), on push to `master`, and
on manual dispatch. Asset names are stable so clients can fetch and verify:

- `dmd-lsp-linux-x64.tar.gz`
- `dmd-lsp-darwin-arm64.tar.gz`
- `dmd-lsp-darwin-x64.tar.gz`
- `dmd-lsp.vsix` (VS Code extension)
- `SHA256SUMS`

Each archive contains the `dmd-lsp` binary at its root. Download base:

```
https://github.com/<owner>/<repo>/releases/download/nightly/<asset>
```

macOS runners: `macos-15` (arm64) and `macos-15-intel` (x64). Windows is not
built — the worker and stdio loop are POSIX-only, so a Windows binary would
not run.

## VS Code extension

[`editor/vscode/`](../editor/vscode/) is a minimal client,
[`vscode-languageclient`](https://www.npmjs.com/package/vscode-languageclient)
started over stdio. It also contributes the D syntax grammar.

On first activation it downloads the platform binary into the extension's
global storage. On each later activation it fetches the release's
`SHA256SUMS` and re-downloads only when the hash changed (disable with
`dmdLsp.autoUpdate: false`); if the release is unreachable it falls back to
the cached binary. `dmdLsp.serverPath` bypasses all of it.

Settings (`settings.json`): `dmdLsp.serverPath`, `dmdLsp.autoUpdate`,
`dmdLsp.importPaths`, `dmdLsp.stringImportPaths`, `dmdLsp.flags`,
`dmdLsp.debounceMs`. Project truth lives in `dls.json` at the workspace root
(see [usage](../README.md#usage)); the command **dmd-lsp: Create dls.json**
writes a starter file and restarts the server.

Build the extension locally:

```sh
cd editor/vscode
npm ci
npm run compile   # tsc --noEmit + esbuild bundle
npm run package   # -> dmd-lsp.vsix
```

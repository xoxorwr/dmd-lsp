import * as vscode from 'vscode';
import * as fs from 'fs';
import * as path from 'path';
import * as https from 'https';
import { execFile } from 'child_process';

const REPO = 'xoxorwr/dmd-lsp';
const TAG = 'nightly';

// dmd-lsp is POSIX-only (fork/socketpair worker); Windows must supply its
// own binary via dmdLsp.serverPath.
function assetName(): string | undefined {
  if (process.platform === 'linux' && process.arch === 'x64') {
    return 'dmd-lsp-linux-x64.tar.gz';
  }
  if (process.platform === 'darwin' && process.arch === 'arm64') {
    return 'dmd-lsp-darwin-arm64.tar.gz';
  }
  if (process.platform === 'darwin' && process.arch === 'x64') {
    return 'dmd-lsp-darwin-x64.tar.gz';
  }
  return undefined;
}

export async function ensureServer(
  context: vscode.ExtensionContext,
  config: vscode.WorkspaceConfiguration,
): Promise<string> {
  const configured = (config.get<string>('serverPath', '') || '').trim();
  if (configured) {
    return configured;
  }

  const asset = assetName();
  if (!asset) {
    throw new Error(
      `no prebuilt dmd-lsp for ${process.platform}/${process.arch}; ` +
        `set "dmdLsp.serverPath" to a local build.`,
    );
  }

  const dir = context.globalStorageUri.fsPath;
  const bin = path.join(dir, 'dmd-lsp');
  if (fs.existsSync(bin)) {
    return bin;
  }

  fs.mkdirSync(dir, { recursive: true });
  const url = `https://github.com/${REPO}/releases/download/${TAG}/${asset}`;
  const tarball = path.join(dir, asset);

  await vscode.window.withProgress(
    { location: vscode.ProgressLocation.Notification, title: `Downloading dmd-lsp (${asset})` },
    async () => {
      await download(url, tarball);
      await extract(tarball, dir);
      fs.chmodSync(bin, 0o755);
      fs.rmSync(tarball, { force: true });
    },
  );
  return bin;
}

function download(url: string, dest: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const follow = (target: string, redirects: number): void => {
      if (redirects > 5) {
        reject(new Error('too many redirects'));
        return;
      }
      https
        .get(target, (res) => {
          const status = res.statusCode ?? 0;
          if (status >= 300 && status < 400 && res.headers.location) {
            res.resume();
            follow(res.headers.location, redirects + 1);
            return;
          }
          if (status !== 200) {
            res.resume();
            reject(new Error(`download failed: HTTP ${status} for ${target}`));
            return;
          }
          const out = fs.createWriteStream(dest);
          res.pipe(out);
          out.on('finish', () => out.close(() => resolve()));
          out.on('error', reject);
        })
        .on('error', reject);
    };
    follow(url, 0);
  });
}

function extract(tarball: string, dest: string): Promise<void> {
  return new Promise((resolve, reject) => {
    execFile('tar', ['-xzf', tarball, '-C', dest], (err) =>
      err ? reject(err) : resolve(),
    );
  });
}

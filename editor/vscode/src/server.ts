import * as vscode from 'vscode';
import * as fs from 'fs';
import * as path from 'path';
import * as http from 'http';
import * as https from 'https';
import { execFile } from 'child_process';

const REPO = 'xoxorwr/dmd-lsp';
const TAG = 'nightly';

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
  if (process.platform === 'win32' && process.arch === 'x64') {
    return 'dmd-lsp-win-x64.zip';
  }
  return undefined;
}

function binaryName(): string {
  return process.platform === 'win32' ? 'dmd-lsp.exe' : 'dmd-lsp';
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
  const bin = path.join(dir, binaryName());
  const stamp = path.join(dir, 'dmd-lsp.sha256');
  fs.mkdirSync(dir, { recursive: true });
  const have = fs.existsSync(bin);

  // `SHA256SUMS` is a few hundred bytes; a cheap freshness check per
  // activation. Offline or rate-limited? fall back to the cached binary.
  let expected: string | undefined;
  if (config.get<boolean>('autoUpdate', true)) {
    expected = await fetchExpectedSha(asset).catch(() => undefined);
    if (have) {
      if (!expected) {
        return bin;
      }
      const current = fs.existsSync(stamp) ? fs.readFileSync(stamp, 'utf8').trim() : '';
      if (current === expected) {
        return bin;
      }
    }
  } else if (have) {
    return bin;
  }

  const url = `https://github.com/${REPO}/releases/download/${TAG}/${asset}`;
  const tarball = path.join(dir, asset);
  await vscode.window.withProgress(
    {
      location: vscode.ProgressLocation.Notification,
      title: `Downloading dmd-lsp (${asset})`,
    },
    async () => {
      await download(url, tarball);
      await extract(tarball, dir);
      if (process.platform !== 'win32') {
        fs.chmodSync(bin, 0o755);
      }
      fs.rmSync(tarball, { force: true });
      if (expected) {
        fs.writeFileSync(stamp, expected + '\n', 'utf8');
      } else {
        fs.rmSync(stamp, { force: true });
      }
    },
  );
  return bin;
}

// Hash of our nightly archive from the release's SHA256SUMS, if present.
async function fetchExpectedSha(asset: string): Promise<string | undefined> {
  const url = `https://github.com/${REPO}/releases/download/${TAG}/SHA256SUMS`;
  const body = await fetchText(url);
  for (const line of body.split('\n')) {
    const m = line.trim().split(/\s+/);
    if (m.length >= 2 && m[1] === asset) {
      return m[0].toLowerCase();
    }
  }
  return undefined;
}

function httpGet(url: string): Promise<http.IncomingMessage> {
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
            reject(new Error(`HTTP ${status} for ${target}`));
            return;
          }
          resolve(res);
        })
        .on('error', reject);
    };
    follow(url, 0);
  });
}

function download(url: string, dest: string): Promise<void> {
  return httpGet(url).then(
    (res) =>
      new Promise<void>((resolve, reject) => {
        const out = fs.createWriteStream(dest);
        res.pipe(out);
        out.on('finish', () => out.close(() => resolve()));
        out.on('error', reject);
      }),
  );
}

function fetchText(url: string): Promise<string> {
  return httpGet(url).then(
    (res) =>
      new Promise<string>((resolve, reject) => {
        const chunks: Buffer[] = [];
        res.on('data', (c: Buffer) => chunks.push(c));
        res.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
        res.on('error', reject);
      }),
  );
}

function extract(archive: string, dest: string): Promise<void> {
  const [cmd, args] =
    process.platform === 'win32'
      ? [
          'powershell',
          [
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            `Expand-Archive -Force -LiteralPath '${archive}' -DestinationPath '${dest}'`,
          ],
        ]
      : ['tar', ['-xzf', archive, '-C', dest]];
  return new Promise((resolve, reject) => {
    execFile(cmd, args, (err) => (err ? reject(err) : resolve()));
  });
}

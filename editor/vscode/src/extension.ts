import * as vscode from 'vscode';
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
} from 'vscode-languageclient/node';
import { ensureServer } from './server';
import { createDlsJson } from './config';

let client: LanguageClient | undefined;

export async function activate(context: vscode.ExtensionContext): Promise<void> {
  context.subscriptions.push(
    vscode.commands.registerCommand('dmdLsp.createConfig', async () => {
      const created = await createDlsJson();
      // The server reads dls.json at initialize (and on its save); restart
      // so a freshly created file takes effect immediately.
      if (created && client) {
        await client.stop();
        await client.start();
      }
    }),
  );

  const config = vscode.workspace.getConfiguration('dmdLsp');

  let serverPath: string;
  try {
    serverPath = await ensureServer(context, config);
  } catch (err) {
    void vscode.window.showErrorMessage(
      `dmd-lsp: ${err instanceof Error ? err.message : String(err)}`,
    );
    return;
  }

  const args = ['--stdio'];
  for (const p of config.get<string[]>('importPaths', [])) {
    args.push(`--import=${p}`);
  }
  for (const p of config.get<string[]>('stringImportPaths', [])) {
    args.push(`--string-import=${p}`);
  }
  for (const f of config.get<string[]>('flags', [])) {
    args.push(`--flag=${f}`);
  }
  args.push(`--debounce-ms=${config.get<number>('debounceMs', 300)}`);

  const serverOptions: ServerOptions = { command: serverPath, args };
  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: 'file', language: 'd' }],
  };

  client = new LanguageClient('dmd-lsp', 'dmd-lsp', serverOptions, clientOptions);
  context.subscriptions.push(client);
  await client.start();
}

export function deactivate(): Thenable<void> | undefined {
  return client?.stop();
}

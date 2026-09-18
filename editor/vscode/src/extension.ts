import * as vscode from 'vscode';
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
} from 'vscode-languageclient/node';
import { ensureServer } from './server';
import { createDlsJson } from './config';

let client: LanguageClient | undefined;

// The static language-configuration.json gives the defaults (comment toggling,
// bracket pairs); this re-applies it at runtime so `dmdLsp.autoCloseBrackets`
// can turn auto-closing off without touching VS Code's own `editor.*` settings.
// `notIn` is plain strings in the JSON config; pass them through unchanged
// (older VS Code has no runtime SyntaxTokenType enum).
function notIn(...tokens: string[]): vscode.SyntaxTokenType[] {
  return tokens as unknown as vscode.SyntaxTokenType[];
}

function applyLanguageConfiguration(): void {
  const autoClose = vscode.workspace
    .getConfiguration('dmdLsp')
    .get<boolean>('autoCloseBrackets', true);
  const pairs: vscode.AutoClosingPair[] = [
    { open: '{', close: '}' },
    { open: '[', close: ']' },
    { open: '(', close: ')' },
    { open: '"', close: '"', notIn: notIn('string', 'comment') },
    { open: "'", close: "'", notIn: notIn('string', 'comment') },
    { open: '`', close: '`', notIn: notIn('string', 'comment') },
    { open: '/*', close: ' */', notIn: notIn('string') },
  ];
  vscode.languages.setLanguageConfiguration('d', {
    comments: { lineComment: '//', blockComment: ['/*', '*/'] },
    brackets: [
      ['{', '}'],
      ['[', ']'],
      ['(', ')'],
    ],
    autoClosingPairs: autoClose ? pairs : [],
  });
}

export async function activate(context: vscode.ExtensionContext): Promise<void> {
  applyLanguageConfiguration();
  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration('dmdLsp.autoCloseBrackets')) {
        applyLanguageConfiguration();
      }
    }),
  );

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
  args.push(`--debounce-ms=${config.get<number>('debounceMs', 500)}`);

  // Run the server in the workspace root so relative import paths (and the
  // dep paths dmd reports for goto-definition) resolve correctly.
  const cwd = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
  const serverOptions: ServerOptions = {
    command: serverPath,
    args,
    options: cwd ? { cwd } : undefined,
  };
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

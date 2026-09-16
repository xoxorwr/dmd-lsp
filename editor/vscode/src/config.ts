import * as vscode from 'vscode';
import * as fs from 'fs';
import * as path from 'path';

// Directories that commonly hold D sources; probed to seed `importPaths`.
const IMPORT_CANDIDATES = ['src', 'source', 'sandbox'];

// Write a starter dls.json at the workspace root. Returns true when the
// file was created (false when it already existed and was just opened).
export async function createDlsJson(): Promise<boolean> {
  const folder = vscode.workspace.workspaceFolders?.[0];
  if (!folder) {
    void vscode.window.showErrorMessage('dmd-lsp: open a folder or workspace first.');
    return false;
  }

  const root = folder.uri.fsPath;
  const file = path.join(root, 'dls.json');

  if (fs.existsSync(file)) {
    await open(file);
    void vscode.window.showInformationMessage('dmd-lsp: dls.json already exists.');
    return false;
  }

  const config = vscode.workspace.getConfiguration('dmdLsp');
  const settingImports = config.get<string[]>('importPaths', []);
  const stringImports = config.get<string[]>('stringImportPaths', []);
  const flags = config.get<string[]>('flags', []);
  const debounceMs = config.get<number>('debounceMs', 500);

  const cfg: Record<string, unknown> = {
    importPaths: settingImports.length ? settingImports : detectImports(root),
  };
  if (stringImports.length) {
    cfg.stringImportPaths = stringImports;
  }
  if (flags.length) {
    cfg.flags = flags;
  }
  if (debounceMs !== 500) {
    cfg.debounceMs = debounceMs;
  }

  fs.writeFileSync(file, JSON.stringify(cfg, null, 4) + '\n', 'utf8');
  await open(file);
  void vscode.window.showInformationMessage('dmd-lsp: created dls.json.');
  return true;
}

function detectImports(root: string): string[] {
  const found = IMPORT_CANDIDATES.filter((d) => fs.existsSync(path.join(root, d)));
  return (found.length ? found : ['src']).map((d) => `${d}/`);
}

async function open(file: string): Promise<void> {
  const doc = await vscode.workspace.openTextDocument(file);
  await vscode.window.showTextDocument(doc);
}

import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

import * as vscode from 'vscode';

const execFileAsync = promisify(execFile);
const OPENBURNBAR_MACOS_BUNDLE_ID = 'com.openburnbar.app';

export type OpenBurnBarAppLaunchTarget = 'dashboard' | 'search';

export async function openBurnBarApp(target: OpenBurnBarAppLaunchTarget): Promise<void> {
  if (process.platform !== 'darwin') {
    throw new Error('OpenBurnBar app launching is currently supported on macOS only.');
  }

  const urls = target === 'search' ? ['openburnbar://search', 'openburnbar://dashboard'] : ['openburnbar://dashboard'];

  for (const url of urls) {
    try {
      await execFileAsync('open', [url]);
      return;
    } catch {
      // Try the next launch target before falling back to the bundle open.
    }
  }

  await execFileAsync('open', ['-b', OPENBURNBAR_MACOS_BUNDLE_ID]);
}

export async function openBurnBarAppOrWarn(target: OpenBurnBarAppLaunchTarget, missingMessage: string): Promise<void> {
  try {
    await openBurnBarApp(target);
  } catch {
    void vscode.window.showWarningMessage(missingMessage);
  }
}

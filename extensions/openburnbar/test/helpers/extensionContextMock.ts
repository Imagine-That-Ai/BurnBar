import * as vscode from 'vscode';

import type { OpenBurnBarActivationHostContext } from '../../src/extension';

export function createExtensionContextMock(): OpenBurnBarActivationHostContext {
  const subscriptions: Array<{ dispose(): void }> = [];
  return {
    subscriptions,
    globalState: {
      get: () => undefined,
      update: async () => undefined
    },
    extensionUri: vscode.Uri.file('/test'),
    extension: {
      extensionKind: vscode.ExtensionKind.UI
    }
  };
}

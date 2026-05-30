/**
 * OpenBurnBar Webview Panel
 *
 * Handles the main webview lifecycle for the OpenBurnBar sidebar panel.
 */

import * as vscode from 'vscode';
import * as workspace from './workspace';

/**
 * Webview panel for OpenBurnBar workspace operations.
 */
interface OpenBurnBarPanelLike {
  webview: vscode.Webview;
  title: string;
  visible: boolean;
  onDidChangeViewState: vscode.Event<vscode.WebviewPanelOnDidChangeViewStateEvent>;
  onDidDispose: vscode.Event<void>;
}

export class OpenBurnBarPanel {
  private readonly extensionUri: vscode.Uri;
  private readonly webview: OpenBurnBarPanelLike;
  private disposables: vscode.Disposable[] = [];

  constructor(extensionUri: vscode.Uri, webview: OpenBurnBarPanelLike) {
    this.extensionUri = extensionUri;
    this.webview = webview;

    this.initializeWebview();
    this.setupPanelEvents();
  }

  /**
   * Initialize the webview with content and scripts.
   */
  private initializeWebview(): void {
    this.webview.webview.options = {
      enableScripts: true,
      localResourceRoots: [this.extensionUri]
    };

    this.webview.webview.html = this.getHtmlContent();

    // Listen for messages from the webview
    this.webview.webview.onDidReceiveMessage(
      (message: { type: string; payload?: unknown }) => {
        this.handleWebviewMessage(message);
      },
      undefined,
      this.disposables
    );
  }

  /**
   * Set up panel lifecycle event handlers.
   */
  private setupPanelEvents(): void {
    this.webview.onDidChangeViewState(
      (e: vscode.WebviewPanelOnDidChangeViewStateEvent) => {
        if (e.webviewPanel.visible) {
          workspace.requestInitialState();
        }
      },
      undefined,
      this.disposables
    );

    this.webview.onDidDispose(
      () => {
        this.dispose();
      },
      undefined,
      this.disposables
    );
  }

  /**
   * Handle messages from the webview.
   */
  private handleWebviewMessage(message: { type: string; payload?: unknown }): void {
    switch (message.type) {
      case 'workspace.requestState':
        vscode.commands.executeCommand('openburnbar.requestState');
        break;

      case 'workspace.selectRun': {
        const payload = runIDPayload(message.payload);
        if (!payload) {
          return;
        }
        vscode.commands.executeCommand('openburnbar.selectRun', payload.runId);
        break;
      }

      case 'workspace.viewRun': {
        const payload = runIDPayload(message.payload);
        if (!payload) {
          return;
        }
        vscode.commands.executeCommand('openburnbar.viewRun', payload.runId);
        break;
      }

      case 'workspace.cancelRun': {
        const payload = runIDPayload(message.payload);
        if (!payload) {
          return;
        }
        vscode.commands.executeCommand('openburnbar.cancelRun', payload.runId);
        break;
      }

      case 'workspace.retryRun': {
        const payload = runIDPayload(message.payload);
        if (!payload) {
          return;
        }
        vscode.commands.executeCommand('openburnbar.retryRun', payload.runId);
        break;
      }

      case 'workspace.executeTool': {
        const payload = executeToolPayload(message.payload);
        if (!payload) {
          return;
        }
        vscode.commands.executeCommand('openburnbar.executeTool', payload.tool, payload.args);
        break;
      }

      default:
        console.warn('Unknown webview message type:', message.type);
    }
  }

  /**
   * Post a message to the webview.
   */
  postMessage(type: string, payload?: unknown): void {
    this.webview.webview.postMessage({ type, payload });
  }

  /**
   * Update the panel title.
   */
  setTitle(title: string): void {
    this.webview.title = title;
  }

  /**
   * Show an error message in the webview.
   */
  showError(message: string): void {
    this.postMessage('workspace.error', { message });
  }

  /**
   * Generate the HTML content for the webview.
   */
  private getHtmlContent(): string {
    const stylesUri = this.webview.webview.asWebviewUri(vscode.Uri.joinPath(this.extensionUri, 'media', 'styles.css'));
    const workspaceScriptUri = this.webview.webview.asWebviewUri(
      vscode.Uri.joinPath(this.extensionUri, 'dist', 'workspace.js')
    );

    return /* html */ `
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline';">
  <link rel="stylesheet" href="${stylesUri}">
  <title>OpenBurnBar</title>
</head>
<body>
  <div class="openburnbar-app">
    <header class="openburnbar-header">
      <h1>OpenBurnBar</h1>
      <div class="connection-status" id="connection-status">
        <span class="status-dot status-dot--disconnected"></span>
        <span class="status-text">Disconnected</span>
      </div>
    </header>

    <main class="openburnbar-main">
      <aside class="runs-sidebar" id="runs-list"></aside>
      <section class="run-detail" id="run-detail">
        <div id="empty-state" class="empty-state">
          <p>No runs yet. Start an agent session to see usage here.</p>
        </div>
      </section>
    </main>

    <footer class="openburnbar-footer">
      <button class="btn btn-text" id="settings-btn">Settings</button>
      <button class="btn btn-text" id="help-btn">Help</button>
    </footer>
  </div>

  <script src="${workspaceScriptUri}"></script>
</body>
</html>
    `;
  }

  /**
   * Clean up resources.
   */
  dispose(): void {
    this.disposables.forEach((d) => d.dispose());
    this.disposables = [];
  }
}

/**
 * Register the webview panel provider.
 */
export function registerPanelProvider(context: vscode.ExtensionContext): void {
  context.subscriptions.push(
    vscode.window.registerWebviewViewProvider(
      'openburnbar.workspace',
      new (class implements vscode.WebviewViewProvider {
        resolveWebviewView(
          webviewView: vscode.WebviewView,
          _context: vscode.WebviewViewResolveContext,
          _token: vscode.CancellationToken
        ): void {
          webviewView.webview.options = {
            enableScripts: true
          };

          const panel = new OpenBurnBarPanel(context.extensionUri, {
            webview: webviewView.webview,
            title: 'OpenBurnBar',
            visible: true,
            onDidChangeViewState: new vscode.EventEmitter<vscode.WebviewPanelOnDidChangeViewStateEvent>().event,
            onDidDispose: new vscode.EventEmitter<void>().event
          });

          webviewView.onDidDispose(() => panel.dispose(), undefined, context.subscriptions);
        }
      })()
    )
  );
}

function runIDPayload(payload: unknown): { runId: string } | undefined {
  if (!isRecord(payload) || typeof payload.runId !== 'string') {
    return undefined;
  }
  return { runId: payload.runId };
}

function executeToolPayload(payload: unknown): { tool: string; args: unknown } | undefined {
  if (!isRecord(payload) || typeof payload.tool !== 'string') {
    return undefined;
  }
  return { tool: payload.tool, args: payload.args };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

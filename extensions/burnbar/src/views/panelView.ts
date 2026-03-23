import { randomBytes } from "node:crypto";
import * as vscode from "vscode";
import { BurnBarExtensionController } from "../state/controller";
import { buildPanelViewModel } from "../state/panelViewModel";
import type { BurnBarJSONValue } from "../types";
import type { BurnBarPanelWebviewMessage } from "./panelProtocol";
import { buildPanelHtml } from "./panelHtml";

export class BurnBarPanelView implements vscode.WebviewViewProvider {
  public static readonly viewType = "burnbar.panel";

  private view?: vscode.WebviewView;
  private stateSubscription?: { dispose(): void };

  constructor(
    private readonly controller: BurnBarExtensionController,
    private readonly extensionUri: vscode.Uri
  ) {}

  resolveWebviewView(
    webviewView: vscode.WebviewView,
    _context: vscode.WebviewViewResolveContext,
    _token: vscode.CancellationToken
  ): void {
    this.view = webviewView;
    this.stateSubscription?.dispose();

    webviewView.webview.options = {
      enableScripts: true,
      localResourceRoots: [this.extensionUri]
    };

    const cssUri = webviewView.webview.asWebviewUri(
      vscode.Uri.joinPath(this.extensionUri, "src", "webview", "panel.css")
    );
    const jsUri = webviewView.webview.asWebviewUri(
      vscode.Uri.joinPath(this.extensionUri, "src", "webview", "panel.js")
    );
    const nonce = generateNonce();

    webviewView.webview.html = buildPanelHtml(webviewView.webview, cssUri, jsUri, nonce);

    // Post initial snapshot
    this.postSnapshot();

    // Re-post on every state change
    this.stateSubscription = this.controller.onDidChangeState(() => {
      this.postSnapshot();
    });

    // Clean up subscription when view is disposed
    webviewView.onDidDispose(() => {
      this.stateSubscription?.dispose();
      this.stateSubscription = undefined;
      this.view = undefined;
    });

    // Handle incoming messages from webview
    webviewView.webview.onDidReceiveMessage((message: BurnBarPanelWebviewMessage) => {
      void this.handleWebviewMessage(message);
    });
  }

  dispose(): void {
    this.stateSubscription?.dispose();
    this.stateSubscription = undefined;
  }

  private postSnapshot(): void {
    if (!this.view) {
      return;
    }
    const viewModel = buildPanelViewModel(this.controller.snapshot);
    void this.view.webview.postMessage({ type: "snapshot", viewModel });
  }

  private async handleWebviewMessage(message: BurnBarPanelWebviewMessage): Promise<void> {
    try {
      switch (message.type) {
        case "startRun":
          const metadata: Record<string, BurnBarJSONValue> = { mode: message.mode };
          const activeEditor = vscode.window.activeTextEditor;
          if (activeEditor?.document) {
            const document = activeEditor.document;
            const workspaceFolder = vscode.workspace.getWorkspaceFolder(document.uri);
            metadata.activeFilePath = workspaceFolder
              ? vscode.workspace.asRelativePath(document.uri, false)
              : document.uri.fsPath;

            const selectedText = document.getText(activeEditor.selection).trim();
            if (selectedText) {
              metadata.activeSelectionText = selectedText;
            }
          }

          await this.controller.startRun({
            prompt: message.prompt,
            modelID: message.modelID,
            metadata
          });
          break;
        case "refresh":
          await this.controller.refresh();
          break;
        case "repair":
          await this.controller.repairDaemon();
          break;
        case "selectRun":
          await this.controller.selectRun(message.runId);
          break;
        case "cancelRun":
          await this.controller.cancelRun(message.runId);
          break;
        case "retryRun":
          await this.controller.retryRun(message.runId);
          break;
        case "approveRun":
          await this.controller.respondToApproval(message.runId, "approve");
          break;
        case "rejectRun":
          await this.controller.respondToApproval(message.runId, "reject");
          break;
      }
    } catch (error) {
      if (this.view) {
        void this.view.webview.postMessage({
          type: "error",
          message: error instanceof Error ? error.message : "BurnBar encountered an unexpected error."
        });
      }
    }
  }
}

function generateNonce(): string {
  return randomBytes(16).toString("hex");
}

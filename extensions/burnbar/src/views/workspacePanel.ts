import { randomBytes } from "node:crypto";

import * as vscode from "vscode";
import { openBurnBarAppOrWarn } from "../host/openBurnBarApp";
import { BurnBarExtensionController } from "../state/controller";
import { buildPanelViewModel } from "../state/panelViewModel";
import type { BurnBarJSONValue } from "../types";
import type { BurnBarWorkspaceWebviewMessage } from "./panelProtocol";
import { buildWorkspaceHtml } from "./workspaceHtml";

/**
 * Singleton editor-pane workspace panel.
 *
 * Opens in the main editor area (not the sidebar). Provides the full
 * BurnBar dashboard experience: Command, Runs, and System sections
 * with a contextual inspector. Shares the same controller/store as
 * the sidebar so both surfaces stay in sync.
 */
export class BurnBarWorkspacePanel implements vscode.Disposable {
  public static readonly viewType = "burnbar.workspace";

  private static instance: BurnBarWorkspacePanel | undefined;

  private panel: vscode.WebviewPanel | undefined;
  private stateSubscription: { dispose(): void } | undefined;
  private lastSection: "command" | "runs" | "system" = "command";
  private disposed = false;

  private constructor(
    private readonly controller: BurnBarExtensionController,
    private readonly extensionUri: vscode.Uri
  ) {}

  /**
   * Open the workspace panel as a singleton. If it already exists,
   * reveal it and preserve the user's current section.
   */
  static open(
    controller: BurnBarExtensionController,
    extensionUri: vscode.Uri
  ): BurnBarWorkspacePanel {
    if (BurnBarWorkspacePanel.instance?.panel) {
      BurnBarWorkspacePanel.instance.panel.reveal(undefined, true);
      return BurnBarWorkspacePanel.instance;
    }

    const instance = new BurnBarWorkspacePanel(controller, extensionUri);
    instance.createPanel();
    BurnBarWorkspacePanel.instance = instance;
    return instance;
  }

  /**
   * Returns the current singleton instance, if one exists.
   */
  static current(): BurnBarWorkspacePanel | undefined {
    return BurnBarWorkspacePanel.instance?.panel
      ? BurnBarWorkspacePanel.instance
      : undefined;
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.stateSubscription?.dispose();
    this.stateSubscription = undefined;
    this.panel?.dispose();
    this.panel = undefined;

    if (BurnBarWorkspacePanel.instance === this) {
      BurnBarWorkspacePanel.instance = undefined;
    }
  }

  private createPanel(): void {
    this.panel = vscode.window.createWebviewPanel(
      BurnBarWorkspacePanel.viewType,
      "BurnBar",
      { viewColumn: vscode.ViewColumn.One, preserveFocus: true },
      {
        enableScripts: true,
        retainContextWhenHidden: true,
        localResourceRoots: [this.extensionUri]
      }
    );

    const webview = this.panel.webview;

    const cssUri = webview.asWebviewUri(
      vscode.Uri.joinPath(this.extensionUri, "src", "webview", "workspace.css")
    );
    const jsUri = webview.asWebviewUri(
      vscode.Uri.joinPath(this.extensionUri, "src", "webview", "workspace.js")
    );
    const logoUri = webview.asWebviewUri(
      vscode.Uri.joinPath(this.extensionUri, "media", "app-icon-128.png")
    );
    const nonce = randomBytes(16).toString("hex");

    webview.html = buildWorkspaceHtml(webview, cssUri, jsUri, logoUri, nonce);

    // Post initial snapshot
    this.postSnapshot();

    // Re-post on every state change
    this.stateSubscription = this.controller.onDidChangeState(() => {
      this.postSnapshot();
    });

    // Handle incoming messages from webview
    this.panel.webview.onDidReceiveMessage(
      (message: BurnBarWorkspaceWebviewMessage) => {
        void this.handleWebviewMessage(message);
      }
    );

    // Clean up when the panel is closed
    this.panel.onDidDispose(() => {
      this.stateSubscription?.dispose();
      this.stateSubscription = undefined;
      this.panel = undefined;

      if (BurnBarWorkspacePanel.instance === this) {
        BurnBarWorkspacePanel.instance = undefined;
      }
    });
  }

  private postSnapshot(): void {
    if (!this.panel) return;

    const viewModel = buildPanelViewModel(this.controller.snapshot, {
      showOpenBurnBarApp: process.platform === "darwin"
    });

    void this.panel.webview.postMessage({ type: "snapshot", viewModel });
    void this.panel.webview.postMessage({ type: "restoreSection", section: this.lastSection });
  }

  private async handleWebviewMessage(
    message: BurnBarWorkspaceWebviewMessage
  ): Promise<void> {
    try {
      switch (message.type) {
        case "startRun": {
          const metadata: Record<string, BurnBarJSONValue> = {
            mode: message.mode
          };
          const activeEditor = vscode.window.activeTextEditor;
          if (activeEditor?.document) {
            const document = activeEditor.document;
            const workspaceFolder = vscode.workspace.getWorkspaceFolder(
              document.uri
            );
            metadata.activeFilePath = workspaceFolder
              ? vscode.workspace.asRelativePath(document.uri, false)
              : document.uri.fsPath;

            const selectedText = document
              .getText(activeEditor.selection)
              .trim();
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
        }
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
        case "openApp":
          await openBurnBarAppOrWarn(
            "dashboard",
            "Could not open BurnBar. Install the BurnBar app, then try again."
          );
          break;
        case "switchSection":
          this.lastSection = message.section;
          break;
        case "openConversationSearch":
          await openBurnBarAppOrWarn(
            "search",
            "Could not open BurnBar for conversation search. Install the BurnBar app, then try again."
          );
          break;
      }
    } catch (error) {
      if (this.panel) {
        void this.panel.webview.postMessage({
          type: "error",
          message:
            error instanceof Error
              ? error.message
              : "BurnBar encountered an unexpected error."
        });
      }
    }
  }
}

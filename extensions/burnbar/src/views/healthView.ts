import * as vscode from "vscode";

import type { BurnBarExtensionController } from "../state/controller";
import { buildHealthRows, type BurnBarHealthRow } from "../state/projections";

class BurnBarHealthTreeItem extends vscode.TreeItem {
  constructor(row: BurnBarHealthRow) {
    super(row.label, vscode.TreeItemCollapsibleState.None);
    this.description = row.value;
    this.tooltip = row.tooltip ?? `${row.label}: ${row.value}`;
    this.iconPath = iconFor(row.icon);
    this.contextValue = "burnbar.healthRow";
  }
}

export class BurnBarHealthTreeDataProvider implements vscode.TreeDataProvider<BurnBarHealthTreeItem>, vscode.Disposable {
  private readonly eventEmitter = new vscode.EventEmitter<BurnBarHealthTreeItem | undefined | null | void>();
  private readonly stateSubscription: vscode.Disposable;

  constructor(private readonly controller: BurnBarExtensionController) {
    this.stateSubscription = controller.onDidChangeState(() => this.eventEmitter.fire());
  }

  readonly onDidChangeTreeData = this.eventEmitter.event;

  getChildren(element?: BurnBarHealthTreeItem): Thenable<BurnBarHealthTreeItem[]> {
    if (element) {
      return Promise.resolve([]);
    }

    return Promise.resolve(buildHealthRows(this.controller.snapshot).map((row) => new BurnBarHealthTreeItem(row)));
  }

  getTreeItem(element: BurnBarHealthTreeItem): vscode.TreeItem {
    return element;
  }

  dispose(): void {
    this.stateSubscription.dispose();
    this.eventEmitter.dispose();
  }
}

function iconFor(kind: BurnBarHealthRow["icon"]): vscode.ThemeIcon {
  switch (kind) {
    case "pass":
      return new vscode.ThemeIcon("pass");
    case "warning":
      return new vscode.ThemeIcon("warning");
    case "pulse":
      return new vscode.ThemeIcon("pulse");
    case "note":
      return new vscode.ThemeIcon("circle-outline");
  }
}

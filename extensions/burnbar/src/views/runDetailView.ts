import * as vscode from "vscode";

import type { BurnBarExtensionController } from "../state/controller";
import { buildRunDetailRows } from "../state/projections";

class BurnBarRunDetailTreeItem extends vscode.TreeItem {
  constructor(label: string, value: string) {
    super(label, vscode.TreeItemCollapsibleState.None);
    this.description = value;
    this.tooltip = `${label}: ${value}`;
    this.iconPath = new vscode.ThemeIcon("chevron-right");
    this.contextValue = "burnbar.runDetailRow";
  }
}

export class BurnBarRunDetailTreeDataProvider
  implements vscode.TreeDataProvider<BurnBarRunDetailTreeItem>, vscode.Disposable
{
  private readonly eventEmitter = new vscode.EventEmitter<BurnBarRunDetailTreeItem | undefined | null | void>();
  private readonly stateSubscription: vscode.Disposable;

  constructor(private readonly controller: BurnBarExtensionController) {
    this.stateSubscription = controller.onDidChangeState(() => this.eventEmitter.fire());
  }

  readonly onDidChangeTreeData = this.eventEmitter.event;

  getChildren(element?: BurnBarRunDetailTreeItem): Thenable<BurnBarRunDetailTreeItem[]> {
    if (element) {
      return Promise.resolve([]);
    }

    return Promise.resolve(
      buildRunDetailRows(this.controller.snapshot).map((row) => new BurnBarRunDetailTreeItem(row.label, row.value))
    );
  }

  getTreeItem(element: BurnBarRunDetailTreeItem): vscode.TreeItem {
    return element;
  }

  dispose(): void {
    this.stateSubscription.dispose();
    this.eventEmitter.dispose();
  }
}

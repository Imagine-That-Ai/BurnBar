import * as vscode from 'vscode';

import type { OpenBurnBarControllerSnapshotSource } from '../state/controller';
import { buildRunDetailRows } from '../state/projections';

class OpenBurnBarRunDetailTreeItem extends vscode.TreeItem {
  constructor(label: string, value: string) {
    super(label, vscode.TreeItemCollapsibleState.None);
    this.description = value;
    this.tooltip = `${label}: ${value}`;
    this.iconPath = new vscode.ThemeIcon('chevron-right');
    this.contextValue = 'openburnbar.runDetailRow';
  }
}

export class OpenBurnBarRunDetailTreeDataProvider
  implements vscode.TreeDataProvider<OpenBurnBarRunDetailTreeItem>, vscode.Disposable
{
  private readonly eventEmitter = new vscode.EventEmitter<OpenBurnBarRunDetailTreeItem | undefined | null | void>();
  private readonly stateSubscription: vscode.Disposable;

  constructor(private readonly controller: OpenBurnBarControllerSnapshotSource) {
    this.stateSubscription = controller.onDidChangeState(() => this.eventEmitter.fire());
  }

  readonly onDidChangeTreeData = this.eventEmitter.event;

  getChildren(element?: OpenBurnBarRunDetailTreeItem): Thenable<OpenBurnBarRunDetailTreeItem[]> {
    if (element) {
      return Promise.resolve([]);
    }

    return Promise.resolve(
      buildRunDetailRows(this.controller.snapshot).map((row) => new OpenBurnBarRunDetailTreeItem(row.label, row.value))
    );
  }

  getTreeItem(element: OpenBurnBarRunDetailTreeItem): vscode.TreeItem {
    return element;
  }

  dispose(): void {
    this.stateSubscription.dispose();
    this.eventEmitter.dispose();
  }
}

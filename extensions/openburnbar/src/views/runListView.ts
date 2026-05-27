import * as vscode from 'vscode';

import type { OpenBurnBarControllerSnapshotSource } from '../state/controller';
import type { BurnBarRunProjection } from '../types';

export class OpenBurnBarRunTreeItem extends vscode.TreeItem {
  constructor(readonly run: BurnBarRunProjection) {
    super(run.title, vscode.TreeItemCollapsibleState.None);
    this.id = run.id;
    this.description = describeRun(run);
    this.tooltip = run.note;
    this.iconPath = new vscode.ThemeIcon(iconForPhase(run.phase));
    this.contextValue = run.source === 'daemon' ? 'openburnbar.run.daemon' : 'openburnbar.run.projected';
  }
}

export class OpenBurnBarRunListTreeDataProvider implements vscode.TreeDataProvider<OpenBurnBarRunTreeItem>, vscode.Disposable {
  private readonly eventEmitter = new vscode.EventEmitter<OpenBurnBarRunTreeItem | undefined | null | void>();
  private readonly stateSubscription: vscode.Disposable;

  constructor(private readonly controller: OpenBurnBarControllerSnapshotSource) {
    this.stateSubscription = controller.onDidChangeState(() => this.eventEmitter.fire());
  }

  readonly onDidChangeTreeData = this.eventEmitter.event;

  getChildren(element?: OpenBurnBarRunTreeItem): Thenable<OpenBurnBarRunTreeItem[]> {
    if (element) {
      return Promise.resolve([]);
    }

    return Promise.resolve(this.controller.snapshot.runs.map((run) => new OpenBurnBarRunTreeItem(run)));
  }

  getTreeItem(element: OpenBurnBarRunTreeItem): vscode.TreeItem {
    return element;
  }

  dispose(): void {
    this.stateSubscription.dispose();
    this.eventEmitter.dispose();
  }
}

function describeRun(run: BurnBarRunProjection): string {
  const tags = [run.phase.replaceAll('_', ' '), run.modelId ?? (run.source === 'daemon' ? 'run' : 'shell')];
  return tags.join(' • ');
}

function iconForPhase(phase: BurnBarRunProjection['phase']): string {
  switch (phase) {
  case 'completed':
    return 'pass';
  case 'failed':
    return 'warning';
  case 'waiting_on_companion':
    return 'clock';
  case 'planning':
  case 'model_streaming':
  case 'executing_tool':
    return 'pulse';
  case 'cancelled':
    return 'circle-slash';
  case 'awaiting_approval':
    return 'question';
  case 'idle':
    return 'circle-large-outline';
  default:
    return 'circle';
  }
}

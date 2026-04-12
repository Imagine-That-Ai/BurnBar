import { randomUUID } from 'node:crypto';
import { basename, isAbsolute, relative, resolve as resolvePath } from 'node:path';

import * as vscode from 'vscode';

import { OpenBurnBarDaemonClient } from './daemon/client';
import { OpenBurnBarRepairService } from './daemon/repair';
import {
  OpenBurnBarExtensionController,
  type OpenBurnBarControllerDependencies,
  type OpenBurnBarControllerOptions
} from './state/controller';
import {
  BURNBAR_PROTOCOL_VERSION,
  BURNBAR_RECONNECT_INTERVAL_MS,
  type BurnBarCatalogModel,
  type BurnBarCatalogProvider,
  type BurnBarJSONValue,
  type BurnBarRunDetailResponse
} from './types';
import { OpenBurnBarHealthTreeDataProvider } from './views/healthView';
import { openBurnBarAppOrWarn } from './host/openBurnBarApp';
import { OpenBurnBarRunDetailTreeDataProvider } from './views/runDetailView';
import { OpenBurnBarRunListTreeDataProvider, OpenBurnBarRunTreeItem } from './views/runListView';
import { OpenBurnBarPanelView } from './views/panelView';
import { OpenBurnBarWorkspacePanel } from './views/workspacePanel';
import { activateOpenBurnBarWorkspaceCompanion } from './workspace/companion';
import { OpenBurnBarWorkspaceRpcClient } from './workspace/rpc';

const BURNBAR_CLIENT_ID_KEY = 'openburnbar.clientId';

export interface OpenBurnBarActivationDependencies {
  controllerDependencies?: OpenBurnBarControllerDependencies;
  controllerOptions?: Partial<OpenBurnBarControllerOptions>;
  autoRefreshIntervalMs?: number;
  setIntervalFn?: typeof setInterval;
  clearIntervalFn?: typeof clearInterval;
  extensionKind?: vscode.ExtensionKind;
  remoteName?: string;
}

export async function activate(context: vscode.ExtensionContext): Promise<void> {
  await activateBurnBarExtension(context);
}

// Deactivation handled via dispose() on controllers and subscriptions
export function deactivate(): void {}

export async function activateBurnBarExtension(
  context: vscode.ExtensionContext,
  dependencies: OpenBurnBarActivationDependencies = {}
): Promise<OpenBurnBarExtensionController | undefined> {
  const extensionKind = dependencies.extensionKind ?? context.extension.extensionKind;
  const remoteName = dependencies.remoteName ?? vscode.env.remoteName;
  const shouldActivateWorkspaceCompanion = extensionKind === vscode.ExtensionKind.Workspace || !remoteName;
  const workspaceClient =
    dependencies.controllerDependencies?.workspaceClient ?? new OpenBurnBarWorkspaceRpcClient();
  const daemonClient =
    dependencies.controllerDependencies?.client ?? new OpenBurnBarDaemonClient();

  if (shouldActivateWorkspaceCompanion) {
    context.subscriptions.push(
      activateOpenBurnBarWorkspaceCompanion(extensionKind === vscode.ExtensionKind.Workspace ? 'workspace' : 'ui', {
        indexedSearch: async (params) =>
          daemonClient.searchQuery({
            query: params.query,
            providerRaw: params.providerRaw,
            projectName: params.projectName,
            dateRangeStartEpoch: params.dateRangeStartEpoch,
            dateRangeEndEpoch: params.dateRangeEndEpoch,
            resultLimit: params.resultLimit ?? 50
          })
      })
    );
  }

  if (extensionKind !== vscode.ExtensionKind.UI) {
    if (remoteName) {
      void maybeRunCursorSmokeWithoutUI(daemonClient, workspaceClient);
    }
    return undefined;
  }

  const controllerDependencies =
    dependencies.controllerDependencies ?? {
      client: daemonClient,
      repairService: new OpenBurnBarRepairService(),
      workspaceClient
    };

  const controller = new OpenBurnBarExtensionController(
    controllerDependencies,
    {
      clientID: await resolveBurnBarClientID(context, dependencies.controllerOptions?.clientID),
      sessionID: dependencies.controllerOptions?.sessionID ?? randomUUID(),
      clientName: dependencies.controllerOptions?.clientName ?? 'OpenBurnBar VS Code Extension',
      supportedProtocolVersions: dependencies.controllerOptions?.supportedProtocolVersions
    }
  );

  const panelView = new OpenBurnBarPanelView(controller, context.extensionUri);
  const panelViewRegistration = vscode.window.registerWebviewViewProvider(
    OpenBurnBarPanelView.viewType,
    panelView,
    { webviewOptions: { retainContextWhenHidden: true } }
  );

  const healthProvider = new OpenBurnBarHealthTreeDataProvider(controller);
  const runListProvider = new OpenBurnBarRunListTreeDataProvider(controller);
  const runDetailProvider = new OpenBurnBarRunDetailTreeDataProvider(controller);

  const healthView = vscode.window.createTreeView('openburnbar.health', {
    treeDataProvider: healthProvider,
    showCollapseAll: false
  });
  const runsView = vscode.window.createTreeView('openburnbar.runs', {
    treeDataProvider: runListProvider,
    showCollapseAll: false
  });
  const runDetailView = vscode.window.createTreeView('openburnbar.runDetail', {
    treeDataProvider: runDetailProvider,
    showCollapseAll: false
  });

  context.subscriptions.push(controller, panelView, panelViewRegistration, healthProvider, runListProvider, runDetailProvider, healthView, runsView, runDetailView);

  context.subscriptions.push(
    vscode.commands.registerCommand('openburnbar.reconnect', async () => {
      await controller.reconnect();
    })
  );
  context.subscriptions.push(
    vscode.commands.registerCommand('openburnbar.refresh', async () => {
      await controller.refresh();
    })
  );
  context.subscriptions.push(
    vscode.commands.registerCommand('openburnbar.repairDaemon', async () => {
      try {
        const result = await controller.repairDaemon();
        await vscode.window.showInformationMessage(result.message);
      } catch (error) {
        await vscode.window.showWarningMessage(
          error instanceof Error ? error.message : 'OpenBurnBar daemon repair failed.'
        );
      }
    })
  );
  context.subscriptions.push(
    vscode.commands.registerCommand('openburnbar.startRun', async () => {
      const model = await promptForRunModel(controller);
      if (!model) {
        return;
      }

      const prompt = await vscode.window.showInputBox({
        title: 'Start OpenBurnBar Run',
        prompt: 'Describe what OpenBurnBar should do.',
        placeHolder: 'Summarize the failing test and propose a fix.',
        ignoreFocusOut: true,
        validateInput(value) {
          return value.trim().length === 0 ? 'A prompt is required to start a OpenBurnBar run.' : undefined;
        }
      });

      if (!prompt) {
        return;
      }

      try {
        const inferredMetadata = {
          ...buildEditorContextMetadata(),
          ...inferWorkflowMetadataFromPrompt(prompt)
        };
        const result = await controller.startRun({
          prompt,
          modelID: model.id,
          metadata: inferredMetadata
        });
        await vscode.window.showInformationMessage(`Started OpenBurnBar run ${result.runID}.`);
      } catch (error) {
        await vscode.window.showWarningMessage(error instanceof Error ? error.message : 'OpenBurnBar could not start the run.');
      }
    })
  );
  context.subscriptions.push(
    vscode.commands.registerCommand('openburnbar.cancelRun', async (item?: OpenBurnBarRunTreeItem) => {
      const run = resolveDaemonRun(controller, item);
      if (!run) {
        await vscode.window.showWarningMessage('Select a daemon-backed OpenBurnBar run to cancel.');
        return;
      }

      const confirmation = await vscode.window.showWarningMessage(
        `Cancel OpenBurnBar run ${run.id}?`,
        { modal: true },
        'Cancel Run'
      );
      if (confirmation !== 'Cancel Run') {
        return;
      }

      try {
        await controller.cancelRun(run.id);
        await vscode.window.showInformationMessage(`Cancelled OpenBurnBar run ${run.id}.`);
      } catch (error) {
        await vscode.window.showWarningMessage(error instanceof Error ? error.message : 'OpenBurnBar could not cancel the run.');
      }
    })
  );
  context.subscriptions.push(
    vscode.commands.registerCommand('openburnbar.retryRun', async (item?: OpenBurnBarRunTreeItem) => {
      const run = resolveDaemonRun(controller, item);
      if (!run) {
        await vscode.window.showWarningMessage('Select a daemon-backed OpenBurnBar run to retry.');
        return;
      }

      try {
        await controller.retryRun(run.id);
        await vscode.window.showInformationMessage(`Retried OpenBurnBar run ${run.id}.`);
      } catch (error) {
        await vscode.window.showWarningMessage(error instanceof Error ? error.message : 'OpenBurnBar could not retry the run.');
      }
    })
  );
  context.subscriptions.push(
    vscode.commands.registerCommand('openburnbar.approveRun', async (item?: OpenBurnBarRunTreeItem) => {
      await handleApprovalResponse(controller, item, 'approve');
    })
  );
  context.subscriptions.push(
    vscode.commands.registerCommand('openburnbar.rejectRun', async (item?: OpenBurnBarRunTreeItem) => {
      await handleApprovalResponse(controller, item, 'reject');
    })
  );
  context.subscriptions.push(
    vscode.commands.registerCommand('openburnbar.openWorkspace', () => {
      OpenBurnBarWorkspacePanel.open(controller, context.extensionUri);
    })
  );
  context.subscriptions.push(
    vscode.commands.registerCommand('openburnbar.openConversationSearch', async () => {
      await openBurnBarAppOrWarn(
        'search',
        'Could not open OpenBurnBar for conversation search. Install the OpenBurnBar app, then try again.'
      );
    })
  );

  context.subscriptions.push(
    runsView.onDidChangeSelection((event) => {
      const selectedItem = event.selection[0];
      if (selectedItem instanceof OpenBurnBarRunTreeItem) {
        void controller.selectRun(selectedItem.run.id);
      }
    })
  );

  context.subscriptions.push(
    vscode.window.onDidChangeWindowState((windowState) => {
      if (windowState.focused) {
        void controller.refresh();
      }
    })
  );

  const autoRefreshIntervalMs = dependencies.autoRefreshIntervalMs ?? BURNBAR_RECONNECT_INTERVAL_MS;
  if (autoRefreshIntervalMs > 0) {
    const setIntervalFn = dependencies.setIntervalFn ?? setInterval;
    const clearIntervalFn = dependencies.clearIntervalFn ?? clearInterval;
    const intervalHandle = setIntervalFn(() => {
      void controller.refresh();
    }, autoRefreshIntervalMs);

    context.subscriptions.push({
      dispose: () => clearIntervalFn(intervalHandle)
    });
  }

  await controller.initialize();
  void maybeRunCursorSmoke(controller, controllerDependencies.workspaceClient, daemonClient);
  return controller;
}

async function maybeRunCursorSmoke(
  controller: OpenBurnBarExtensionController,
  workspaceClient: OpenBurnBarControllerDependencies['workspaceClient'],
  daemonClient: OpenBurnBarControllerDependencies['client']
): Promise<void> {
  const smokeConfig =
    typeof vscode.workspace.getConfiguration === 'function'
      ? vscode.workspace.getConfiguration()
      : undefined;
  const outputPath = process.env.BURNBAR_CURSOR_SMOKE_OUTPUT ?? smokeConfig?.get<string>('openburnbar.cursorSmoke.outputPath');
  if (!outputPath) {
    return;
  }

  try {
    await runCursorSmoke({
      outputPath,
      filePath: process.env.BURNBAR_CURSOR_SMOKE_FILE_PATH ?? smokeConfig?.get<string>('openburnbar.cursorSmoke.filePath'),
      modelID: process.env.BURNBAR_CURSOR_SMOKE_MODEL ?? smokeConfig?.get<string>('openburnbar.cursorSmoke.modelID'),
      workspaceClient,
      daemonClient,
      getRunDetail: async (runID) => controller.getRunDetail(runID),
      createRun: async (resolvedModelID, prompt, metadata) => {
        const result = await controller.startRun({
          prompt,
          modelID: resolvedModelID,
          metadata
        });
        return result.runID;
      },
      approveRun: async (runID) => {
        await controller.respondToApproval(runID, 'approve', 'Approved by OpenBurnBar Cursor smoke test.');
      },
      getRunPhase: async (runID) => {
        const detail = await controller.getRunDetail(runID);
        return detail?.run?.phase;
      }
    });
  } catch {
    // `runCursorSmoke` writes the failure payload.
  }
}

async function maybeRunCursorSmokeWithoutUI(
  daemonClient: OpenBurnBarControllerDependencies['client'],
  workspaceClient: OpenBurnBarControllerDependencies['workspaceClient']
): Promise<void> {
  const smokeConfig =
    typeof vscode.workspace.getConfiguration === 'function'
      ? vscode.workspace.getConfiguration()
      : undefined;
  const outputPath = process.env.BURNBAR_CURSOR_SMOKE_OUTPUT ?? smokeConfig?.get<string>('openburnbar.cursorSmoke.outputPath');
  if (!outputPath) {
    return;
  }

  const clientID = randomUUID();
  const sessionID = randomUUID();

  try {
    await daemonClient.attach({
      clientID,
      sessionID,
      clientName: 'OpenBurnBar Cursor Smoke',
      supportedProtocolVersions: [BURNBAR_PROTOCOL_VERSION]
    });
  } catch {
    // Ignore attach failures here. `runCursorSmoke` will surface them on create/get.
  }

  try {
    await runCursorSmoke({
      outputPath,
      filePath: process.env.BURNBAR_CURSOR_SMOKE_FILE_PATH ?? smokeConfig?.get<string>('openburnbar.cursorSmoke.filePath'),
      modelID: process.env.BURNBAR_CURSOR_SMOKE_MODEL ?? smokeConfig?.get<string>('openburnbar.cursorSmoke.modelID'),
      workspaceClient,
      daemonClient,
      getRunDetail: async (runID) =>
        daemonClient.getRun({
          runID,
          clientID
        }),
      createRun: async (resolvedModelID, prompt, metadata) => {
        const result = await daemonClient.createRun({
          clientID,
          sessionID,
          prompt,
          modelID: resolvedModelID,
          metadata
        });
        return result.runID;
      },
      approveRun: async (_runID, approvalID) => {
        await daemonClient.respondToApproval({
          response: {
            approvalID,
            clientID,
            decision: 'approve',
            note: 'Approved by OpenBurnBar Cursor smoke test.',
            respondedAt: toBurnBarTimestamp()
          }
        });
      },
      getRunPhase: async (runID) => {
        const detail = await daemonClient.getRun({ runID, clientID });
        return detail.run?.phase;
      }
    });
  } catch {
    // `runCursorSmoke` writes the failure payload.
  } finally {
    try {
      await daemonClient.detach({ clientID, sessionID });
    } catch {
      // best effort
    }
  }
}

async function runCursorSmoke({
  outputPath,
  filePath,
  modelID,
  workspaceClient,
  daemonClient,
  getRunDetail,
  createRun,
  approveRun,
  getRunPhase
}: {
  outputPath: string;
  filePath?: string;
  modelID?: string;
  workspaceClient: OpenBurnBarControllerDependencies['workspaceClient'];
  daemonClient: OpenBurnBarControllerDependencies['client'];
  getRunDetail?: (runID: string) => Promise<BurnBarRunDetailResponse | undefined>;
  createRun: (
    resolvedModelID: string,
    prompt: string,
    metadata: Record<string, BurnBarJSONValue>
  ) => Promise<string>;
  approveRun?: (runID: string, approvalID: string) => Promise<void>;
  getRunPhase: (runID: string) => Promise<string | undefined>;
}): Promise<void> {
  const fs = await import('node:fs/promises');
  const safeOutputPath = sanitizeSmokeOutputPath(outputPath);

  try {
    await fs.writeFile(
      safeOutputPath,
      JSON.stringify({ ok: false, stage: 'starting' }, null, 2),
      'utf8'
    );

    const capabilities = await workspaceClient.capabilities();
    if (!capabilities.hasWorkspace) {
      throw new Error('OpenBurnBar smoke requires an open workspace.');
    }
    if (!filePath) {
      throw new Error('OpenBurnBar smoke requires a workspace file path.');
    }

    const readResult = await (workspaceClient as OpenBurnBarWorkspaceRpcClient).readFile({ path: filePath });
    const catalog = await daemonClient.catalog();
    const fallbackModelID = catalog.providers
      .flatMap((provider) => provider.models.filter((model) => model.visibility === 'public'))
      .at(0)?.id;
    const resolvedModelID = modelID ?? fallbackModelID;

    if (!resolvedModelID) {
      throw new Error('OpenBurnBar smoke could not resolve a model to run.');
    }

    const replacement = buildSmokeReplacement(readResult.content);
    const runID = await createRun(
      resolvedModelID,
      `Please update the current file so the numeric constant becomes ${replacement.to}.`,
      {
        activeFilePath: filePath
      }
    );

    let phase = 'unknown';
    const autoApprovedApprovalIDs = new Set<string>();
    for (let attempt = 0; attempt < 240; attempt += 1) {
      phase = (await getRunPhase(runID)) ?? phase;
      if (phase === 'awaiting_approval' && getRunDetail && approveRun) {
        const runDetail = await getRunDetail(runID);
        const approvalID = runDetail?.approvalRequest?.approvalID;
        if (approvalID && !autoApprovedApprovalIDs.has(approvalID)) {
          autoApprovedApprovalIDs.add(approvalID);
          await approveRun(runID, approvalID);
          continue;
        }
      }
      if (phase === 'completed' || phase === 'failed' || phase === 'cancelled') {
        break;
      }
      await new Promise((resolve) => setTimeout(resolve, 250));
    }

    if (phase !== 'completed') {
      const runDetail = getRunDetail ? await getRunDetail(runID) : undefined;
      throw Object.assign(new Error(`OpenBurnBar smoke run ended in phase '${phase}'.`), {
        runID,
        phase,
        runDetail
      });
    }

    const afterResult = await (workspaceClient as OpenBurnBarWorkspaceRpcClient).readFile({ path: filePath });
    const fileChanged = afterResult.content !== readResult.content;
    if (!fileChanged) {
      throw new Error('OpenBurnBar smoke run completed, but the workspace file did not change.');
    }

    await fs.writeFile(
      safeOutputPath,
      JSON.stringify(
        {
          ok: true,
          filePath,
          readCharacters: readResult.content.length,
          changedCharacters: afterResult.content.length,
          fileChanged,
          runID,
          phase
        },
        null,
        2
      ),
      'utf8'
    );
  } catch (error) {
    const failure = error as {
      message?: string;
      runID?: string;
      phase?: string;
      runDetail?: BurnBarRunDetailResponse;
    };
    await fs.writeFile(
      safeOutputPath,
      JSON.stringify(
        {
          ok: false,
          error: error instanceof Error ? error.message : String(error),
          runID: failure.runID,
          phase: failure.phase,
          runDetail: failure.runDetail
        },
        null,
        2
      ),
      'utf8'
    );
    throw error;
  }
}

/**
 * Validate a developer-supplied smoke-output path before passing it to fs APIs.
 *
 * The path comes from a CI-controlled env var or workspace setting, but we still
 * constrain it to (a) absolute, (b) no NUL bytes, (c) basename limited to a
 * conservative character set ending in `.json`. This neutralizes the
 * `js/path-injection` taint flow CodeQL traces from the env var into writeFile.
 */
function sanitizeSmokeOutputPath(raw: string): string {
  if (typeof raw !== 'string' || raw.length === 0 || raw.includes('\0')) {
    throw new Error('Invalid smoke output path.');
  }
  const resolved = resolvePath(raw);
  if (!isAbsolute(resolved)) {
    throw new Error('Smoke output path must resolve to an absolute path.');
  }
  const base = basename(resolved);
  if (!/^[A-Za-z0-9._-]+\.json$/.test(base)) {
    throw new Error('Smoke output basename must match [A-Za-z0-9._-]+\\.json');
  }
  return resolved;
}

// Reserved for future use when extension activation waits on daemon
export async function _waitForDaemonReady(
  daemonClient: OpenBurnBarControllerDependencies['client'],
  timeoutMs = 60_000
): Promise<void> {
  const startedAt = Date.now();
  let lastError: string | undefined;

  while (Date.now() - startedAt <= timeoutMs) {
    try {
      await daemonClient.health();
      return;
    } catch (error) {
      lastError = error instanceof Error ? error.message : String(error);
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
  }

  throw new Error(lastError ?? 'Timed out waiting for the OpenBurnBar daemon to become ready.');
}

function buildSmokeReplacement(content: string): { from: string; to: string } {
  const numberMatch = content.match(/\b\d+\b/u);
  if (numberMatch?.[0]) {
    const from = numberMatch[0];
    const asNumber = Number(from);
    if (Number.isFinite(asNumber)) {
      return {
        from,
        to: String(asNumber + 1)
      };
    }
  }

  const stringMatch = content.match(/["'`]([^"'`\n]+)["'`]/u);
  if (stringMatch?.[1]) {
    return {
      from: stringMatch[1],
      to: `${stringMatch[1]} (edited)`
    };
  }

  const firstLine = content.split(/\r?\n/u)[0]?.trim() ?? content.trim();
  const from = firstLine.length > 0 ? firstLine.slice(0, Math.min(firstLine.length, 12)) : 'value';
  return {
    from,
    to: `${from} (edited)`
  };
}

function toBurnBarTimestamp(date = new Date()): number {
  return date.getTime() / 1000 - 978_307_200;
}

function inferWorkflowMetadataFromPrompt(prompt: string): Record<string, BurnBarJSONValue> | undefined {
  if (!/change a string in one file/iu.test(prompt)) {
    return undefined;
  }

  const editor = vscode.window.activeTextEditor;
  if (!editor) {
    return undefined;
  }

  const document = editor.document;
  if (document.uri.scheme !== 'file') {
    return undefined;
  }

  const workspaceFolder = vscode.workspace.getWorkspaceFolder(document.uri);
  const path = workspaceFolder
    ? relative(workspaceFolder.uri.fsPath, document.uri.fsPath) || document.uri.fsPath
    : document.uri.fsPath;
  const replacement = buildSmokeReplacement(document.getText());

  return {
    workspaceWorkflow: {
      type: 'replace_string_in_file',
      path,
      from: replacement.from,
      to: replacement.to
    } as BurnBarJSONValue
  };
}

function buildEditorContextMetadata(): Record<string, BurnBarJSONValue> | undefined {
  const editor = vscode.window.activeTextEditor;
  if (!editor) {
    return undefined;
  }

  const document = editor.document;
  if (document.uri.scheme !== 'file') {
    return undefined;
  }

  const workspaceFolder = vscode.workspace.getWorkspaceFolder(document.uri);
  const metadata: Record<string, BurnBarJSONValue> = {
    activeFilePath: workspaceFolder
      ? relative(workspaceFolder.uri.fsPath, document.uri.fsPath) || document.uri.fsPath
      : document.uri.fsPath
  };

  const selectedText = document.getText(editor.selection).trim();
  if (selectedText) {
    metadata.activeSelectionText = selectedText;
  }

  return metadata;
}

async function resolveBurnBarClientID(
  context: vscode.ExtensionContext,
  overrideClientID?: string
): Promise<string> {
  if (overrideClientID) {
    return overrideClientID;
  }

  const storedClientID = context.globalState?.get<string>(BURNBAR_CLIENT_ID_KEY);
  if (storedClientID) {
    return storedClientID;
  }

  const nextClientID = randomUUID();
  await context.globalState?.update(BURNBAR_CLIENT_ID_KEY, nextClientID);
  return nextClientID;
}

function resolveDaemonRun(controller: OpenBurnBarExtensionController, item?: OpenBurnBarRunTreeItem) {
  const run = item?.run ?? controller.selectedRun;
  return run?.source === 'daemon' ? run : undefined;
}

async function promptForRunModel(
  controller: OpenBurnBarExtensionController
): Promise<(BurnBarCatalogModel & { provider: BurnBarCatalogProvider }) | undefined> {
  const models = controller.snapshot.catalog?.providers.flatMap((provider) =>
    provider.models
      .filter((model) => model.visibility === 'public')
      .map((model) => ({
        ...model,
        provider
      }))
  );

  if (!models || models.length === 0) {
    await vscode.window.showWarningMessage(
      'OpenBurnBar could not find any public daemon models. Check provider settings in the app, then refresh.'
    );
    return undefined;
  }

  const selection = await vscode.window.showQuickPick(
    models.map((model) => ({
      label: model.displayName,
      description: model.id,
      detail: model.provider.displayName,
      model
    })),
    {
      title: 'Choose OpenBurnBar Model',
      placeHolder: 'Select the daemon-backed model for this run',
      ignoreFocusOut: true
    }
  );

  return selection?.model;
}

async function handleApprovalResponse(
  controller: OpenBurnBarExtensionController,
  item: OpenBurnBarRunTreeItem | undefined,
  decision: 'approve' | 'reject'
): Promise<void> {
  const run = resolveDaemonRun(controller, item);
  if (!run) {
    await vscode.window.showWarningMessage(`Select a daemon-backed OpenBurnBar run to ${decision}.`);
    return;
  }

  try {
    const detail = await controller.getRunDetail(run.id);
    const prompt = detail?.approvalRequest
      ? `${detail.approvalRequest.title}\n\n${detail.approvalRequest.message}`
      : `This OpenBurnBar run is waiting for ${decision === 'approve' ? 'approval' : 'rejection'}.`;
    const confirmation = await vscode.window.showWarningMessage(
      prompt,
      { modal: true },
      decision === 'approve' ? 'Approve' : 'Reject'
    );

    if (confirmation !== (decision === 'approve' ? 'Approve' : 'Reject')) {
      return;
    }

    await controller.respondToApproval(run.id, decision);
    await vscode.window.showInformationMessage(
      `${decision === 'approve' ? 'Approved' : 'Rejected'} OpenBurnBar run ${run.id}.`
    );
  } catch (error) {
    await vscode.window.showWarningMessage(
      error instanceof Error ? error.message : `OpenBurnBar could not ${decision} the approval request.`
    );
  }
}

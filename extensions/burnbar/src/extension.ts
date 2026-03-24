import { randomUUID } from "node:crypto";
import { relative } from "node:path";

import * as vscode from "vscode";

import { BurnBarDaemonClient } from "./daemon/client";
import { BurnBarRepairService } from "./daemon/repair";
import {
  BurnBarExtensionController,
  type BurnBarControllerDependencies,
  type BurnBarControllerOptions
} from "./state/controller";
import {
  BURNBAR_PROTOCOL_VERSION,
  BURNBAR_RECONNECT_INTERVAL_MS,
  type BurnBarCatalogModel,
  type BurnBarCatalogProvider,
  type BurnBarJSONValue,
  type BurnBarRunDetailResponse
} from "./types";
import { BurnBarHealthTreeDataProvider } from "./views/healthView";
import { openBurnBarAppOrWarn } from "./host/openBurnBarApp";
import { BurnBarRunDetailTreeDataProvider } from "./views/runDetailView";
import { BurnBarRunListTreeDataProvider, BurnBarRunTreeItem } from "./views/runListView";
import { BurnBarPanelView } from "./views/panelView";
import { BurnBarWorkspacePanel } from "./views/workspacePanel";
import { activateBurnBarWorkspaceCompanion } from "./workspace/companion";
import { BurnBarWorkspaceRpcClient } from "./workspace/rpc";

const BURNBAR_CLIENT_ID_KEY = "burnbar.clientId";

export interface BurnBarActivationDependencies {
  controllerDependencies?: BurnBarControllerDependencies;
  controllerOptions?: Partial<BurnBarControllerOptions>;
  autoRefreshIntervalMs?: number;
  setIntervalFn?: typeof setInterval;
  clearIntervalFn?: typeof clearInterval;
  extensionKind?: vscode.ExtensionKind;
  remoteName?: string;
}

export async function activate(context: vscode.ExtensionContext): Promise<void> {
  await activateBurnBarExtension(context);
}

export function deactivate(): void {}

export async function activateBurnBarExtension(
  context: vscode.ExtensionContext,
  dependencies: BurnBarActivationDependencies = {}
): Promise<BurnBarExtensionController | undefined> {
  const extensionKind = dependencies.extensionKind ?? context.extension.extensionKind;
  const remoteName = dependencies.remoteName ?? vscode.env.remoteName;
  const shouldActivateWorkspaceCompanion = extensionKind === vscode.ExtensionKind.Workspace || !remoteName;
  const workspaceClient =
    dependencies.controllerDependencies?.workspaceClient ?? new BurnBarWorkspaceRpcClient();
  const daemonClient =
    dependencies.controllerDependencies?.client ?? new BurnBarDaemonClient();

  if (shouldActivateWorkspaceCompanion) {
    context.subscriptions.push(activateBurnBarWorkspaceCompanion(extensionKind === vscode.ExtensionKind.Workspace ? "workspace" : "ui"));
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
      repairService: new BurnBarRepairService(),
      workspaceClient
    };

  const controller = new BurnBarExtensionController(
    controllerDependencies,
    {
      clientID: await resolveBurnBarClientID(context, dependencies.controllerOptions?.clientID),
      sessionID: dependencies.controllerOptions?.sessionID ?? randomUUID(),
      clientName: dependencies.controllerOptions?.clientName ?? "BurnBar VS Code Extension",
      supportedProtocolVersions: dependencies.controllerOptions?.supportedProtocolVersions
    }
  );

  const panelView = new BurnBarPanelView(controller, context.extensionUri);
  const panelViewRegistration = vscode.window.registerWebviewViewProvider(
    BurnBarPanelView.viewType,
    panelView,
    { webviewOptions: { retainContextWhenHidden: true } }
  );

  const healthProvider = new BurnBarHealthTreeDataProvider(controller);
  const runListProvider = new BurnBarRunListTreeDataProvider(controller);
  const runDetailProvider = new BurnBarRunDetailTreeDataProvider(controller);

  const healthView = vscode.window.createTreeView("burnbar.health", {
    treeDataProvider: healthProvider,
    showCollapseAll: false
  });
  const runsView = vscode.window.createTreeView("burnbar.runs", {
    treeDataProvider: runListProvider,
    showCollapseAll: false
  });
  const runDetailView = vscode.window.createTreeView("burnbar.runDetail", {
    treeDataProvider: runDetailProvider,
    showCollapseAll: false
  });

  context.subscriptions.push(controller, panelView, panelViewRegistration, healthProvider, runListProvider, runDetailProvider, healthView, runsView, runDetailView);

  context.subscriptions.push(
    vscode.commands.registerCommand("burnbar.reconnect", async () => {
      await controller.reconnect();
    })
  );
  context.subscriptions.push(
    vscode.commands.registerCommand("burnbar.refresh", async () => {
      await controller.refresh();
    })
  );
  context.subscriptions.push(
    vscode.commands.registerCommand("burnbar.repairDaemon", async () => {
      try {
        const result = await controller.repairDaemon();
        await vscode.window.showInformationMessage(result.message);
      } catch (error) {
        await vscode.window.showWarningMessage(
          error instanceof Error ? error.message : "BurnBar daemon repair failed."
        );
      }
    })
  );
  context.subscriptions.push(
    vscode.commands.registerCommand("burnbar.startRun", async () => {
      const model = await promptForRunModel(controller);
      if (!model) {
        return;
      }

      const prompt = await vscode.window.showInputBox({
        title: "Start BurnBar Run",
        prompt: "Describe what BurnBar should do.",
        placeHolder: "Summarize the failing test and propose a fix.",
        ignoreFocusOut: true,
        validateInput(value) {
          return value.trim().length === 0 ? "A prompt is required to start a BurnBar run." : undefined;
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
        await vscode.window.showInformationMessage(`Started BurnBar run ${result.runID}.`);
      } catch (error) {
        await vscode.window.showWarningMessage(error instanceof Error ? error.message : "BurnBar could not start the run.");
      }
    })
  );
  context.subscriptions.push(
    vscode.commands.registerCommand("burnbar.cancelRun", async (item?: BurnBarRunTreeItem) => {
      const run = resolveDaemonRun(controller, item);
      if (!run) {
        await vscode.window.showWarningMessage("Select a daemon-backed BurnBar run to cancel.");
        return;
      }

      const confirmation = await vscode.window.showWarningMessage(
        `Cancel BurnBar run ${run.id}?`,
        { modal: true },
        "Cancel Run"
      );
      if (confirmation !== "Cancel Run") {
        return;
      }

      try {
        await controller.cancelRun(run.id);
        await vscode.window.showInformationMessage(`Cancelled BurnBar run ${run.id}.`);
      } catch (error) {
        await vscode.window.showWarningMessage(error instanceof Error ? error.message : "BurnBar could not cancel the run.");
      }
    })
  );
  context.subscriptions.push(
    vscode.commands.registerCommand("burnbar.retryRun", async (item?: BurnBarRunTreeItem) => {
      const run = resolveDaemonRun(controller, item);
      if (!run) {
        await vscode.window.showWarningMessage("Select a daemon-backed BurnBar run to retry.");
        return;
      }

      try {
        await controller.retryRun(run.id);
        await vscode.window.showInformationMessage(`Retried BurnBar run ${run.id}.`);
      } catch (error) {
        await vscode.window.showWarningMessage(error instanceof Error ? error.message : "BurnBar could not retry the run.");
      }
    })
  );
  context.subscriptions.push(
    vscode.commands.registerCommand("burnbar.approveRun", async (item?: BurnBarRunTreeItem) => {
      await handleApprovalResponse(controller, item, "approve");
    })
  );
  context.subscriptions.push(
    vscode.commands.registerCommand("burnbar.rejectRun", async (item?: BurnBarRunTreeItem) => {
      await handleApprovalResponse(controller, item, "reject");
    })
  );
  context.subscriptions.push(
    vscode.commands.registerCommand("burnbar.openWorkspace", () => {
      BurnBarWorkspacePanel.open(controller, context.extensionUri);
    })
  );
  context.subscriptions.push(
    vscode.commands.registerCommand("burnbar.openConversationSearch", async () => {
      await openBurnBarAppOrWarn(
        "search",
        "Could not open BurnBar for conversation search. Install the BurnBar app, then try again."
      );
    })
  );

  context.subscriptions.push(
    runsView.onDidChangeSelection((event) => {
      const selectedItem = event.selection[0];
      if (selectedItem instanceof BurnBarRunTreeItem) {
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
  controller: BurnBarExtensionController,
  workspaceClient: BurnBarControllerDependencies["workspaceClient"],
  daemonClient: BurnBarControllerDependencies["client"]
): Promise<void> {
  const smokeConfig =
    typeof vscode.workspace.getConfiguration === "function"
      ? vscode.workspace.getConfiguration()
      : undefined;
  const outputPath = process.env.BURNBAR_CURSOR_SMOKE_OUTPUT ?? smokeConfig?.get<string>("burnbar.cursorSmoke.outputPath");
  if (!outputPath) {
    return;
  }

  try {
    await runCursorSmoke({
      outputPath,
      filePath: process.env.BURNBAR_CURSOR_SMOKE_FILE_PATH ?? smokeConfig?.get<string>("burnbar.cursorSmoke.filePath"),
      modelID: process.env.BURNBAR_CURSOR_SMOKE_MODEL ?? smokeConfig?.get<string>("burnbar.cursorSmoke.modelID"),
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
  daemonClient: BurnBarControllerDependencies["client"],
  workspaceClient: BurnBarControllerDependencies["workspaceClient"]
): Promise<void> {
  const smokeConfig =
    typeof vscode.workspace.getConfiguration === "function"
      ? vscode.workspace.getConfiguration()
      : undefined;
  const outputPath = process.env.BURNBAR_CURSOR_SMOKE_OUTPUT ?? smokeConfig?.get<string>("burnbar.cursorSmoke.outputPath");
  if (!outputPath) {
    return;
  }

  const clientID = randomUUID();
  const sessionID = randomUUID();

  try {
    await daemonClient.attach({
      clientID,
      sessionID,
      clientName: "BurnBar Cursor Smoke",
      supportedProtocolVersions: [BURNBAR_PROTOCOL_VERSION]
    });
  } catch {
    // Ignore attach failures here. `runCursorSmoke` will surface them on create/get.
  }

  try {
    await runCursorSmoke({
      outputPath,
      filePath: process.env.BURNBAR_CURSOR_SMOKE_FILE_PATH ?? smokeConfig?.get<string>("burnbar.cursorSmoke.filePath"),
      modelID: process.env.BURNBAR_CURSOR_SMOKE_MODEL ?? smokeConfig?.get<string>("burnbar.cursorSmoke.modelID"),
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
  getRunPhase
}: {
  outputPath: string;
  filePath?: string;
  modelID?: string;
  workspaceClient: BurnBarControllerDependencies["workspaceClient"];
  daemonClient: BurnBarControllerDependencies["client"];
  getRunDetail?: (runID: string) => Promise<BurnBarRunDetailResponse | undefined>;
  createRun: (
    resolvedModelID: string,
    prompt: string,
    metadata: Record<string, BurnBarJSONValue>
  ) => Promise<string>;
  getRunPhase: (runID: string) => Promise<string | undefined>;
}): Promise<void> {
  const fs = await import("node:fs/promises");

  try {
    await fs.writeFile(
      outputPath,
      JSON.stringify({ ok: false, stage: "starting" }, null, 2),
      "utf8"
    );

    const capabilities = await workspaceClient.capabilities();
    if (!capabilities.hasWorkspace) {
      throw new Error("BurnBar smoke requires an open workspace.");
    }
    if (!filePath) {
      throw new Error("BurnBar smoke requires a workspace file path.");
    }

    const readResult = await (workspaceClient as BurnBarWorkspaceRpcClient).readFile({ path: filePath });
    const catalog = await daemonClient.catalog();
    const fallbackModelID = catalog.providers
      .flatMap((provider) => provider.models.filter((model) => model.visibility === "public"))
      .at(0)?.id;
    const resolvedModelID = modelID ?? fallbackModelID;

    if (!resolvedModelID) {
      throw new Error("BurnBar smoke could not resolve a model to run.");
    }

    const replacement = buildSmokeReplacement(readResult.content);
    const runID = await createRun(
      resolvedModelID,
      `Please update the current file so the numeric constant becomes ${replacement.to}.`,
      {
        activeFilePath: filePath
      }
    );

    let phase = "unknown";
    for (let attempt = 0; attempt < 240; attempt += 1) {
      phase = (await getRunPhase(runID)) ?? phase;
      if (phase === "completed" || phase === "failed" || phase === "cancelled") {
        break;
      }
      await new Promise((resolve) => setTimeout(resolve, 250));
    }

    if (phase !== "completed") {
      const runDetail = getRunDetail ? await getRunDetail(runID) : undefined;
      throw Object.assign(new Error(`BurnBar smoke run ended in phase '${phase}'.`), {
        runID,
        phase,
        runDetail
      });
    }

    const afterResult = await (workspaceClient as BurnBarWorkspaceRpcClient).readFile({ path: filePath });
    const fileChanged = afterResult.content !== readResult.content;
    if (!fileChanged) {
      throw new Error("BurnBar smoke run completed, but the workspace file did not change.");
    }

    await fs.writeFile(
      outputPath,
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
      "utf8"
    );
  } catch (error) {
    const failure = error as {
      message?: string;
      runID?: string;
      phase?: string;
      runDetail?: BurnBarRunDetailResponse;
    };
    await fs.writeFile(
      outputPath,
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
      "utf8"
    );
    throw error;
  }
}

async function waitForDaemonReady(
  daemonClient: BurnBarControllerDependencies["client"],
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

  throw new Error(lastError ?? "Timed out waiting for the BurnBar daemon to become ready.");
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
  const from = firstLine.length > 0 ? firstLine.slice(0, Math.min(firstLine.length, 12)) : "value";
  return {
    from,
    to: `${from} (edited)`
  };
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
  if (document.uri.scheme !== "file") {
    return undefined;
  }

  const workspaceFolder = vscode.workspace.getWorkspaceFolder(document.uri);
  const path = workspaceFolder
    ? relative(workspaceFolder.uri.fsPath, document.uri.fsPath) || document.uri.fsPath
    : document.uri.fsPath;
  const replacement = buildSmokeReplacement(document.getText());

  return {
    workspaceWorkflow: {
      type: "replace_string_in_file",
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
  if (document.uri.scheme !== "file") {
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

function resolveDaemonRun(controller: BurnBarExtensionController, item?: BurnBarRunTreeItem) {
  const run = item?.run ?? controller.selectedRun;
  return run?.source === "daemon" ? run : undefined;
}

async function promptForRunModel(
  controller: BurnBarExtensionController
): Promise<(BurnBarCatalogModel & { provider: BurnBarCatalogProvider }) | undefined> {
  const models = controller.snapshot.catalog?.providers.flatMap((provider) =>
    provider.models
      .filter((model) => model.visibility === "public")
      .map((model) => ({
        ...model,
        provider
      }))
  );

  if (!models || models.length === 0) {
    await vscode.window.showWarningMessage(
      "BurnBar could not find any public daemon models. Check provider settings in the app, then refresh."
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
      title: "Choose BurnBar Model",
      placeHolder: "Select the daemon-backed model for this run",
      ignoreFocusOut: true
    }
  );

  return selection?.model;
}

async function handleApprovalResponse(
  controller: BurnBarExtensionController,
  item: BurnBarRunTreeItem | undefined,
  decision: "approve" | "reject"
): Promise<void> {
  const run = resolveDaemonRun(controller, item);
  if (!run) {
    await vscode.window.showWarningMessage(`Select a daemon-backed BurnBar run to ${decision}.`);
    return;
  }

  try {
    const detail = await controller.getRunDetail(run.id);
    const prompt = detail?.approvalRequest
      ? `${detail.approvalRequest.title}\n\n${detail.approvalRequest.message}`
      : `This BurnBar run is waiting for ${decision === "approve" ? "approval" : "rejection"}.`;
    const confirmation = await vscode.window.showWarningMessage(
      prompt,
      { modal: true },
      decision === "approve" ? "Approve" : "Reject"
    );

    if (confirmation !== (decision === "approve" ? "Approve" : "Reject")) {
      return;
    }

    await controller.respondToApproval(run.id, decision);
    await vscode.window.showInformationMessage(
      `${decision === "approve" ? "Approved" : "Rejected"} BurnBar run ${run.id}.`
    );
  } catch (error) {
    await vscode.window.showWarningMessage(
      error instanceof Error ? error.message : `BurnBar could not ${decision} the approval request.`
    );
  }
}

import type {
  BurnBarCatalog,
  BurnBarRunProjection,
  BurnBarRunStateSnapshot,
  BurnBarState,
  BurnBarUsageEvent
} from "../types";
import type { BurnBarWorkspaceCapabilities } from "../workspace/types";

export interface BurnBarHealthRow {
  id: string;
  label: string;
  value: string;
  icon: "pass" | "warning" | "pulse" | "note";
  tooltip?: string;
}

export interface BurnBarRunDetailRow {
  id: string;
  label: string;
  value: string;
}

export function projectRuns(
  state: Pick<
    BurnBarState,
    | "connectionStatus"
    | "clientAttached"
    | "health"
    | "catalog"
    | "daemonRuns"
    | "pendingToolCalls"
    | "recentUsage"
    | "lastError"
    | "runError"
    | "workspace"
    | "workspaceError"
  >
): BurnBarRunProjection[] {
  const timestamp = new Date().toISOString();

  if (state.connectionStatus === "repairing") {
    return [
      {
        id: "repairing-daemon",
        title: "Repairing local daemon",
        phase: "planning",
        note: "BurnBar is restarting the local LaunchAgent. Keep this sidebar open while the daemon socket comes back.",
        updatedAt: timestamp,
        source: "projected"
      }
    ];
  }

  if (state.connectionStatus !== "connected" || !state.health) {
    return [
      {
        id: "daemon-unavailable",
        title: "Daemon unavailable",
        phase: "failed",
        note: daemonRecoveryNote(state.lastError),
        updatedAt: timestamp,
        source: "projected"
      }
    ];
  }

  if (!state.clientAttached) {
    return [
      {
        id: "client-session-unavailable",
        title: "Client session unavailable",
        phase: "failed",
        note: state.lastError ?? "BurnBar reached the daemon but could not attach the sidebar session.",
        updatedAt: timestamp,
        source: "projected"
      }
    ];
  }

  if (state.runError) {
    return [
      {
        id: "run-state-unavailable",
        title: "Run state unavailable",
        phase: "failed",
        note: state.runError,
        updatedAt: timestamp,
        source: "projected"
      }
    ];
  }

  if (state.daemonRuns.length === 0) {
    return [
      {
        id: "empty-run-list",
        title: "No runs yet",
        phase: "idle",
        note: emptyRunListNote(state),
        updatedAt: timestamp,
        source: "projected"
      }
    ];
  }

  return state.daemonRuns.map((run) =>
    projectDaemonRun(run, state.catalog, state.recentUsage, state.pendingToolCalls, state.workspace)
  );
}

export function buildHealthRows(state: BurnBarState): BurnBarHealthRow[] {
  const providers = state.catalog?.providers.length ?? 0;
  const publicModels = visibleModels(state.catalog).length;
  const socketPath = state.health?.socketPath ?? "Unavailable";
  const catalogValue =
    state.connectionStatus === "connected"
      ? providers > 0
        ? `${providers} providers, ${publicModels} visible models`
        : "Connected, waiting for provider catalog"
      : "Unavailable";

  const rows: BurnBarHealthRow[] = [
    {
      id: "status",
      label: "Status",
      value: healthStatusLabel(state),
      icon: state.connectionStatus === "connected" ? "pass" : state.connectionStatus === "repairing" ? "pulse" : "warning"
    },
    {
      id: "session",
      label: "Session",
      value: state.connectionStatus === "connected" ? (state.clientAttached ? "Attached" : "Not attached") : "Unavailable",
      icon: state.connectionStatus !== "connected" ? "warning" : state.clientAttached ? "pass" : "warning"
    },
    {
      id: "daemon",
      label: "Daemon",
      value: state.health?.daemonVersion ?? "Unavailable",
      icon: "note"
    },
    {
      id: "protocol",
      label: "Protocol",
      value: state.health ? `v${state.health.protocolVersion}` : "Unavailable",
      icon: "note"
    },
    {
      id: "socket",
      label: "Socket",
      value: socketPath,
      icon: "note",
      tooltip: socketPath
    },
    {
      id: "catalog",
      label: "Catalog",
      value: catalogValue,
      icon: state.connectionStatus !== "connected" ? "warning" : providers > 0 ? "pass" : "pulse"
    },
    {
      id: "runs",
      label: "Runs",
      value:
        state.connectionStatus !== "connected"
          ? "Unavailable"
          : state.runError
            ? "Unavailable"
            : `${state.daemonRuns.length} tracked`,
      icon:
        state.connectionStatus !== "connected" || state.runError
          ? "warning"
          : state.daemonRuns.length > 0
            ? "pass"
            : "note"
    }
  ];

  if (state.lastError) {
    rows.push({
      id: "last-error",
      label: "Last error",
      value: state.lastError,
      icon: "warning",
      tooltip: state.lastError
    });
  }

  if (state.runError) {
    rows.push({
      id: "run-error",
      label: "Run state",
      value: state.runError,
      icon: "warning",
      tooltip: state.runError
    });
  }

  const workspaceMode = describeWorkspaceMode(state.workspace);
  rows.push({
    id: "workspace-mode",
    label: "Workspace",
    value: workspaceMode,
    icon: state.workspace
      ? !state.workspace.hasWorkspace
        ? "pulse"
        : state.workspace.gatedTools.length > 0
          ? "warning"
          : "pass"
      : "pulse"
  });

  rows.push({
    id: "workspace-tools",
    label: "Workspace tools",
    value: describeWorkspaceTools(state.workspace),
    icon: state.workspace ? state.workspace.hasWorkspace ? "note" : "pulse" : "pulse"
  });

  if (state.workspace?.explanation) {
    rows.push({
      id: "workspace-explanation",
      label: "Workspace note",
      value: state.workspace.explanation,
      icon: state.workspace.gatedTools.length > 0 ? "warning" : "note",
      tooltip: state.workspace.explanation
    });
  } else if (state.workspaceError) {
    rows.push({
      id: "workspace-error",
      label: "Workspace note",
      value: state.workspaceError,
      icon: "warning",
      tooltip: state.workspaceError
    });
  }

  const nextStep = recommendedNextStep(state);
  if (nextStep) {
    rows.push({
      id: "next-step",
      label: "Next step",
      value: nextStep,
      icon: state.connectionStatus === "connected" ? "note" : "warning",
      tooltip: nextStep
    });
  }

  return rows;
}

export function buildRunDetailRows(state: BurnBarState): BurnBarRunDetailRow[] {
  const selectedRun = state.runs.find((run) => run.id === state.selectedRunId);

  if (!selectedRun) {
    return [
      {
        id: "empty",
        label: "Run",
        value: "Select a BurnBar run to inspect state and recovery guidance."
      }
    ];
  }

  const detailForSelectedRun =
    state.selectedRunDetail?.run?.runID === selectedRun.id ? state.selectedRunDetail : undefined;
  const runSnapshot = detailForSelectedRun?.run ?? state.daemonRuns.find((run) => run.runID === selectedRun.id);
  const usage = state.recentUsage.find((entry) => entry.runID === selectedRun.id);

  const rows: BurnBarRunDetailRow[] = [
    {
      id: "title",
      label: "Run",
      value: selectedRun.title
    },
    {
      id: "phase",
      label: "Phase",
      value: humanizePhase(selectedRun.phase)
    },
    {
      id: "provider",
      label: "Provider",
      value: selectedRun.providerName ?? selectedRun.providerId ?? "Not assigned"
    },
    {
      id: "model",
      label: "Model",
      value: selectedRun.modelId ?? "Not assigned"
    },
    {
      id: "updated",
      label: "Updated",
      value: selectedRun.updatedAt
    },
    {
      id: "note",
      label: "Note",
      value: detailForSelectedRun?.approvalRequest
        ? `${detailForSelectedRun.approvalRequest.title}: ${detailForSelectedRun.approvalRequest.message}`
        : selectedRun.note
    }
  ];

  if (runSnapshot) {
    rows.push({
      id: "run-id",
      label: "Run ID",
      value: runSnapshot.runID
    });
    rows.push({
      id: "client-id",
      label: "Client",
      value: runSnapshot.clientID
    });
    rows.push({
      id: "session-id",
      label: "Session",
      value: runSnapshot.sessionID
    });
  }

  if (runSnapshot?.errorMessage) {
    rows.push({
      id: "error",
      label: "Error",
      value: runSnapshot.errorMessage
    });
  }

  if (detailForSelectedRun?.approvalRequest) {
    rows.push({
      id: "approval-tool",
      label: "Approval tool",
      value: detailForSelectedRun.approvalRequest.tool
    });
    rows.push({
      id: "approval-requested-at",
      label: "Approval requested",
      value: detailForSelectedRun.approvalRequest.requestedAt
    });
  }

  if (detailForSelectedRun?.pendingToolCall) {
    rows.push({
      id: "pending-tool",
      label: "Pending tool",
      value: detailForSelectedRun.pendingToolCall.tool
    });
    rows.push({
      id: "pending-tool-status",
      label: "Tool status",
      value: detailForSelectedRun.pendingToolCall.status
    });
  }

  if (detailForSelectedRun?.loopState?.lastDecision) {
    rows.push({
      id: "loop-iteration",
      label: "Loop iteration",
      value: String(detailForSelectedRun.loopState.iterationCount)
    });
    rows.push({
      id: "loop-action",
      label: "Loop action",
      value: detailForSelectedRun.loopState.lastDecision.action
    });
    rows.push({
      id: "loop-rationale",
      label: "Loop rationale",
      value: detailForSelectedRun.loopState.lastDecision.rationale
    });
  }

  if (detailForSelectedRun?.arbitration) {
    rows.push({
      id: "controller",
      label: "Controller",
      value: detailForSelectedRun.arbitration.activeClientID ?? "None"
    });

    if (detailForSelectedRun.arbitration.reason) {
      rows.push({
        id: "arbitration-reason",
        label: "Arbitration",
        value: detailForSelectedRun.arbitration.reason
      });
    }
  }

  if (usage) {
    rows.push({
      id: "usage",
      label: "Usage",
      value: `${usage.providerID} • in ${usage.inputTokens} / out ${usage.outputTokens} / cost ${usage.cost.toFixed(4)}`
    });
  }

  const recovery = runRecoveryStep(selectedRun.id, state);
  if (recovery) {
    rows.push({
      id: "recovery",
      label: "Recovery",
      value: recovery
    });
  }

  return rows;
}

function visibleModels(catalog?: BurnBarCatalog): Array<{ id: string }> {
  return (
    catalog?.providers.flatMap((provider) =>
      provider.models.filter((model) => model.visibility === "public")
    ) ?? []
  );
}

function projectDaemonRun(
  run: BurnBarRunStateSnapshot,
  catalog: BurnBarCatalog | undefined,
  recentUsage: BurnBarUsageEvent[],
  pendingToolCalls: BurnBarState["pendingToolCalls"],
  workspace: BurnBarState["workspace"]
): BurnBarRunProjection {
  const usage = recentUsage.find((entry) => entry.runID === run.runID);
  const pendingToolCall = pendingToolCalls.find((toolCall) => toolCall.runID === run.runID);
  const provider =
    (usage?.providerID ? catalog?.providers.find((candidate) => candidate.id === usage.providerID) : undefined) ??
    catalog?.providers.find((candidate) => candidate.models.some((model) => model.id === run.modelID));

  return {
    id: run.runID,
    title: `Run ${shortID(run.runID)}`,
    phase: run.phase,
    note: describeRunNote(run, usage, pendingToolCall, workspace),
    updatedAt: run.updatedAt,
    providerId: usage?.providerID ?? provider?.id,
    providerName: provider?.displayName ?? usage?.providerID,
    modelId: run.modelID,
    source: "daemon"
  };
}

function describeRunNote(
  run: BurnBarRunStateSnapshot,
  usage?: BurnBarUsageEvent,
  pendingToolCall?: BurnBarState["pendingToolCalls"][number],
  workspace?: BurnBarState["workspace"]
): string {
  if (run.errorMessage) {
    return run.errorMessage;
  }

  if (run.phase === "awaiting_approval") {
    if (workspace?.untrustedWorkspace) {
      return "Awaiting trust";
    }
    return "Awaiting approval";
  }

  if (run.phase === "completed" && usage) {
    return `Completed with ${usage.providerID} after ${usage.inputTokens + usage.outputTokens} billed tokens.`;
  }

  switch (run.phase) {
    case "idle":
      return "Run is queued and waiting for BurnBar to begin.";
    case "planning":
      return "BurnBar is planning the next step.";
    case "executing_tool":
      if (pendingToolCall) {
        return toolStatusLabel(pendingToolCall.tool);
      }
      return "BurnBar is executing a workspace tool step.";
    case "waiting_on_companion":
      if (pendingToolCall) {
        return toolStatusLabel(pendingToolCall.tool);
      }
      return "BurnBar is waiting for the workspace companion.";
    case "model_streaming":
      return "BurnBar is streaming model output.";
    case "completed":
      return "Run completed successfully.";
    case "failed":
      return "Run failed. Retry from the BurnBar runs view once the daemon is healthy.";
    case "cancelled":
      return "Run was cancelled.";
  }
}

function toolStatusLabel(tool: BurnBarState["pendingToolCalls"][number]["tool"]): string {
  switch (tool) {
    case "read_file":
      return "Reading file";
    case "search_workspace":
      return "Searching workspace";
    case "apply_patch":
      return "Applying patch";
    case "run_terminal":
      return "Running terminal";
  }
}

function emptyRunListNote(state: Pick<BurnBarState, "catalog" | "workspace" | "workspaceError">): string {
  if ((state.catalog?.providers.length ?? 0) === 0) {
    return "Connect BurnBar providers in the app first, then use Start Run from this view.";
  }

  if (visibleModels(state.catalog).length === 0) {
    return "Expose a public BurnBar model in the daemon catalog, then use Start Run.";
  }

  if (!state.workspace?.hasWorkspace) {
    return "Open a folder or workspace, then use Start Run to create the first BurnBar run.";
  }

  if (state.workspaceError) {
    return "The daemon is ready, but the workspace companion is still reconnecting. Refresh if this does not clear.";
  }

  return "Use Start Run from the BurnBar runs view to create the first daemon-backed run.";
}

function describeWorkspaceMode(workspace?: BurnBarWorkspaceCapabilities): string {
  if (!workspace) {
    return "Detecting workspace companion";
  }

  if (!workspace.hasWorkspace) {
    return `No workspace open • ${workspace.workspaceHost} host`;
  }

  const location = workspace.remoteWorkspace ? "Remote" : workspace.localWorkspace ? "Local" : "Detached";
  const trust = workspace.untrustedWorkspace ? "restricted" : "trusted";
  const access = workspace.readonlyWorkspace ? "read-only" : "writable";
  const virtuality = workspace.virtualWorkspace ? "virtual" : "file-backed";
  return `${location} • ${trust} • ${access} • ${virtuality} • ${workspace.workspaceHost} host`;
}

function describeWorkspaceTools(workspace?: BurnBarWorkspaceCapabilities): string {
  if (!workspace) {
    return "Waiting for companion";
  }

  if (!workspace.hasWorkspace) {
    return "Open a folder or workspace to enable BurnBar tools.";
  }

  const available = workspace.availableTools.length > 0 ? workspace.availableTools.join(", ") : "none";
  const gated = workspace.gatedTools.length > 0 ? `; gated: ${workspace.gatedTools.join(", ")}` : "";
  return `Available: ${available}${gated}`;
}

function healthStatusLabel(state: BurnBarState): string {
  switch (state.connectionStatus) {
    case "connecting":
      return "Connecting";
    case "connected":
      return "Connected";
    case "repairing":
      return "Repairing";
    case "disconnected":
      return "Disconnected";
  }
}

function humanizePhase(phase: BurnBarRunProjection["phase"]): string {
  return phase.replaceAll("_", " ");
}

function recommendedNextStep(state: BurnBarState): string | undefined {
  if (state.connectionStatus === "repairing") {
    return "Wait for the daemon socket to respond, then refresh if this state does not clear.";
  }

  if (state.connectionStatus !== "connected" || !state.health) {
    return daemonRecoveryStep(state.lastError);
  }

  if (!state.clientAttached) {
    return "Run BurnBar: Reconnect to attach a fresh daemon client session.";
  }

  if (state.runError) {
    return "Refresh the BurnBar runs view. If run state still fails to load, reconnect the BurnBar client session.";
  }

  if ((state.catalog?.providers.length ?? 0) === 0) {
    return "Check BurnBar provider settings in the app, then refresh this sidebar.";
  }

  if ((state.catalog?.providers.length ?? 0) > 0 && visibleModels(state.catalog).length === 0) {
    return "Expose a supported public model in BurnBar, then refresh.";
  }

  if (state.workspaceError) {
    return "Reload the Cursor window if the workspace companion does not reconnect.";
  }

  if (!state.workspace) {
    return "Wait for the workspace companion to register, then refresh if needed.";
  }

  if (!state.workspace.hasWorkspace) {
    return "Open a folder or workspace to enable BurnBar tools.";
  }

  if (state.workspace.untrustedWorkspace) {
    return "Trust this workspace to enable apply_patch and run_terminal.";
  }

  if (state.workspace.readonlyWorkspace) {
    return "Use a writable workspace if you need BurnBar to apply edits.";
  }

  if (state.workspace.virtualWorkspace) {
    return "Use a file-backed workspace if you need BurnBar terminal commands.";
  }

  if (state.daemonRuns.length === 0) {
    return "Use Start Run in the BurnBar runs view to begin the first daemon-backed run.";
  }

  return undefined;
}

function runRecoveryStep(runId: string, state: BurnBarState): string | undefined {
  switch (runId) {
    case "daemon-unavailable":
      return daemonRecoveryStep(state.lastError);
    case "client-session-unavailable":
      return "Run BurnBar: Reconnect to attach a fresh daemon client session.";
    case "run-state-unavailable":
      return "Refresh the BurnBar runs view. If the daemon stays healthy but run state does not load, reconnect.";
    case "empty-run-list":
      return recommendedNextStep(state);
    case "repairing-daemon":
      return "Keep Cursor open while BurnBar restarts the LaunchAgent.";
    default: {
      const selectedRun = state.runs.find((run) => run.id === runId);
      if (!selectedRun || selectedRun.source !== "daemon") {
        return undefined;
      }

      if (selectedRun.phase === "awaiting_approval") {
        return "Approve or reject this run from the BurnBar runs view.";
      }

      if (selectedRun.phase === "failed") {
        return "Retry this run from the BurnBar runs view after confirming daemon health and provider settings.";
      }

      if (selectedRun.phase === "cancelled") {
        return "Retry this run from the BurnBar runs view if you want BurnBar to start a new attempt.";
      }

      return undefined;
    }
  }
}

function shortID(value: string): string {
  return value.slice(0, 8);
}

function daemonRecoveryNote(lastError?: string): string {
  return lastError ? `${lastError} ${daemonRecoveryStep(lastError)}` : daemonRecoveryStep(undefined);
}

function daemonRecoveryStep(lastError?: string): string {
  const error = lastError?.toLowerCase() ?? "";

  if (error.includes("protocol mismatch")) {
    return "Update BurnBar so the app, daemon, and extension use the same protocol version, then reconnect.";
  }

  if (error.includes("could not negotiate a shared daemon protocol version")) {
    return "Update BurnBar so the extension and daemon share a supported protocol version, then reconnect.";
  }

  if (error.includes("timed out waiting for burnbar daemon")) {
    return "Run Reconnect once. If the daemon still does not answer, run Repair Daemon from BurnBar.";
  }

  if (error.includes("not installed yet")) {
    return "Install or repair the daemon from the BurnBar app, then reopen the BurnBar sidebar.";
  }

  if (error.includes("only available from the local macos extension host")) {
    return "Run repair from a local macOS Cursor window or use the BurnBar app.";
  }

  if (error.includes("client session mismatch") || error.includes("client '") || error.includes("observer")) {
    return "Run Reconnect so BurnBar can attach a fresh controller session to the daemon.";
  }

  if (
    error.includes("unable to reach the local burnbar daemon") ||
    error.includes("socket missing") ||
    error.includes("closed the connection before replying")
  ) {
    return "Open BurnBar, confirm the daemon is installed, then run Repair Daemon.";
  }

  if (error.includes("launchctl")) {
    return "Retry Repair Daemon from BurnBar. If launchctl still fails, repair the daemon from the app.";
  }

  return "Reconnect or repair the local BurnBar daemon to resume the sidebar shell.";
}

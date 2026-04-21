import type {
  BurnBarCatalog,
  BurnBarRunPhase,
  BurnBarRunProjection,
  OpenBurnBarState
} from '../types';
import type { BurnBarWorkspaceCapabilities } from '../workspace/types';

// ---------------------------------------------------------------------------
// View model types
// ---------------------------------------------------------------------------

export interface OpenBurnBarPanelModelOption {
  id: string;
  displayName: string;
  providerName: string;
}

export interface OpenBurnBarPanelRunCard {
  id: string;
  title: string;
  phase: string;
  phaseColor: 'muted' | 'warning' | 'active' | 'success' | 'error';
  providerName?: string;
  modelId?: string;
  updatedAt: string;
  note: string;
  source: 'daemon' | 'projected';
  hasApproval: boolean;
  isSelected: boolean;
}

export interface OpenBurnBarPanelCapabilityChip {
  label: string;
  kind: 'ready' | 'locked' | 'warning';
}

export interface OpenBurnBarPanelApprovalState {
  runId: string;
  title: string;
  message: string;
  tool: string;
  requestedAt: string;
}

export interface OpenBurnBarPanelSelectedRunDetail {
  summary: string;
  responseText?: string;
  usageText?: string;
  recoveryMessage?: string;
  arbitrationInfo?: string;
  loopDecisionText?: string;
}

export interface OpenBurnBarPanelViewModel {
  // Header
  connectionStatus: string;
  isConnected: boolean;
  isDaemonUnavailable: boolean;

  // Health / system
  daemonVersion?: string;
  protocolVersion?: number;
  socketPath?: string;

  // Workspace / trust
  isWorkspaceTrusted: boolean;
  hasWorkspace: boolean;
  workspaceDescription: string;
  capabilityChips: OpenBurnBarPanelCapabilityChip[];

  // Composer
  isComposerEnabled: boolean;
  composerDisabledReason?: string;
  selectedModelOptions: OpenBurnBarPanelModelOption[];

  // Runs
  activeRun?: OpenBurnBarPanelRunCard;
  historyRuns: OpenBurnBarPanelRunCard[];
  selectedRunId?: string;

  // Approval (for selected run)
  approvalState?: OpenBurnBarPanelApprovalState;

  // Selected run inline detail
  selectedRunDetail?: OpenBurnBarPanelSelectedRunDetail;

  // Recovery block (daemon unavailable)
  recoveryMessage?: string;

  // State flags
  catalogUnavailable: boolean;
  noRunsYet: boolean;

  // System drawer
  systemInfo: {
    daemonVersion: string;
    protocolVersion: string;
    socketPath: string;
    connectionStatus: string;
    controllerState: string;
    workspaceHost: string;
  };

  // Error
  lastError?: string;
  lastUpdatedAt?: string;

  /** macOS only: show control to launch the menu bar OpenBurnBar app */
  showOpenBurnBarApp: boolean;

  /** Compact footer line for the sidebar companion. */
  statusLineText?: string;
}

export interface BuildPanelViewModelHostContext {
  showOpenBurnBarApp?: boolean;
  sidebarStatusLineMode?: 'smart' | 'workspace' | 'models' | 'activeRun' | 'socket' | 'off';
}

// ---------------------------------------------------------------------------
// Main builder
// ---------------------------------------------------------------------------

export function buildPanelViewModel(
  state: OpenBurnBarState,
  hostContext: BuildPanelViewModelHostContext = {}
): OpenBurnBarPanelViewModel {
  const isConnected = state.connectionStatus === 'connected' && Boolean(state.health);
  const isDaemonUnavailable =
    state.connectionStatus === 'disconnected' || state.connectionStatus === 'connecting';

  const isWorkspaceTrusted = Boolean(state.workspace) && !(state.workspace?.untrustedWorkspace ?? false);
  const hasWorkspace = state.workspace?.hasWorkspace ?? false;
  const workspaceDescription = buildWorkspaceDescription(state.workspace);
  const capabilityChips = buildCapabilityChips(state.workspace);

  const publicModelOptions = buildModelOptions(state.catalog);
  const isComposerEnabled = publicModelOptions.length > 0;
  const composerDisabledReason = isComposerEnabled
    ? undefined
    : 'No daemon models available. Check provider settings in OpenBurnBar, then refresh.';

  const { activeRun, historyRuns } = buildRunCards(state);

  const approvalState = buildApprovalState(state);
  const selectedRunDetail = buildSelectedRunDetail(state);

  const recoveryMessage = buildRecoveryMessage(state);

  const noRunsYet = state.connectionStatus === 'connected' && state.daemonRuns.length === 0;
  const catalogUnavailable = state.connectionStatus === 'connected' && !state.catalog;

  const systemInfo = buildSystemInfo(state);
  const statusLineText = buildStatusLineText(
    hostContext.sidebarStatusLineMode ?? 'smart',
    {
      activeRun,
      workspaceDescription,
      modelCount: publicModelOptions.length,
      socketPath: state.health?.socketPath ?? undefined,
      daemonVersion: state.health?.daemonVersion
    }
  );

  return {
    connectionStatus: state.connectionStatus,
    isConnected,
    isDaemonUnavailable,

    daemonVersion: state.health?.daemonVersion,
    protocolVersion: state.health?.protocolVersion,
    socketPath: state.health?.socketPath ?? undefined,

    isWorkspaceTrusted,
    hasWorkspace,
    workspaceDescription,
    capabilityChips,

    isComposerEnabled,
    composerDisabledReason,
    selectedModelOptions: publicModelOptions,

    activeRun,
    historyRuns,
    selectedRunId: state.selectedRunId,

    approvalState,
    selectedRunDetail,

    recoveryMessage,

    catalogUnavailable,
    noRunsYet,

    systemInfo,

    lastError: state.lastError,
    lastUpdatedAt: state.lastUpdatedAt,

    showOpenBurnBarApp: hostContext.showOpenBurnBarApp === true,
    statusLineText
  };
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

function buildWorkspaceDescription(workspace?: BurnBarWorkspaceCapabilities): string {
  if (!workspace) {
    return 'Detecting workspace\u2026';
  }

  if (!workspace.hasWorkspace) {
    return 'No workspace open';
  }

  const location = workspace.remoteWorkspace ? 'Remote' : 'Local';
  const trust = workspace.untrustedWorkspace ? 'restricted' : 'trusted';
  return `${location} \u2022 ${trust}`;
}

function buildCapabilityChips(workspace?: BurnBarWorkspaceCapabilities): OpenBurnBarPanelCapabilityChip[] {
  if (!workspace) {
    return [{ label: 'Open a folder to enable tools', kind: 'warning' }];
  }

  if (!workspace.hasWorkspace) {
    return [{ label: 'Open a folder to enable tools', kind: 'warning' }];
  }

  const chips: OpenBurnBarPanelCapabilityChip[] = [];

  // Group read_file + search_workspace together
  const readSearchAvailable =
    workspace.availableTools.includes('read_file') ||
    workspace.availableTools.includes('search_workspace');
  const readSearchGated =
    workspace.gatedTools.includes('read_file') ||
    workspace.gatedTools.includes('search_workspace');

  if (readSearchAvailable) {
    chips.push({ label: 'Read/Search ready', kind: 'ready' });
  } else if (readSearchGated) {
    chips.push({ label: 'Read/Search locked', kind: 'locked' });
  }

  // apply_patch
  if (workspace.availableTools.includes('apply_patch')) {
    chips.push({ label: 'Edit ready', kind: 'ready' });
  } else if (workspace.gatedTools.includes('apply_patch')) {
    chips.push({ label: 'Edit locked', kind: 'locked' });
  }

  // run_terminal
  if (workspace.availableTools.includes('run_terminal')) {
    chips.push({ label: 'Terminal ready', kind: 'ready' });
  } else if (workspace.gatedTools.includes('run_terminal')) {
    chips.push({ label: 'Terminal locked', kind: 'locked' });
  }

  if (workspace.untrustedWorkspace) {
    chips.push({ label: 'Trust workspace to unlock edit + terminal', kind: 'warning' });
  }

  return chips;
}

function buildModelOptions(catalog?: BurnBarCatalog): OpenBurnBarPanelModelOption[] {
  if (!catalog) {
    return [];
  }

  const options: OpenBurnBarPanelModelOption[] = [];
  for (const provider of catalog.providers) {
    for (const model of provider.models) {
      if (model.visibility === 'public') {
        options.push({
          id: model.id,
          displayName: model.displayName,
          providerName: provider.displayName
        });
      }
    }
  }
  return options;
}

const ACTIVE_PHASES = new Set<BurnBarRunPhase>([
  'planning',
  'awaiting_approval',
  'executing_tool',
  'waiting_on_companion',
  'model_streaming'
]);

function phaseColor(phase: BurnBarRunPhase): OpenBurnBarPanelRunCard['phaseColor'] {
  switch (phase) {
  case 'planning':
  case 'executing_tool':
  case 'waiting_on_companion':
  case 'model_streaming':
    return 'active';
  case 'awaiting_approval':
    return 'warning';
  case 'completed':
    return 'success';
  case 'failed':
  case 'cancelled':
    return 'error';
  case 'idle':
  default:
    return 'muted';
  }
}

function runToCard(
  run: BurnBarRunProjection,
  selectedRunId: string | undefined,
  hasApproval: boolean
): OpenBurnBarPanelRunCard {
  return {
    id: run.id,
    title: run.title,
    phase: run.phase,
    phaseColor: phaseColor(run.phase),
    providerName: run.providerName,
    modelId: run.modelId,
    updatedAt: run.updatedAt,
    note: run.note,
    source: run.source === 'daemon' ? 'daemon' : 'projected',
    hasApproval,
    isSelected: run.id === selectedRunId
  };
}

function buildRunCards(
  state: OpenBurnBarState
): { activeRun: OpenBurnBarPanelRunCard | undefined; historyRuns: OpenBurnBarPanelRunCard[] } {
  const { runs, selectedRunId, selectedRunDetail } = state;

  if (runs.length === 0) {
    return { activeRun: undefined, historyRuns: [] };
  }

  // Determine whether a given run has a pending approval
  function hasApprovalFor(run: BurnBarRunProjection): boolean {
    return Boolean(selectedRunDetail?.approvalRequest) && run.id === selectedRunId;
  }

  // Find the active run: first run with an active phase, else selected run, else runs[0]
  let activeIndex = runs.findIndex((r) => ACTIVE_PHASES.has(r.phase));
  if (activeIndex === -1) {
    activeIndex = selectedRunId !== null && selectedRunId !== undefined ? runs.findIndex((r) => r.id === selectedRunId) : -1;
  }
  if (activeIndex === -1) {
    activeIndex = 0;
  }

  const activeRunProjection = runs[activeIndex];
  const activeRun = runToCard(activeRunProjection, selectedRunId, hasApprovalFor(activeRunProjection));

  const historyRuns: OpenBurnBarPanelRunCard[] = [];
  for (let i = 0; i < runs.length; i++) {
    if (i === activeIndex) {
      continue;
    }
    const r = runs[i];
    historyRuns.push(runToCard(r, selectedRunId, hasApprovalFor(r)));
  }

  return { activeRun, historyRuns };
}

function buildApprovalState(state: OpenBurnBarState): OpenBurnBarPanelApprovalState | undefined {
  const approval = state.selectedRunDetail?.approvalRequest;
  if (!approval) {
    return undefined;
  }

  return {
    runId: approval.runID,
    title: approval.title,
    message: approval.message,
    tool: approval.tool,
    requestedAt: approval.requestedAt
  };
}

function buildSelectedRunDetail(state: OpenBurnBarState): OpenBurnBarPanelSelectedRunDetail | undefined {
  const detail = state.selectedRunDetail;
  if (!detail) {
    return undefined;
  }

  const selectedRun = state.runs.find((r) => r.id === state.selectedRunId);
  const summary = selectedRun
    ? `${selectedRun.title} \u2022 ${selectedRun.phase}${selectedRun.note ? `: ${selectedRun.note}` : ''}`
    : detail.run
      ? `Run ${detail.run.runID.slice(0, 8)} \u2022 ${detail.run.phase}`
      : 'Run detail';

  let usageText: string | undefined;
  const usage = state.recentUsage.find((u) => u.runID === state.selectedRunId);
  if (usage) {
    usageText = `${usage.providerID} \u2022 in ${usage.inputTokens} / out ${usage.outputTokens} / cost ${usage.cost.toFixed(4)}`;
  }

  let recoveryMessage: string | undefined;
  if (detail.run?.errorMessage) {
    recoveryMessage = detail.run.errorMessage;
  }

  let arbitrationInfo: string | undefined;
  const arb = detail.arbitration;
  if (arb) {
    const controller = arb.activeClientID ?? 'None';
    const attached = arb.attachedClientIDs.length;
    arbitrationInfo = `Controller: ${controller} \u2022 ${attached} attached`;
    if (arb.reason) {
      arbitrationInfo += ` \u2022 ${arb.reason}`;
    }
  }

  let loopDecisionText: string | undefined;
  const loopState = detail.loopState;
  if (loopState?.lastDecision) {
    const tool = loopState.lastDecision.requestedTool ? ` via ${loopState.lastDecision.requestedTool}` : '';
    loopDecisionText = `Loop ${loopState.iterationCount}: ${loopState.lastDecision.action}${tool} — ${loopState.lastDecision.rationale}`;
  }

  const responseText = loopState?.lastDecision?.message ?? undefined;

  return { summary, responseText, usageText, recoveryMessage, arbitrationInfo, loopDecisionText };
}

function buildRecoveryMessage(state: OpenBurnBarState): string | undefined {
  if (state.connectionStatus === 'connected' && !state.catalog) {
    return 'No daemon models available';
  }

  if (state.connectionStatus === 'disconnected') {
    const recoveryAction =
      'Run Reconnect once. If the daemon still does not answer, run Repair Daemon from OpenBurnBar.';
    return state.lastError
      ? `Daemon disconnected: ${state.lastError} ${recoveryAction}`
      : `Daemon disconnected. ${recoveryAction}`;
  }

  if (state.connectionStatus === 'connecting') {
    return 'Connecting to the OpenBurnBar daemon\u2026';
  }

  return undefined;
}

function buildSystemInfo(
  state: OpenBurnBarState
): OpenBurnBarPanelViewModel['systemInfo'] {
  const activeClientID = state.selectedRunDetail?.arbitration?.activeClientID;
  return {
    daemonVersion: state.health?.daemonVersion ?? '\u2014',
    protocolVersion: state.health ? `v${state.health.protocolVersion}` : '\u2014',
    socketPath: state.health?.socketPath ?? '\u2014',
    connectionStatus: capitalize(state.connectionStatus),
    controllerState: activeClientID ? `Controller: ${activeClientID}` : '\u2014',
    workspaceHost: state.workspace?.workspaceHost ?? '\u2014'
  };
}

function capitalize(value: string): string {
  if (!value) {
    return value;
  }
  return value.charAt(0).toUpperCase() + value.slice(1);
}

function buildStatusLineText(
  mode: NonNullable<BuildPanelViewModelHostContext['sidebarStatusLineMode']>,
  input: {
    activeRun?: OpenBurnBarPanelRunCard;
    workspaceDescription: string;
    modelCount: number;
    socketPath?: string;
    daemonVersion?: string;
  }
): string | undefined {
  const activeRunText = input.activeRun
    ? `${input.activeRun.title} • ${input.activeRun.phase}`
    : 'No active run';
  const modelsText =
    input.modelCount === 0 ? 'No visible models' : `${input.modelCount} visible model${input.modelCount === 1 ? '' : 's'}`;
  const socketText = input.socketPath ?? (input.daemonVersion ? `Daemon v${input.daemonVersion}` : undefined);

  switch (mode) {
  case 'off':
    return undefined;
  case 'workspace':
    return input.workspaceDescription;
  case 'models':
    return modelsText;
  case 'activeRun':
    return activeRunText;
  case 'socket':
    return socketText;
  case 'smart':
  default:
    return input.activeRun
      ? activeRunText
      : [input.workspaceDescription, modelsText].filter(Boolean).join(' • ');
  }
}

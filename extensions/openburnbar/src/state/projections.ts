import type {
  BurnBarCatalog,
  BurnBarRunProjection,
  BurnBarRunStateSnapshot,
  OpenBurnBarState,
  BurnBarUsageEvent,
  BurnBarMissionSnapshot,
  BurnBarMissionPacketSnapshot,
  BurnBarPRLinkageSnapshot
} from '../types';
import type { BurnBarWorkspaceCapabilities } from '../workspace/types';

export interface BurnBarHealthRow {
  id: string;
  label: string;
  value: string;
  icon: 'pass' | 'warning' | 'pulse' | 'note';
  tooltip?: string;
}

export interface BurnBarRunDetailRow {
  id: string;
  label: string;
  value: string;
}

export function projectRuns(
  state: Pick<
    OpenBurnBarState,
    | 'connectionStatus'
    | 'clientAttached'
    | 'health'
    | 'catalog'
    | 'daemonRuns'
    | 'pendingToolCalls'
    | 'recentUsage'
    | 'lastError'
    | 'runError'
    | 'workspace'
    | 'workspaceError'
  >
): BurnBarRunProjection[] {
  const timestamp = new Date().toISOString();

  if (state.connectionStatus === 'repairing') {
    return [
      {
        id: 'repairing-daemon',
        title: 'Repairing local daemon',
        phase: 'planning',
        note: 'OpenBurnBar is restarting the local LaunchAgent. Keep this sidebar open while the daemon socket comes back.',
        updatedAt: timestamp,
        source: 'projected'
      }
    ];
  }

  if (state.connectionStatus !== 'connected' || !state.health) {
    return [
      {
        id: 'daemon-unavailable',
        title: 'Daemon unavailable',
        phase: 'failed',
        note: daemonRecoveryNote(state.lastError),
        updatedAt: timestamp,
        source: 'projected'
      }
    ];
  }

  if (!state.clientAttached) {
    return [
      {
        id: 'client-session-unavailable',
        title: 'Client session unavailable',
        phase: 'failed',
        note: state.lastError ?? 'OpenBurnBar reached the daemon but could not attach the sidebar session.',
        updatedAt: timestamp,
        source: 'projected'
      }
    ];
  }

  if (state.runError) {
    return [
      {
        id: 'run-state-unavailable',
        title: 'Run state unavailable',
        phase: 'failed',
        note: state.runError,
        updatedAt: timestamp,
        source: 'projected'
      }
    ];
  }

  if (state.daemonRuns.length === 0) {
    return [
      {
        id: 'empty-run-list',
        title: 'No runs yet',
        phase: 'idle',
        note: emptyRunListNote(state),
        updatedAt: timestamp,
        source: 'projected'
      }
    ];
  }

  return state.daemonRuns.map((run) =>
    projectDaemonRun(run, state.catalog, state.recentUsage, state.pendingToolCalls, state.workspace)
  );
}

export function buildHealthRows(state: OpenBurnBarState): BurnBarHealthRow[] {
  const providers = state.catalog?.providers.length ?? 0;
  const publicModels = visibleModels(state.catalog).length;
  const socketPath = state.health?.socketPath ?? 'Unavailable';
  const catalogValue =
    state.connectionStatus === 'connected'
      ? providers > 0
        ? `${providers} providers, ${publicModels} visible models`
        : 'Connected, waiting for provider catalog'
      : 'Unavailable';

  const rows: BurnBarHealthRow[] = [
    {
      id: 'status',
      label: 'Status',
      value: healthStatusLabel(state),
      icon: state.connectionStatus === 'connected' ? 'pass' : state.connectionStatus === 'repairing' ? 'pulse' : 'warning'
    },
    {
      id: 'session',
      label: 'Session',
      value: state.connectionStatus === 'connected' ? (state.clientAttached ? 'Attached' : 'Not attached') : 'Unavailable',
      icon: state.connectionStatus !== 'connected' ? 'warning' : state.clientAttached ? 'pass' : 'warning'
    },
    {
      id: 'daemon',
      label: 'Daemon',
      value: state.health?.daemonVersion ?? 'Unavailable',
      icon: 'note'
    },
    {
      id: 'protocol',
      label: 'Protocol',
      value: state.health ? `v${state.health.protocolVersion}` : 'Unavailable',
      icon: 'note'
    },
    {
      id: 'socket',
      label: 'Socket',
      value: socketPath,
      icon: 'note',
      tooltip: socketPath
    },
    {
      id: 'catalog',
      label: 'Catalog',
      value: catalogValue,
      icon: state.connectionStatus !== 'connected' ? 'warning' : providers > 0 ? 'pass' : 'pulse'
    },
    {
      id: 'runs',
      label: 'Runs',
      value:
        state.connectionStatus !== 'connected'
          ? 'Unavailable'
          : state.runError
            ? 'Unavailable'
            : `${state.daemonRuns.length} tracked`,
      icon:
        state.connectionStatus !== 'connected' || state.runError
          ? 'warning'
          : state.daemonRuns.length > 0
            ? 'pass'
            : 'note'
    }
  ];

  if (state.lastError) {
    rows.push({
      id: 'last-error',
      label: 'Last error',
      value: state.lastError,
      icon: 'warning',
      tooltip: state.lastError
    });
  }

  if (state.runError) {
    rows.push({
      id: 'run-error',
      label: 'Run state',
      value: state.runError,
      icon: 'warning',
      tooltip: state.runError
    });
  }

  const workspaceMode = describeWorkspaceMode(state.workspace);
  rows.push({
    id: 'workspace-mode',
    label: 'Workspace',
    value: workspaceMode,
    icon: state.workspace
      ? !state.workspace.hasWorkspace
        ? 'pulse'
        : state.workspace.gatedTools.length > 0
          ? 'warning'
          : 'pass'
      : 'pulse'
  });

  rows.push({
    id: 'workspace-tools',
    label: 'Workspace tools',
    value: describeWorkspaceTools(state.workspace),
    icon: state.workspace ? state.workspace.hasWorkspace ? 'note' : 'pulse' : 'pulse'
  });

  if (state.workspace?.explanation) {
    rows.push({
      id: 'workspace-explanation',
      label: 'Workspace note',
      value: state.workspace.explanation,
      icon: state.workspace.gatedTools.length > 0 ? 'warning' : 'note',
      tooltip: state.workspace.explanation
    });
  } else if (state.workspaceError) {
    rows.push({
      id: 'workspace-error',
      label: 'Workspace note',
      value: state.workspaceError,
      icon: 'warning',
      tooltip: state.workspaceError
    });
  }

  const nextStep = recommendedNextStep(state);
  if (nextStep) {
    rows.push({
      id: 'next-step',
      label: 'Next step',
      value: nextStep,
      icon: state.connectionStatus === 'connected' ? 'note' : 'warning',
      tooltip: nextStep
    });
  }

  return rows;
}

export function buildRunDetailRows(state: OpenBurnBarState): BurnBarRunDetailRow[] {
  const selectedRun = state.runs.find((run) => run.id === state.selectedRunId);

  if (!selectedRun) {
    return [
      {
        id: 'empty',
        label: 'Run',
        value: 'Select a OpenBurnBar run to inspect state and recovery guidance.'
      }
    ];
  }

  const detailForSelectedRun =
    state.selectedRunDetail?.run?.runID === selectedRun.id ? state.selectedRunDetail : undefined;
  const runSnapshot = detailForSelectedRun?.run ?? state.daemonRuns.find((run) => run.runID === selectedRun.id);
  const usage = state.recentUsage.find((entry) => entry.runID === selectedRun.id);

  const rows: BurnBarRunDetailRow[] = [
    {
      id: 'title',
      label: 'Run',
      value: selectedRun.title
    },
    {
      id: 'phase',
      label: 'Phase',
      value: humanizePhase(selectedRun.phase)
    },
    {
      id: 'provider',
      label: 'Provider',
      value: selectedRun.providerName ?? selectedRun.providerId ?? 'Not assigned'
    },
    {
      id: 'model',
      label: 'Model',
      value: selectedRun.modelId ?? 'Not assigned'
    },
    {
      id: 'updated',
      label: 'Updated',
      value: selectedRun.updatedAt
    },
    {
      id: 'note',
      label: 'Note',
      value: detailForSelectedRun?.approvalRequest
        ? `${detailForSelectedRun.approvalRequest.title}: ${detailForSelectedRun.approvalRequest.message}`
        : selectedRun.note
    }
  ];

  if (runSnapshot) {
    rows.push({
      id: 'run-id',
      label: 'Run ID',
      value: runSnapshot.runID
    });
    rows.push({
      id: 'client-id',
      label: 'Client',
      value: runSnapshot.clientID
    });
    rows.push({
      id: 'session-id',
      label: 'Session',
      value: runSnapshot.sessionID
    });
  }

  if (runSnapshot?.errorMessage) {
    rows.push({
      id: 'error',
      label: 'Error',
      value: runSnapshot.errorMessage
    });
  }

  if (detailForSelectedRun?.approvalRequest) {
    rows.push({
      id: 'approval-tool',
      label: 'Approval tool',
      value: detailForSelectedRun.approvalRequest.tool
    });
    rows.push({
      id: 'approval-requested-at',
      label: 'Approval requested',
      value: detailForSelectedRun.approvalRequest.requestedAt
    });
  }

  if (detailForSelectedRun?.pendingToolCall) {
    rows.push({
      id: 'pending-tool',
      label: 'Pending tool',
      value: detailForSelectedRun.pendingToolCall.tool
    });
    rows.push({
      id: 'pending-tool-status',
      label: 'Tool status',
      value: detailForSelectedRun.pendingToolCall.status
    });
  }

  if (detailForSelectedRun?.loopState?.lastDecision) {
    rows.push({
      id: 'loop-iteration',
      label: 'Loop iteration',
      value: String(detailForSelectedRun.loopState.iterationCount)
    });
    rows.push({
      id: 'loop-action',
      label: 'Loop action',
      value: detailForSelectedRun.loopState.lastDecision.action
    });
    rows.push({
      id: 'loop-rationale',
      label: 'Loop rationale',
      value: detailForSelectedRun.loopState.lastDecision.rationale
    });
  }

  if (detailForSelectedRun?.arbitration) {
    rows.push({
      id: 'controller',
      label: 'Controller',
      value: detailForSelectedRun.arbitration.activeClientID ?? 'None'
    });

    if (detailForSelectedRun.arbitration.reason) {
      rows.push({
        id: 'arbitration-reason',
        label: 'Arbitration',
        value: detailForSelectedRun.arbitration.reason
      });
    }
  }

  if (usage) {
    rows.push({
      id: 'usage',
      label: 'Usage',
      value: `${usage.providerID} • in ${usage.inputTokens} / out ${usage.outputTokens} / cost ${usage.cost.toFixed(4)}`
    });
  }

  const recovery = runRecoveryStep(selectedRun.id, state);
  if (recovery) {
    rows.push({
      id: 'recovery',
      label: 'Recovery',
      value: recovery
    });
  }

  return rows;
}

// MARK: - Mission Projections (VAL-EXT-008, VAL-CROSS-010)

// VAL-CROSS-009: Readiness reason codes for pre-dispatch execution failures
// Maps directly from daemon BurnBarExecutionReadinessCode for cross-surface parity

export type BurnBarReadinessReasonCode =
  | 'missing_credential'
  | 'invalid_repo_branch'
  | 'runtime_unavailable'
  | 'insufficient_credential_permissions';

export interface BurnBarReadinessFailure {
  code: BurnBarReadinessReasonCode;
  detail: string;
}

/**
 * Maps a readiness reason code to a human-readable display message for operator-facing UI.
 * Matches the displayMessage computed property in BurnBarReadinessFailure (Swift, app side).
 */
export function readinessDisplayMessage(failure: BurnBarReadinessFailure): string {
  switch (failure.code) {
  case 'missing_credential':
    return `Credential missing: ${failure.detail}`;
  case 'invalid_repo_branch':
    return `Repository unavailable: ${failure.detail}`;
  case 'runtime_unavailable':
    return `Runtime unavailable: ${failure.detail}`;
  case 'insufficient_credential_permissions':
    return `Insufficient permissions: ${failure.detail}`;
  default:
    return `Readiness check failed: ${failure.detail}`;
  }
}

export interface BurnBarMissionRow {
  id: string;
  title: string;
  projectSlug: string;
  status: BurnBarMissionStatus;
  recommendation: BurnBarMissionRecommendation;
  phase: BurnBarRunPhase;
  note: string;
  updatedAt: string;
  source: 'daemon' | 'projected';
  // Ownership and transfer tracking
  approved: boolean;
  approvedBy?: string;
  ownerPrincipalID?: string;
  assigneePrincipalID?: string;
  roleEligibility: BurnBarMissionRoleEligibility;
  latestAuditEventID?: string;
  latestAuditSummary?: string;
  packetsCount: number;
  activePacketID?: string;
  takeoverCount: number;
  // VAL-CROSS-009: Readiness failure for pre-dispatch execution failures
  readinessFailure?: BurnBarReadinessFailure;
  // VAL-EXT-007: PR closure linkage and closure-question state parity.
  prLinkage?: BurnBarPRLinkageSnapshot;
  closureQuestionState: string;
}

export interface BurnBarMissionRoleEligibility {
  canApprove: boolean;
  canTransferOwnership: boolean;
  canAnswerClosureQuestion: boolean;
}

export interface BurnBarMissionDetailRow {
  id: string;
  label: string;
  value: string;
}

// Daemon canonical statuses: matches BurnBarMissionStatus in OpenBurnBarCore
export type BurnBarMissionStatus =
  | 'draft'
  | 'awaiting_approval'
  | 'approved'
  | 'dispatching'
  | 'in_progress'
  | 'partially_completed'
  | 'completed'
  | 'failed'
  | 'cancelled';
export type BurnBarMissionRecommendation = 'proceed' | 'review' | 'pause';
export type BurnBarRunPhase =
  | 'idle'
  | 'planning'
  | 'executing_tool'
  | 'waiting_on_companion'
  | 'model_streaming'
  | 'completed'
  | 'failed'
  | 'cancelled'
  | 'awaiting_approval';

export type BurnBarMissionNextActionBucket = 'blockage' | 'interruption' | 'completion';

export interface BurnBarMissionNextAction {
  id: string;
  missionId: string;
  projectSlug: string;
  title: string;
  summary: string;
  bucket: BurnBarMissionNextActionBucket;
  status: BurnBarMissionStatus;
  recommendation: BurnBarMissionRecommendation;
  updatedAt: string;
}

export function buildMissionNextActions(state: OpenBurnBarState): BurnBarMissionNextAction[] {
  if (!state.daemonMissions || state.daemonMissions.length === 0) {
    return [];
  }

  return [...state.daemonMissions]
    .sort(nextActionMissionComparator)
    .map((mission) => {
      const trimmedSummary = mission.summary.trim();
      return {
        id: `next-action-${mission.id}`,
        missionId: mission.id,
        projectSlug: mission.projectSlug,
        title: nextActionTitle(mission.status),
        summary: trimmedSummary.length > 0 ? trimmedSummary : nextActionSummaryFallback(mission.status),
        bucket: nextActionBucket(mission.status),
        status: mission.status,
        recommendation: mission.recommendation,
        updatedAt: mission.updatedAt
      };
    });
}

export function buildMissionRows(state: OpenBurnBarState): BurnBarMissionRow[] {
  const timestamp = new Date().toISOString();

  if (state.connectionStatus !== 'connected' || !state.health) {
    return [
      {
        id: 'daemon-unavailable',
        title: 'Daemon unavailable',
        projectSlug: '',
        status: 'failed',
        recommendation: 'review',
        phase: 'failed',
        note: 'Mission board unavailable: daemon is not connected.',
        updatedAt: timestamp,
        source: 'projected',
        approved: false,
        roleEligibility: {
          canApprove: false,
          canTransferOwnership: false,
          canAnswerClosureQuestion: false
        },
        packetsCount: 0,
        takeoverCount: 0,
        closureQuestionState: 'Unknown'
      }
    ];
  }

  if (!state.clientAttached) {
    return [
      {
        id: 'client-session-unavailable',
        title: 'Client session unavailable',
        projectSlug: '',
        status: 'failed',
        recommendation: 'review',
        phase: 'failed',
        note: 'Mission board unavailable: client session is not attached.',
        updatedAt: timestamp,
        source: 'projected',
        approved: false,
        roleEligibility: {
          canApprove: false,
          canTransferOwnership: false,
          canAnswerClosureQuestion: false
        },
        packetsCount: 0,
        takeoverCount: 0,
        closureQuestionState: 'Unknown'
      }
    ];
  }

  if (!state.daemonMissions || state.daemonMissions.length === 0) {
    return [
      {
        id: 'empty-mission-list',
        title: 'No missions yet',
        projectSlug: '',
        status: 'awaiting_approval',
        recommendation: 'review',
        phase: 'idle',
        note: 'Use Mission Board in the OpenBurnBar app to create your first mission.',
        updatedAt: timestamp,
        source: 'projected',
        approved: false,
        roleEligibility: {
          canApprove: false,
          canTransferOwnership: false,
          canAnswerClosureQuestion: false
        },
        packetsCount: 0,
        takeoverCount: 0,
        closureQuestionState: 'No closure question pending'
      }
    ];
  }

  // Sort missions: updatedAt DESC, missionID ASC tie-break — matches daemon canonical ordering
  return [...state.daemonMissions]
    .sort((a, b) => {
      const aTime = new Date(a.updatedAt).getTime();
      const bTime = new Date(b.updatedAt).getTime();
      if (aTime !== bTime) {
        return bTime - aTime; // updatedAt DESC
      }
      return a.id.localeCompare(b.id); // missionID ASC tie-break
    })
    .map((mission) => {
      const activePacket = mission.packets.find((p) => p.status === 'in_progress' || p.status === 'pending');
      const runForMission = state.daemonRuns.find((run) =>
        mission.packets.some((packet) => packet.runID === run.runID)
      );
      const prLinkage = resolveMissionPRLinkage(mission);
      const teamFields = extractTeamCollaborationFields(mission, activePacket);

      return {
        id: mission.id,
        title: mission.title,
        projectSlug: mission.projectSlug,
        status: mission.status,
        recommendation: mission.recommendation,
        phase: runForMission?.phase ?? missionPhaseFromStatus(mission.status),
        note: describeMissionNote(mission, activePacket),
        updatedAt: mission.updatedAt,
        source: 'daemon' as const,
        approved: mission.approval?.approved ?? false,
        approvedBy: mission.approval?.approvedBy,
        ownerPrincipalID: teamFields.ownerPrincipalID,
        assigneePrincipalID: teamFields.assigneePrincipalID,
        roleEligibility: teamFields.roleEligibility,
        latestAuditEventID: teamFields.latestAuditEventID,
        latestAuditSummary: teamFields.latestAuditSummary,
        packetsCount: mission.packets.length,
        activePacketID: activePacket?.id,
        takeoverCount: mission.takeoverHistory?.length ?? 0,
        // VAL-CROSS-009: Extract readiness failure from mission metadata if present
        readinessFailure: extractReadinessFailure(mission.metadata),
        prLinkage,
        closureQuestionState: closureQuestionStateForStatus(mission.status)
      };
    });
}

/**
 * Extracts readiness failure information from mission metadata.
 * Matches the BurnBarReadinessFailure structure for cross-surface parity.
 */
function extractReadinessFailure(
  metadata?: Record<string, unknown>
): BurnBarReadinessFailure | undefined {
  if (!metadata) {
    return undefined;
  }

  const readiness = metadata.readinessFailure as
    | { code: string; detail: string }
    | undefined;

  if (!readiness?.code || !readiness?.detail) {
    return undefined;
  }

  // Validate that the code is one of the known reason codes
  const validCodes: BurnBarReadinessReasonCode[] = [
    'missing_credential',
    'invalid_repo_branch',
    'runtime_unavailable',
    'insufficient_credential_permissions'
  ];

  if (!validCodes.includes(readiness.code as BurnBarReadinessReasonCode)) {
    return undefined;
  }

  return {
    code: readiness.code as BurnBarReadinessReasonCode,
    detail: readiness.detail
  };
}

function extractTeamCollaborationFields(
  mission: BurnBarMissionSnapshot,
  activePacket?: BurnBarMissionPacketSnapshot
): {
  ownerPrincipalID?: string;
  assigneePrincipalID?: string;
  roleEligibility: BurnBarMissionRoleEligibility;
  latestAuditEventID?: string;
  latestAuditSummary?: string;
} {
  const metadata = mission.metadata ?? {};
  const ownerPrincipalID =
    metadataString(metadata, 'team_owner_id', 'owner_principal_id') ?? mission.approval?.approvedBy;
  const assigneePrincipalID =
    metadataString(metadata, 'team_assignee_id', 'assignee_principal_id') ?? activePacket?.workerName;

  const roleEligibility: BurnBarMissionRoleEligibility = {
    canApprove:
      metadataBoolean(metadata, 'role_can_approve')
      ?? (!(mission.approval?.approved ?? false) && mission.status === 'awaiting_approval'),
    canTransferOwnership:
      metadataBoolean(metadata, 'role_can_transfer')
      ?? !['completed', 'failed', 'cancelled'].includes(mission.status),
    canAnswerClosureQuestion:
      metadataBoolean(metadata, 'role_can_answer_closure')
      ?? mission.status === 'awaiting_approval'
  };

  return {
    ownerPrincipalID,
    assigneePrincipalID,
    roleEligibility,
    latestAuditEventID: metadataString(metadata, 'audit_event_id', 'last_audit_event_id'),
    latestAuditSummary: metadataString(metadata, 'audit_summary', 'last_audit_summary')
  };
}

function metadataString(
  metadata: Record<string, unknown>,
  ...keys: string[]
): string | undefined {
  for (const key of keys) {
    const value = metadata[key];
    if (typeof value === 'string') {
      const trimmed = value.trim();
      if (trimmed.length > 0) {
        return trimmed;
      }
    }
  }
  return undefined;
}

function metadataBoolean(
  metadata: Record<string, unknown>,
  key: string
): boolean | undefined {
  const value = metadata[key];
  return typeof value === 'boolean' ? value : undefined;
}

export function buildMissionDetailRows(state: OpenBurnBarState, missionId?: string): BurnBarMissionDetailRow[] {
  if (!missionId) {
    return [
      {
        id: 'empty',
        label: 'Mission',
        value: 'Select a mission from the board to inspect details.'
      }
    ];
  }

  const mission = state.daemonMissions?.find((m) => m.id === missionId);
  if (!mission) {
    return [
      {
        id: 'not-found',
        label: 'Mission',
        value: 'Mission not found.'
      }
    ];
  }

  const rows: BurnBarMissionDetailRow[] = [
    {
      id: 'title',
      label: 'Mission',
      value: mission.title
    },
    {
      id: 'project',
      label: 'Project',
      value: mission.projectSlug
    },
    {
      id: 'status',
      label: 'Status',
      value: mission.status
    },
    {
      id: 'recommendation',
      label: 'Recommendation',
      value: mission.recommendation
    },
    {
      id: 'summary',
      label: 'Summary',
      value: mission.summary
    },
    {
      id: 'created-at',
      label: 'Created',
      value: mission.createdAt
    },
    {
      id: 'updated-at',
      label: 'Updated',
      value: mission.updatedAt
    },
    {
      id: 'approval',
      label: 'Approved',
      value: mission.approval?.approved ? `Yes by ${mission.approval.approvedBy ?? 'unknown'}` : 'Pending'
    },
    {
      id: 'closure-question-state',
      label: 'Closure question',
      value: closureQuestionStateForStatus(mission.status)
    }
  ];

  const prLinkage = resolveMissionPRLinkage(mission);
  if (prLinkage) {
    rows.push({
      id: 'pr-linkage',
      label: 'Pull request',
      value: `${prLinkage.repository} #${prLinkage.prNumberOrID}`
    });
    rows.push({
      id: 'pr-state',
      label: 'PR state',
      value: prLinkage.state
    });
    rows.push({
      id: 'pr-url',
      label: 'PR URL',
      value: prLinkage.url
    });
    rows.push({
      id: 'pr-merged',
      label: 'PR merged',
      value: prLinkage.state === 'merged' ? 'Yes' : 'No'
    });
  }

  if (mission.packets.length > 0) {
    rows.push({
      id: 'packets',
      label: 'Packets',
      value: `${mission.packets.length} total`
    });

    const activePacket = mission.packets.find((p) => p.status === 'in_progress');
    if (activePacket) {
      rows.push({
        id: 'active-packet',
        label: 'Active packet',
        value: `${activePacket.objective} (${activePacket.status})`
      });
    }
  }

  if (mission.burnRecords && mission.burnRecords.length > 0) {
    const totalBurn = mission.burnRecords.reduce((sum, record) => sum + record.amount, 0);
    rows.push({
      id: 'burn',
      label: 'Total burn',
      value: `${totalBurn.toFixed(4)}`
    });
  }

  if (mission.takeoverHistory && mission.takeoverHistory.length > 0) {
    rows.push({
      id: 'takeovers',
      label: 'Takeovers',
      value: `${mission.takeoverHistory.length} total`
    });
  }

  return rows;
}

function missionPhaseFromStatus(status: BurnBarMissionStatus): BurnBarRunPhase {
  switch (status) {
  case 'in_progress':
    return 'executing_tool';
  case 'dispatching':
    return 'executing_tool';
  case 'awaiting_approval':
    return 'awaiting_approval';
  case 'completed':
    return 'completed';
  case 'failed':
    return 'failed';
  case 'cancelled':
    return 'cancelled';
  case 'partially_completed':
    return 'model_streaming';
  case 'approved':
    return 'planning';
  case 'draft':
    return 'planning';
  default:
    return 'idle';
  }
}

function nextActionMissionComparator(
  lhs: BurnBarMissionSnapshot,
  rhs: BurnBarMissionSnapshot
): number {
  const bucketDelta = nextActionBucketRank(nextActionBucket(lhs.status)) - nextActionBucketRank(nextActionBucket(rhs.status));
  if (bucketDelta !== 0) {
    return bucketDelta;
  }

  const statusDelta = nextActionStatusRank(lhs.status) - nextActionStatusRank(rhs.status);
  if (statusDelta !== 0) {
    return statusDelta;
  }

  const lhsTime = new Date(lhs.updatedAt).getTime();
  const rhsTime = new Date(rhs.updatedAt).getTime();
  if (lhsTime !== rhsTime) {
    return rhsTime - lhsTime;
  }

  return lhs.id.localeCompare(rhs.id);
}

function nextActionBucket(status: BurnBarMissionStatus): BurnBarMissionNextActionBucket {
  switch (status) {
  case 'failed':
    return 'blockage';
  case 'completed':
  case 'cancelled':
    return 'completion';
  case 'draft':
  case 'awaiting_approval':
  case 'approved':
  case 'dispatching':
  case 'in_progress':
  case 'partially_completed':
  default:
    return 'interruption';
  }
}

function nextActionBucketRank(bucket: BurnBarMissionNextActionBucket): number {
  switch (bucket) {
  case 'blockage': return 0;
  case 'interruption': return 1;
  case 'completion': return 2;
  default: return 3;
  }
}

function nextActionStatusRank(status: BurnBarMissionStatus): number {
  switch (status) {
  case 'failed': return 0;
  case 'awaiting_approval': return 1;
  case 'partially_completed': return 2;
  case 'in_progress': return 3;
  case 'dispatching': return 4;
  case 'approved': return 5;
  case 'draft': return 6;
  case 'completed': return 7;
  case 'cancelled': return 8;
  default: return 9;
  }
}

function nextActionTitle(status: BurnBarMissionStatus): string {
  switch (status) {
  case 'failed': return 'Resolve blocker';
  case 'awaiting_approval': return 'Approve mission';
  case 'partially_completed': return 'Resume interrupted mission';
  case 'in_progress':
  case 'dispatching':
    return 'Monitor active mission';
  case 'approved':
  case 'draft':
    return 'Start mission execution';
  case 'completed':
    return 'Review completion';
  case 'cancelled':
    return 'Review cancellation';
  default:
    return 'Review mission state';
  }
}

function nextActionSummaryFallback(status: BurnBarMissionStatus): string {
  switch (status) {
  case 'failed':
    return 'Clear the blocker and resume execution.';
  case 'awaiting_approval':
    return 'Operator approval is required before dispatch can continue.';
  case 'partially_completed':
    return 'Mission work was interrupted and still needs closure.';
  case 'in_progress':
  case 'dispatching':
    return 'Mission is active; watch for the next checkpoint.';
  case 'approved':
  case 'draft':
    return 'Mission is ready to begin execution.';
  case 'completed':
    return 'Mission closed successfully; review closure evidence.';
  case 'cancelled':
    return 'Mission was cancelled; confirm whether it should be reopened.';
  default:
    return 'Review current mission status.';
  }
}

function describeMissionNote(
  mission: BurnBarMissionSnapshot,
  activePacket?: BurnBarMissionPacketSnapshot
): string {
  const prLinkage = resolveMissionPRLinkage(mission);

  if (mission.status === 'completed') {
    const completedPackets = mission.packets.filter((p) => p.status === 'completed').length;
    if (prLinkage) {
      return `Completed: ${completedPackets}/${mission.packets.length} packets done. PR ${prLinkage.state} (${prLinkage.prNumberOrID}).`;
    }
    return `Completed: ${completedPackets}/${mission.packets.length} packets done.`;
  }

  if (mission.status === 'failed') {
    return 'Mission failed. Check packet failures.';
  }

  if (activePacket) {
    return `Active: ${activePacket.objective}`;
  }

  if (mission.status === 'awaiting_approval') {
    return 'Mission awaiting operator approval.';
  }

  if (mission.status === 'dispatching' || mission.status === 'in_progress') {
    return 'Mission is running with no active packet.';
  }

  return `${mission.packets.length} packet(s), status: ${mission.status}`;
}

function closureQuestionStateForStatus(status: BurnBarMissionStatus): string {
  switch (status) {
  case 'awaiting_approval':
    return 'Pending closure approval question';
  case 'completed':
    return 'No closure question pending';
  case 'failed':
  case 'cancelled':
    return 'Closure unresolved';
  case 'draft':
  case 'approved':
  case 'dispatching':
  case 'in_progress':
  case 'partially_completed':
  default:
    return 'Closure in progress';
  }
}

function resolveMissionPRLinkage(mission: BurnBarMissionSnapshot): BurnBarPRLinkageSnapshot | undefined {
  if (mission.prLinkage) {
    return mission.prLinkage;
  }

  const latestResult = [...mission.results]
    .sort((lhs, rhs) => Date.parse(rhs.createdAt) - Date.parse(lhs.createdAt))[0];
  if (latestResult?.prLinkage) {
    return latestResult.prLinkage;
  }

  return parsePRLinkageFromMetadata(mission.metadata);
}

function parsePRLinkageFromMetadata(
  metadata?: Record<string, unknown>
): BurnBarPRLinkageSnapshot | undefined {
  if (!metadata) {
    return undefined;
  }

  const nested = asObject(metadata.pr_linkage) ?? asObject(metadata.prLinkage) ?? asObject(metadata.pull_request);
  const source = nested ?? metadata;

  const repository = asString(source.repository) ?? asString(source.pr_repository);
  const prNumberOrID = asString(source.prNumberOrID) ?? asString(source.pr_number_or_id) ?? asString(source.pr_id);
  const url = asString(source.url) ?? asString(source.pr_url);
  if (!repository || !prNumberOrID || !url) {
    return undefined;
  }

  const mergeCommitSHA = asString(source.mergeCommitSHA) ?? asString(source.pr_merge_commit_sha);
  const mergedAt = asString(source.mergedAt) ?? asString(source.pr_merged_at);
  const closedAt = asString(source.closedAt) ?? asString(source.pr_closed_at);
  const mergedSignal =
    (asBoolean(source.isMerged) ?? asBoolean(source.pr_is_merged) ?? false)
    || Boolean(mergeCommitSHA)
    || Boolean(mergedAt);
  const state = normalizePRState(
    asString(source.state) ?? asString(source.pr_state),
    mergedSignal,
    Boolean(closedAt)
  );

  return {
    schemaVersion: asNumber(source.schemaVersion) ?? 1,
    repository,
    prNumberOrID,
    url,
    state,
    mergeCommitSHA: mergeCommitSHA ?? undefined,
    mergedAt: mergedAt ?? undefined,
    closedAt: closedAt ?? undefined
  };
}

function normalizePRState(
  rawState: string | undefined,
  mergedSignal: boolean,
  closedSignal: boolean
): BurnBarPRLinkageSnapshot['state'] {
  const normalized = rawState?.trim().toLowerCase();
  if (normalized === 'opened' || normalized === 'open') {
    return 'opened';
  }
  if (normalized === 'merged') {
    return 'merged';
  }
  if (normalized === 'closed') {
    return mergedSignal ? 'merged' : 'closed';
  }
  if (mergedSignal) {
    return 'merged';
  }
  if (closedSignal) {
    return 'closed';
  }
  return 'opened';
}

function asObject(value: unknown): Record<string, unknown> | undefined {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return undefined;
  }
  return value as Record<string, unknown>;
}

function asString(value: unknown): string | undefined {
  if (typeof value !== 'string') {
    return undefined;
  }
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function asBoolean(value: unknown): boolean | undefined {
  if (typeof value === 'boolean') {
    return value;
  }
  if (typeof value === 'number') {
    return value !== 0;
  }
  return undefined;
}

function asNumber(value: unknown): number | undefined {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === 'string') {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) {
      return parsed;
    }
  }
  return undefined;
}

function visibleModels(catalog?: BurnBarCatalog): Array<{ id: string }> {
  return (
    catalog?.providers.flatMap((provider) =>
      provider.models.filter((model) => model.visibility === 'public')
    ) ?? []
  );
}

function projectDaemonRun(
  run: BurnBarRunStateSnapshot,
  catalog: BurnBarCatalog | undefined,
  recentUsage: BurnBarUsageEvent[],
  pendingToolCalls: OpenBurnBarState['pendingToolCalls'],
  workspace: OpenBurnBarState['workspace']
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
    source: 'daemon'
  };
}

function describeRunNote(
  run: BurnBarRunStateSnapshot,
  usage?: BurnBarUsageEvent,
  pendingToolCall?: OpenBurnBarState['pendingToolCalls'][number],
  workspace?: OpenBurnBarState['workspace']
): string {
  if (run.errorMessage) {
    return run.errorMessage;
  }

  if (run.phase === 'awaiting_approval') {
    if (workspace?.untrustedWorkspace) {
      return 'Awaiting trust';
    }
    return 'Awaiting approval';
  }

  if (run.phase === 'completed' && usage) {
    return `Completed with ${usage.providerID} after ${usage.inputTokens + usage.outputTokens} billed tokens.`;
  }

  switch (run.phase) {
  case 'idle':
    return 'Run is queued and waiting for OpenBurnBar to begin.';
  case 'planning':
    return 'OpenBurnBar is planning the next step.';
  case 'executing_tool':
    if (pendingToolCall) {
      return toolStatusLabel(pendingToolCall.tool);
    }
    return 'OpenBurnBar is executing a workspace tool step.';
  case 'waiting_on_companion':
    if (pendingToolCall) {
      return toolStatusLabel(pendingToolCall.tool);
    }
    return 'OpenBurnBar is waiting for the workspace companion.';
  case 'model_streaming':
    return 'OpenBurnBar is streaming model output.';
  case 'completed':
    return 'Run completed successfully.';
  case 'failed':
    return 'Run failed. Retry from the OpenBurnBar runs view once the daemon is healthy.';
  case 'cancelled':
    return 'Run was cancelled.';
  default:
    return `Unknown phase: ${run.phase}`;
  }
}

function toolStatusLabel(tool: OpenBurnBarState['pendingToolCalls'][number]['tool']): string {
  switch (tool) {
  case 'read_file':
    return 'Reading file';
  case 'search_workspace':
    return 'Searching workspace';
  case 'apply_patch':
    return 'Applying patch';
  case 'run_terminal':
    return 'Running terminal';
  default:
    return `Unknown tool: ${tool}`;
  }
}

function emptyRunListNote(state: Pick<OpenBurnBarState, 'catalog' | 'workspace' | 'workspaceError'>): string {
  if ((state.catalog?.providers.length ?? 0) === 0) {
    return 'Connect OpenBurnBar providers in the app first, then use Start Run from this view.';
  }

  if (visibleModels(state.catalog).length === 0) {
    return 'Expose a public OpenBurnBar model in the daemon catalog, then use Start Run.';
  }

  if (!state.workspace?.hasWorkspace) {
    return 'Open a folder or workspace, then use Start Run to create the first OpenBurnBar run.';
  }

  if (state.workspaceError) {
    return 'The daemon is ready, but the workspace companion is still reconnecting. Refresh if this does not clear.';
  }

  return 'Use Start Run from the OpenBurnBar runs view to create the first daemon-backed run.';
}

function describeWorkspaceMode(workspace?: BurnBarWorkspaceCapabilities): string {
  if (!workspace) {
    return 'Detecting workspace companion';
  }

  if (!workspace.hasWorkspace) {
    return `No workspace open • ${workspace.workspaceHost} host`;
  }

  const location = workspace.remoteWorkspace ? 'Remote' : workspace.localWorkspace ? 'Local' : 'Detached';
  const trust = workspace.untrustedWorkspace ? 'restricted' : 'trusted';
  const access = workspace.readonlyWorkspace ? 'read-only' : 'writable';
  const virtuality = workspace.virtualWorkspace ? 'virtual' : 'file-backed';
  return `${location} • ${trust} • ${access} • ${virtuality} • ${workspace.workspaceHost} host`;
}

function describeWorkspaceTools(workspace?: BurnBarWorkspaceCapabilities): string {
  if (!workspace) {
    return 'Waiting for companion';
  }

  if (!workspace.hasWorkspace) {
    return 'Open a folder or workspace to enable OpenBurnBar tools.';
  }

  const available = workspace.availableTools.length > 0 ? workspace.availableTools.join(', ') : 'none';
  const gated = workspace.gatedTools.length > 0 ? `; gated: ${workspace.gatedTools.join(', ')}` : '';
  return `Available: ${available}${gated}`;
}

function healthStatusLabel(state: OpenBurnBarState): string {
  switch (state.connectionStatus) {
  case 'connecting':
    return 'Connecting';
  case 'connected':
    return 'Connected';
  case 'repairing':
    return 'Repairing';
  case 'disconnected':
    return 'Disconnected';
  default:
    return `Unknown status: ${state.connectionStatus}`;
  }
}

function humanizePhase(phase: BurnBarRunProjection['phase']): string {
  return phase.replaceAll('_', ' ');
}

function recommendedNextStep(state: OpenBurnBarState): string | undefined {
  if (state.connectionStatus === 'repairing') {
    return 'Wait for the daemon socket to respond, then refresh if this state does not clear.';
  }

  if (state.connectionStatus !== 'connected' || !state.health) {
    return daemonRecoveryStep(state.lastError);
  }

  if (!state.clientAttached) {
    return 'Run OpenBurnBar: Reconnect to attach a fresh daemon client session.';
  }

  if (state.runError) {
    return 'Refresh the OpenBurnBar runs view. If run state still fails to load, reconnect the OpenBurnBar client session.';
  }

  if ((state.catalog?.providers.length ?? 0) === 0) {
    return 'Check OpenBurnBar provider settings in the app, then refresh this sidebar.';
  }

  if ((state.catalog?.providers.length ?? 0) > 0 && visibleModels(state.catalog).length === 0) {
    return 'Expose a supported public model in OpenBurnBar, then refresh.';
  }

  if (state.workspaceError) {
    return 'Reload the Cursor window if the workspace companion does not reconnect.';
  }

  if (!state.workspace) {
    return 'Wait for the workspace companion to register, then refresh if needed.';
  }

  if (!state.workspace.hasWorkspace) {
    return 'Open a folder or workspace to enable OpenBurnBar tools.';
  }

  if (state.workspace.untrustedWorkspace) {
    return 'Trust this workspace to enable apply_patch and run_terminal.';
  }

  if (state.workspace.readonlyWorkspace) {
    return 'Use a writable workspace if you need OpenBurnBar to apply edits.';
  }

  if (state.workspace.virtualWorkspace) {
    return 'Use a file-backed workspace if you need OpenBurnBar terminal commands.';
  }

  if (state.daemonRuns.length === 0) {
    return 'Use Start Run in the OpenBurnBar runs view to begin the first daemon-backed run.';
  }

  return undefined;
}

function runRecoveryStep(runId: string, state: OpenBurnBarState): string | undefined {
  switch (runId) {
  case 'daemon-unavailable':
    return daemonRecoveryStep(state.lastError);
  case 'client-session-unavailable':
    return 'Run OpenBurnBar: Reconnect to attach a fresh daemon client session.';
  case 'run-state-unavailable':
    return 'Refresh the OpenBurnBar runs view. If the daemon stays healthy but run state does not load, reconnect.';
  case 'empty-run-list':
    return recommendedNextStep(state);
  case 'repairing-daemon':
    return 'Keep Cursor open while OpenBurnBar restarts the LaunchAgent.';
  default: {
    const selectedRun = state.runs.find((run) => run.id === runId);
    if (!selectedRun || selectedRun.source !== 'daemon') {
      return undefined;
    }

    if (selectedRun.phase === 'awaiting_approval') {
      return 'Approve or reject this run from the OpenBurnBar runs view.';
    }

    if (selectedRun.phase === 'failed') {
      return 'Retry this run from the OpenBurnBar runs view after confirming daemon health and provider settings.';
    }

    if (selectedRun.phase === 'cancelled') {
      return 'Retry this run from the OpenBurnBar runs view if you want OpenBurnBar to start a new attempt.';
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
  const error = lastError?.toLowerCase() ?? '';

  if (error.includes('protocol mismatch')) {
    return 'Update OpenBurnBar so the app, daemon, and extension use the same protocol version, then reconnect.';
  }

  if (error.includes('could not negotiate a shared daemon protocol version')) {
    return 'Update OpenBurnBar so the extension and daemon share a supported protocol version, then reconnect.';
  }

  if (error.includes('timed out waiting for openburnbar daemon')) {
    return 'Run Reconnect once. If the daemon still does not answer, run Repair Daemon from OpenBurnBar.';
  }

  if (error.includes('not installed yet')) {
    return 'Install or repair the daemon from the OpenBurnBar app, then reopen the OpenBurnBar sidebar.';
  }

  if (error.includes('only available from the local macos extension host')) {
    return 'Run repair from a local macOS Cursor window or use the OpenBurnBar app.';
  }

  if (error.includes('client session mismatch') || error.includes("client '") || error.includes('observer')) {
    return 'Run Reconnect so OpenBurnBar can attach a fresh controller session to the daemon.';
  }

  if (
    error.includes('unable to reach the local openburnbar daemon') ||
    error.includes('socket missing') ||
    error.includes('closed the connection before replying')
  ) {
    return 'Open OpenBurnBar, confirm the daemon is installed, then run Repair Daemon.';
  }

  if (error.includes('launchctl')) {
    return 'Retry Repair Daemon from OpenBurnBar. If launchctl still fails, repair the daemon from the app.';
  }

  return 'Reconnect or repair the local OpenBurnBar daemon to resume the sidebar shell.';
}

export const BURNBAR_PROTOCOL_VERSION = 1;
export const BURNBAR_RECONNECT_INTERVAL_MS = 15_000;

import type { BurnBarWorkspaceCapabilities } from './workspace/types';

export type BurnBarRPCMethod =
  | 'daemon.health'
  | 'daemon.catalog'
  | 'daemon.config.get'
  | 'daemon.usage.recent'
  | 'daemon.search.query'
  | 'run.create'
  | 'run.list'
  | 'run.get'
  | 'run.poll'
  | 'run.cancel'
  | 'run.retry'
  | 'workspace.executeTool'
  | 'workspace.toolResult'
  | 'approval.respond'
  | 'client.attach'
  | 'client.claimControl'
  | 'client.detach';
export type BurnBarConnectionStatus =
  | 'connecting'
  | 'connected'
  | 'disconnected'
  | 'repairing';
export type BurnBarRunPhase =
  | 'idle'
  | 'planning'
  | 'awaiting_approval'
  | 'executing_tool'
  | 'waiting_on_companion'
  | 'model_streaming'
  | 'completed'
  | 'failed'
  | 'cancelled';

export type OpenBurnBarApprovalDecision = 'approve' | 'reject' | 'cancel';
export type BurnBarToolKind = 'read_file' | 'search_workspace' | 'apply_patch' | 'run_terminal';

export type BurnBarJSONValue =
  | string
  | number
  | boolean
  | null
  | BurnBarJSONValue[]
  | {
      [key: string]: BurnBarJSONValue;
    };

export interface BurnBarRPCRequestEnvelope {
  id: string;
  method: BurnBarRPCMethod;
}

export interface BurnBarRPCRequestEnvelopeWithParams<Params> extends BurnBarRPCRequestEnvelope {
  params: Params;
}

export interface BurnBarRPCError {
  code: number;
  message: string;
}

export interface BurnBarRPCResponseEnvelope<Result> {
  id: string;
  protocolVersion: number;
  result?: Result;
  error?: BurnBarRPCError;
}

export interface BurnBarHealthResponse {
  ok: boolean;
  daemonVersion: string;
  protocolVersion: number;
  socketPath?: string | null;
}

/** Matches `BurnBarSearchQueryRequest` in OpenBurnBarCore. */
export interface BurnBarSearchQueryParams {
  query: string;
  providerRaw?: string | null;
  projectName?: string | null;
  dateRangeStartEpoch?: number | null;
  dateRangeEndEpoch?: number | null;
  resultLimit?: number;
}

export interface BurnBarIndexedSearchHit {
  chunkID: string;
  sourceKind: string;
  sourceID: string;
  title: string;
  snippet: string;
  provider?: string | null;
  projectName?: string | null;
}

/** Matches `BurnBarSearchQueryResult` in OpenBurnBarCore. */
export interface BurnBarSearchQueryDaemonResult {
  plan: {
    mode: string;
    lexicalFTSQuery: string;
    semanticText: string;
    aggregatePatterns: string[];
    note?: string | null;
  };
  aggregateOccurrenceCount?: number | null;
  hits: BurnBarIndexedSearchHit[];
  degradedMessage?: string | null;
}

export interface BurnBarCatalogModelPricing {
  inputPerMToken: number;
  outputPerMToken: number;
  cacheReadPerMToken: number;
}

export interface BurnBarCatalogModel {
  id: string;
  displayName: string;
  visibility: 'public' | 'hidden' | 'internal';
  aliases: string[];
  pricing: BurnBarCatalogModelPricing;
}

export interface BurnBarCatalogProvider {
  id: string;
  displayName: string;
  baseURL: string;
  visibility: 'public' | 'hidden' | 'internal';
  capabilities: string[];
  models: BurnBarCatalogModel[];
}

export interface BurnBarCatalog {
  schemaVersion: number;
  providers: BurnBarCatalogProvider[];
}

export interface BurnBarCatalogResponse {
  catalog: BurnBarCatalog;
}

export interface BurnBarProviderSettings {
  providerID: string;
  isEnabled: boolean;
  baseURL: string;
  preferredModelIDs: string[];
}

export interface BurnBarProviderConfigurationSnapshot {
  providers: BurnBarProviderSettings[];
}

export interface BurnBarConfigResponse {
  snapshot: BurnBarProviderConfigurationSnapshot;
}

export interface BurnBarRecentUsageRequest {
  limit: number;
}

export interface BurnBarUsageEvent {
  runID?: string | null;
  providerID: string;
  modelID: string;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cost: number;
  recordedAt: string;
}

export interface BurnBarRecentUsageResponse {
  usage: BurnBarUsageEvent[];
}

export interface BurnBarClientAttachRequest {
  clientID: string;
  sessionID: string;
  clientName: string;
  supportedProtocolVersions: number[];
}

export interface BurnBarClientAttachResponse {
  attachedClientID: string;
  negotiatedProtocolVersion?: number | null;
}

export interface BurnBarClientClaimControlRequest {
  clientID: string;
  sessionID: string;
}

export interface BurnBarClientDetachRequest {
  clientID: string;
  sessionID: string;
}

export interface BurnBarClientArbitrationSnapshot {
  activeClientID?: string | null;
  attachedClientIDs: string[];
  reason?: string | null;
}

export interface BurnBarRunStateSnapshot {
  runID: string;
  clientID: string;
  sessionID: string;
  phase: BurnBarRunPhase;
  modelID: string;
  updatedAt: string;
  errorMessage?: string | null;
  activeApprovalID?: string | null;
}

export type BurnBarToolExecutionErrorCode =
  | 'trust_gated'
  | 'no_workspace'
  | 'remote_unsupported'
  | 'apply_failed'
  | 'terminal_failed'
  | 'unknown';

export interface BurnBarToolExecutionError {
  code: BurnBarToolExecutionErrorCode;
  message: string;
}

export type BurnBarToolCallStatus = 'pending' | 'in_progress' | 'completed' | 'failed' | 'cancelled';

export interface BurnBarToolCallSnapshot {
  callID: string;
  runID: string;
  tool: BurnBarToolKind;
  arguments: BurnBarJSONValue;
  status: BurnBarToolCallStatus;
  requestedBy: string;
  requestedAt: string;
  claimedBy?: string | null;
  claimedAt?: string | null;
  completedAt?: string | null;
  output?: BurnBarJSONValue | null;
  error?: BurnBarToolExecutionError | null;
}

export type BurnBarAgentLoopActionKind =
  | 'complete'
  | 'search_workspace'
  | 'read_file'
  | 'apply_patch'
  | 'run_terminal'
  | 'request_approval'
  | 'fail';

export interface BurnBarAgentContextSnapshot {
  candidatePaths: string[];
  activeFilePath?: string | null;
  lastReadFilePath?: string | null;
  lastReadContent?: string | null;
  searchHints: string[];
  replacementTargetPath?: string | null;
  searchResultPaths: string[];
}

export interface BurnBarAgentLoopDecision {
  action: BurnBarAgentLoopActionKind;
  requestedTool?: BurnBarToolKind | null;
  arguments?: BurnBarJSONValue | null;
  rationale: string;
  message?: string | null;
}

export interface BurnBarAgentLoopState {
  iterationCount: number;
  lastDecision?: BurnBarAgentLoopDecision | null;
  lastContextSnapshot?: BurnBarAgentContextSnapshot | null;
  lastExecutedTool?: BurnBarToolKind | null;
  terminalPending: boolean;
}

export interface BurnBarRunCreateRequest {
  clientID: string;
  sessionID: string;
  prompt: string;
  modelID: string;
  metadata?: Record<string, BurnBarJSONValue>;
}

export interface BurnBarRunCreateResponse {
  runID: string;
  phase: BurnBarRunPhase;
}

export interface BurnBarRunListRequest {
  clientID: string;
}

export interface BurnBarRunListResponse {
  runs: BurnBarRunStateSnapshot[];
}

export interface BurnBarRunGetRequest {
  runID: string;
  clientID: string;
}

export interface BurnBarRunPollRequest {
  clientID: string;
  sessionID: string;
  runID?: string;
}

export interface BurnBarRunEventBatch {
  runs: BurnBarRunStateSnapshot[];
  approvals: OpenBurnBarApprovalRequest[];
  pendingToolCalls: BurnBarToolCallSnapshot[];
  arbitration?: BurnBarClientArbitrationSnapshot | null;
  emittedAt: string;
}

export interface BurnBarRunCancelRequest {
  runID: string;
  clientID: string;
  reason?: string;
}

export interface BurnBarRunRetryRequest {
  runID: string;
  clientID: string;
}

export interface OpenBurnBarApprovalRequest {
  approvalID: string;
  runID: string;
  tool: BurnBarToolKind;
  title: string;
  message: string;
  requestedAt: string;
}

export interface OpenBurnBarApprovalResponse {
  approvalID: string;
  clientID: string;
  decision: OpenBurnBarApprovalDecision;
  note?: string;
  respondedAt: number;
}

export interface OpenBurnBarApprovalRespondRequest {
  response: OpenBurnBarApprovalResponse;
}

export interface BurnBarRunDetailResponse {
  run?: BurnBarRunStateSnapshot | null;
  approvalRequest?: OpenBurnBarApprovalRequest | null;
  pendingToolCall?: BurnBarToolCallSnapshot | null;
  loopState?: BurnBarAgentLoopState | null;
  arbitration?: BurnBarClientArbitrationSnapshot | null;
}

export interface BurnBarToolExecutionRequest {
  clientID: string;
  sessionID: string;
  runID?: string;
}

export type BurnBarToolExecutionDisposition = 'dispatched' | 'no_pending_tool_call' | 'run_not_found';

export interface BurnBarToolExecutionResponse {
  disposition: BurnBarToolExecutionDisposition;
  toolCall?: BurnBarToolCallSnapshot | null;
}

export interface BurnBarToolResultSubmissionRequest {
  clientID: string;
  sessionID: string;
  runID: string;
  callID: string;
  succeeded: boolean;
  output?: BurnBarJSONValue | null;
  error?: BurnBarToolExecutionError | null;
  completedAt: number;
}

export interface BurnBarRunProjection {
  id: string;
  title: string;
  phase: BurnBarRunPhase;
  note: string;
  updatedAt: string;
  providerId?: string;
  providerName?: string;
  modelId?: string;
  source: 'projected' | 'daemon';
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
export type BurnBarMissionPacketStatus = 'pending' | 'in_progress' | 'completed' | 'failed' | 'cancelled';
export type BurnBarMissionResultStatus = 'pending' | 'success' | 'failed' | 'partial';
export type BurnBarAutoTakeoverStatus = 'requested' | 'in_progress' | 'completed' | 'declined' | 'failed';

export interface BurnBarMissionApprovalSnapshot {
  approved: boolean;
  approvedAt?: string;
  approvedBy?: string;
  note?: string;
}

export interface BurnBarMissionPacketSnapshot {
  id: string;
  missionID: string;
  workerName: string;
  objective: string;
  status: BurnBarMissionPacketStatus;
  runID?: string;
  dispatchedAt?: string;
  completedAt?: string;
  metadata: Record<string, unknown>;
}

export interface BurnBarMissionResultSnapshot {
  id: string;
  missionID: string;
  packetID?: string;
  runID?: string;
  status: BurnBarMissionResultStatus;
  summary: string;
  detail?: string;
  burnDelta: number;
  createdAt: string;
  evidenceRefs: string[];
  metadata: Record<string, unknown>;
}

export interface BurnBarMissionBurnRecord {
  id: string;
  label: string;
  amount: number;
  unit: string;
  recordedAt: string;
}

export interface BurnBarAutoTakeoverRecord {
  id: string;
  projectSlug: string;
  missionID?: string;
  sourceRunID?: string;
  takeoverRunID?: string;
  status: BurnBarAutoTakeoverStatus;
  reason: string;
  createdAt: string;
  updatedAt: string;
  metadata: Record<string, unknown>;
}

export interface BurnBarMissionSnapshot {
  id: string;
  projectSlug: string;
  title: string;
  summary: string;
  status: BurnBarMissionStatus;
  recommendation: BurnBarMissionRecommendation;
  createdAt: string;
  updatedAt: string;
  approval?: BurnBarMissionApprovalSnapshot;
  packets: BurnBarMissionPacketSnapshot[];
  results: BurnBarMissionResultSnapshot[];
  burnRecords: BurnBarMissionBurnRecord[];
  takeoverHistory: BurnBarAutoTakeoverRecord[];
  metadata: Record<string, unknown>;
}

export interface OpenBurnBarState {
  connectionStatus: BurnBarConnectionStatus;
  clientAttached: boolean;
  health?: BurnBarHealthResponse;
  catalog?: BurnBarCatalog;
  daemonRuns: BurnBarRunStateSnapshot[];
  daemonMissions?: BurnBarMissionSnapshot[];
  pendingToolCalls: BurnBarToolCallSnapshot[];
  arbitration?: BurnBarClientArbitrationSnapshot;
  selectedRunDetail?: BurnBarRunDetailResponse;
  recentUsage: BurnBarUsageEvent[];
  runError?: string;
  workspace?: BurnBarWorkspaceCapabilities;
  runs: BurnBarRunProjection[];
  selectedRunId?: string;
  lastError?: string;
  workspaceError?: string;
  lastUpdatedAt?: string;
}

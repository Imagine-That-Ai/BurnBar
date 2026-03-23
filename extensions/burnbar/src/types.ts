export const BURNBAR_PROTOCOL_VERSION = 1;
export const BURNBAR_RECONNECT_INTERVAL_MS = 15_000;

import type { BurnBarWorkspaceCapabilities } from "./workspace/types";

export type BurnBarRPCMethod =
  | "daemon.health"
  | "daemon.catalog"
  | "daemon.config.get"
  | "daemon.usage.recent"
  | "run.create"
  | "run.list"
  | "run.get"
  | "run.poll"
  | "run.cancel"
  | "run.retry"
  | "workspace.executeTool"
  | "workspace.toolResult"
  | "approval.respond"
  | "client.attach"
  | "client.detach";
export type BurnBarConnectionStatus =
  | "connecting"
  | "connected"
  | "disconnected"
  | "repairing";
export type BurnBarRunPhase =
  | "idle"
  | "planning"
  | "awaiting_approval"
  | "executing_tool"
  | "waiting_on_companion"
  | "model_streaming"
  | "completed"
  | "failed"
  | "cancelled";

export type BurnBarApprovalDecision = "approve" | "reject" | "cancel";
export type BurnBarToolKind = "read_file" | "search_workspace" | "apply_patch" | "run_terminal";

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

export interface BurnBarCatalogModelPricing {
  inputPerMToken: number;
  outputPerMToken: number;
  cacheReadPerMToken: number;
}

export interface BurnBarCatalogModel {
  id: string;
  displayName: string;
  visibility: "public" | "hidden" | "internal";
  aliases: string[];
  pricing: BurnBarCatalogModelPricing;
}

export interface BurnBarCatalogProvider {
  id: string;
  displayName: string;
  baseURL: string;
  visibility: "public" | "hidden" | "internal";
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
  | "trust_gated"
  | "no_workspace"
  | "remote_unsupported"
  | "apply_failed"
  | "terminal_failed"
  | "unknown";

export interface BurnBarToolExecutionError {
  code: BurnBarToolExecutionErrorCode;
  message: string;
}

export type BurnBarToolCallStatus = "pending" | "in_progress" | "completed" | "failed" | "cancelled";

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
  approvals: BurnBarApprovalRequest[];
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

export interface BurnBarApprovalRequest {
  approvalID: string;
  runID: string;
  tool: BurnBarToolKind;
  title: string;
  message: string;
  requestedAt: string;
}

export interface BurnBarApprovalResponse {
  approvalID: string;
  clientID: string;
  decision: BurnBarApprovalDecision;
  note?: string;
  respondedAt: number;
}

export interface BurnBarApprovalRespondRequest {
  response: BurnBarApprovalResponse;
}

export interface BurnBarRunDetailResponse {
  run?: BurnBarRunStateSnapshot | null;
  approvalRequest?: BurnBarApprovalRequest | null;
  pendingToolCall?: BurnBarToolCallSnapshot | null;
  arbitration?: BurnBarClientArbitrationSnapshot | null;
}

export interface BurnBarToolExecutionRequest {
  clientID: string;
  sessionID: string;
  runID?: string;
}

export type BurnBarToolExecutionDisposition = "dispatched" | "no_pending_tool_call" | "run_not_found";

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
  source: "projected" | "daemon";
}

export interface BurnBarState {
  connectionStatus: BurnBarConnectionStatus;
  clientAttached: boolean;
  health?: BurnBarHealthResponse;
  catalog?: BurnBarCatalog;
  daemonRuns: BurnBarRunStateSnapshot[];
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

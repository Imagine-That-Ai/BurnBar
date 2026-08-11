import type {
  AIInboxAction,
  AIInboxActionKind,
  AIInboxConfig,
  AIInboxEgressMode,
  AIInboxEvidence,
  AIInboxEvidenceKind,
  AIInboxFounderPack,
  AIInboxGetResponse,
  AIInboxItemDetail,
  AIInboxItemKind,
  AIInboxItemPayload,
  AIInboxItemState,
  AIInboxItemSummary,
  AIInboxListRequest,
  AIInboxListResponse,
  AIInboxMemoryCandidate,
  AIInboxMemoryApprovalResponse,
  AIInboxMemoryCandidateApproveRequest,
  AIInboxMemoryExportRequest,
  AIInboxMemoryExportResponse,
  AIInboxFeedback,
  AIInboxItemPresentationState,
  AIInboxPresentationGetResponse,
  AIInboxPresentationListRequest,
  AIInboxPresentationListResponse,
  AIInboxPresentationMarkAllReadResponse,
  AIInboxPresentationMutationAction,
  AIInboxPresentationMutationRequest,
  AIInboxPresentationMutationResponse,
  AIInboxPresentationRow,
  AIInboxPlan,
  AIInboxPlanAcceptRequest,
  AIInboxPlanAcceptResponse,
  AIInboxPlanCandidate,
  AIInboxPlanGetResponse,
  AIInboxPlanGradeRequest,
  AIInboxPlanGradeResponse,
  AIInboxPlanCreateFollowupRequest,
  AIInboxPlanCreateFollowupResponse,
  AIInboxPlanHorizon,
  AIInboxPlansListRequest,
  AIInboxPlansListResponse,
  AIInboxPlanRememberStepRequest,
  AIInboxPlanRememberStepResponse,
  AIInboxPlanStatus,
  AIInboxPlanStep,
  AIInboxPlanStepStatus,
  AIInboxPlanUpdateStepRequest,
  AIInboxPlanUpdateStepResponse,
  AIInboxReplyRequest,
  AIInboxReplyResponse,
  AIInboxRunGateResult,
  AIInboxRunNowResponse,
  AIInboxRunsResponse,
  AIInboxThread,
  AIInboxThreadGetResponse,
  AIInboxThreadMessage,
  AIInboxThreadMessageRole,
  AIInboxVerification,
  AIInboxVerificationVerdict
} from './tauriBridgeTypes.js';
import type { RawJsonValue } from './tauriBridgeRaw.js';
import {
  requireBoolean,
  requireObject,
  requireString
} from './tauriBridgeRaw.js';

const FOUNDATION_REFERENCE_UNIX_MS = Date.UTC(2001, 0, 1);
const MAX_SAFE_COUNT = Number.MAX_SAFE_INTEGER;

const ITEM_KINDS = new Set<AIInboxItemKind>([
  'ci_waste',
  'promised_not_landed',
  'uncommitted_work',
  'cost_anomaly',
  'stuck_pr',
  'index_health',
  'brief',
  'budget',
  'system'
]);
const ITEM_STATES = new Set<AIInboxItemState>(['new', 'updated', 'resolved', 'expired']);
const FEEDBACK_VALUES = new Set<AIInboxFeedback>(['useful', 'not_useful']);
const PRESENTATION_MUTATION_ACTIONS = new Set<AIInboxPresentationMutationAction>([
  'mark_read',
  'mark_unread',
  'archive',
  'unarchive',
  'snooze',
  'clear_snooze',
  'set_feedback',
  'clear_feedback'
]);
const EGRESS_MODES = new Set<AIInboxEgressMode>(['off', 'local', 'cloud']);
const EVIDENCE_KINDS = new Set<AIInboxEvidenceKind>([
  'conversation',
  'pull_request',
  'issue',
  'workflow_run',
  'commit',
  'file',
  'usage',
  'metric'
]);
const ACTION_KINDS = new Set<AIInboxActionKind>([
  'open_url',
  'resume_conversation',
  'open_session_log',
  'open_project',
  'open_settings',
  'run_command'
]);
const VERIFICATION_VERDICTS = new Set<AIInboxVerificationVerdict>([
  'confirmed',
  'refuted',
  'unclear',
  'unverified',
  'deterministic'
]);
const RUN_GATE_RESULTS = new Set<AIInboxRunGateResult>([
  'skipped_unchanged',
  'skipped_disabled',
  'local_changed',
  'remote_phase',
  'forced',
  'failed'
]);
const FOUNDER_PACKS = new Set<AIInboxFounderPack>(['engOps', 'productStrategy']);
const THREAD_ROLES = new Set<AIInboxThreadMessageRole>(['user', 'assistant']);
const PLAN_HORIZONS = new Set<AIInboxPlanHorizon>(['week', 'month', 'quarter', 'ongoing']);
const PLAN_STATUSES = new Set<AIInboxPlanStatus>([
  'proposed',
  'active',
  'paused',
  'completed',
  'killed'
]);
const PLAN_STEP_STATUSES = new Set<AIInboxPlanStepStatus>([
  'proposed',
  'accepted',
  'in_progress',
  'landed',
  'failed',
  'killed'
]);

function requireArray(value: RawJsonValue, label: string): RawJsonValue[] {
  if (!Array.isArray(value)) throw new Error(`${label} must be an array.`);
  return value;
}

function requireStringValue(value: RawJsonValue, label: string): string {
  if (typeof value !== 'string') throw new Error(`${label} must be a string.`);
  return value;
}

function optionalString(value: RawJsonValue, label: string): string | undefined {
  if (value === undefined || value === null) return undefined;
  return requireStringValue(value, label);
}

function optionalBoolean(value: RawJsonValue, label: string): boolean | undefined {
  if (value === undefined || value === null) return undefined;
  return requireBoolean(value, label);
}

function requireFiniteNumber(value: RawJsonValue, label: string): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new Error(`${label} must be a finite number.`);
  }
  return value;
}

function clampNumber(value: RawJsonValue, label: string, minimum: number, maximum: number): number {
  return Math.min(maximum, Math.max(minimum, requireFiniteNumber(value, label)));
}

function clampInteger(value: RawJsonValue, label: string, minimum: number, maximum: number): number {
  const number = requireFiniteNumber(value, label);
  if (!Number.isSafeInteger(number)) throw new Error(`${label} must be a safe integer.`);
  return Math.min(maximum, Math.max(minimum, number));
}

function optionalClampedNumber(
  value: RawJsonValue,
  label: string,
  minimum: number,
  maximum: number
): number | undefined {
  if (value === undefined || value === null) return undefined;
  return clampNumber(value, label, minimum, maximum);
}

function optionalClampedInteger(
  value: RawJsonValue,
  label: string,
  minimum: number,
  maximum: number
): number | undefined {
  if (value === undefined || value === null) return undefined;
  return clampInteger(value, label, minimum, maximum);
}

function requireEnum<T extends string>(
  value: RawJsonValue,
  values: ReadonlySet<T>,
  label: string
): T {
  if (typeof value !== 'string' || !values.has(value as T)) {
    throw new Error(`${label} is unsupported.`);
  }
  return value as T;
}

function optionalEnum<T extends string>(
  value: RawJsonValue,
  values: ReadonlySet<T>,
  label: string
): T | undefined {
  if (value === undefined || value === null) return undefined;
  return requireEnum(value, values, label);
}

function decodeStringArray(value: RawJsonValue, label: string): string[] {
  return requireArray(value, label).map((entry, index) =>
    requireStringValue(entry, `${label}[${index}]`)
  );
}

function decodeEnumArray<T extends string>(
  value: RawJsonValue,
  values: ReadonlySet<T>,
  label: string
): T[] {
  return requireArray(value, label).map((entry, index) =>
    requireEnum(entry, values, `${label}[${index}]`)
  );
}

function decodePriorityArray(value: RawJsonValue, label: string): Array<1 | 2 | 3 | 4> {
  return requireArray(value, label).map((entry, index) =>
    clampInteger(entry, `${label}[${index}]`, 1, 4) as 1 | 2 | 3 | 4
  );
}

function optionalDate(value: RawJsonValue, label: string): string | undefined {
  if (value === undefined || value === null) return undefined;
  return decodeSwiftDate(value, label);
}

function optionalField<T extends object, K extends keyof T>(
  target: T,
  key: K,
  value: T[K] | undefined
): void {
  if (value !== undefined) target[key] = value;
}

/**
 * Swift's default JSONEncoder represents Date as seconds since
 * 2001-01-01T00:00:00Z. ISO strings are also accepted for forward-compatible
 * fixtures, but every accepted value is canonicalized before reaching UI code.
 */
export function decodeSwiftDate(value: RawJsonValue, label: string): string {
  const milliseconds = typeof value === 'number'
    ? FOUNDATION_REFERENCE_UNIX_MS + requireFiniteNumber(value, label) * 1_000
    : typeof value === 'string' && value.trim().length > 0
      ? Date.parse(value)
      : Number.NaN;
  if (!Number.isFinite(milliseconds)) throw new Error(`${label} must be a valid date.`);
  const date = new Date(milliseconds);
  if (!Number.isFinite(date.getTime())) throw new Error(`${label} must be a valid date.`);
  return date.toISOString();
}

export function encodeSwiftDate(value: string, label: string): number {
  const milliseconds = Date.parse(value);
  if (!Number.isFinite(milliseconds)) throw new Error(`${label} must be a valid ISO-8601 date.`);
  return (milliseconds - FOUNDATION_REFERENCE_UNIX_MS) / 1_000;
}

function decodeEvidence(raw: RawJsonValue, label: string): AIInboxEvidence {
  const value = requireObject(raw, label);
  const evidence: AIInboxEvidence = {
    id: requireString(value.id, `${label}.id`),
    kind: requireEnum(value.kind, EVIDENCE_KINDS, `${label}.kind`),
    label: requireString(value.label, `${label}.label`)
  };
  optionalField(evidence, 'detail', optionalString(value.detail, `${label}.detail`));
  optionalField(evidence, 'url', optionalString(value.url, `${label}.url`));
  optionalField(evidence, 'occurredAt', optionalDate(value.occurredAt, `${label}.occurredAt`));
  return evidence;
}

function decodeMemoryCandidate(raw: RawJsonValue, label: string): AIInboxMemoryCandidate {
  const value = requireObject(raw, label);
  return {
    id: requireString(value.id, `${label}.id`),
    text: requireStringValue(value.text, `${label}.text`),
    kind: requireStringValue(value.kind, `${label}.kind`),
    confidence: clampNumber(value.confidence, `${label}.confidence`, 0, 1),
    citationConversationIDs: decodeStringArray(
      value.citationConversationIDs,
      `${label}.citationConversationIDs`
    )
  };
}

function decodeAction(raw: RawJsonValue, label: string): AIInboxAction {
  const value = requireObject(raw, label);
  return {
    id: requireString(value.id, `${label}.id`),
    kind: requireEnum(value.kind, ACTION_KINDS, `${label}.kind`),
    title: requireString(value.title, `${label}.title`),
    value: requireStringValue(value.value, `${label}.value`),
    isPrimary: requireBoolean(value.isPrimary, `${label}.isPrimary`)
  };
}

function decodeVerification(raw: RawJsonValue, label: string): AIInboxVerification {
  const value = requireObject(raw, label);
  const verification: AIInboxVerification = {
    verdict: requireEnum(value.verdict, VERIFICATION_VERDICTS, `${label}.verdict`),
    checkedAt: decodeSwiftDate(value.checkedAt, `${label}.checkedAt`)
  };
  optionalField(verification, 'reason', optionalString(value.reason, `${label}.reason`));
  optionalField(
    verification,
    'verifierModel',
    optionalString(value.verifierModel, `${label}.verifierModel`)
  );
  return verification;
}

function decodeStringRecord(value: RawJsonValue, label: string): Record<string, string> {
  const record = requireObject(value, label);
  return Object.fromEntries(
    Object.entries(record).map(([key, entry]) => [
      key,
      requireStringValue(entry, `${label}.${key}`)
    ])
  );
}

function decodeItemPayload(raw: RawJsonValue, label: string): AIInboxItemPayload {
  const value = requireObject(raw, label);
  const version = clampInteger(value.version, `${label}.version`, 1, MAX_SAFE_COUNT);
  if (version !== 1) throw new Error(`${label}.version is unsupported.`);
  const payload: AIInboxItemPayload = {
    version,
    evidence: requireArray(value.evidence, `${label}.evidence`).map((entry, index) =>
      decodeEvidence(entry, `${label}.evidence[${index}]`)
    ),
    memoryCandidates: requireArray(
      value.memoryCandidates,
      `${label}.memoryCandidates`
    ).map((entry, index) =>
      decodeMemoryCandidate(entry, `${label}.memoryCandidates[${index}]`)
    ),
    actions: requireArray(value.actions, `${label}.actions`).map((entry, index) =>
      decodeAction(entry, `${label}.actions[${index}]`)
    ),
    metrics: decodeStringRecord(value.metrics, `${label}.metrics`)
  };
  if (value.verification !== undefined && value.verification !== null) {
    payload.verification = decodeVerification(value.verification, `${label}.verification`);
  }
  return payload;
}

function decodeItemSummary(raw: RawJsonValue, label: string): AIInboxItemSummary {
  const value = requireObject(raw, label);
  const priority = clampInteger(value.priority, `${label}.priority`, 1, 4);
  const summary: AIInboxItemSummary = {
    id: requireString(value.id, `${label}.id`),
    fingerprint: requireString(value.fingerprint, `${label}.fingerprint`),
    kind: requireEnum(value.kind, ITEM_KINDS, `${label}.kind`),
    priority: priority as AIInboxItemSummary['priority'],
    state: requireEnum(value.state, ITEM_STATES, `${label}.state`),
    title: requireString(value.title, `${label}.title`),
    occurrenceCount: clampInteger(
      value.occurrenceCount,
      `${label}.occurrenceCount`,
      0,
      MAX_SAFE_COUNT
    ),
    firstSeenAt: decodeSwiftDate(value.firstSeenAt, `${label}.firstSeenAt`),
    lastSeenAt: decodeSwiftDate(value.lastSeenAt, `${label}.lastSeenAt`),
    modelProvenance: requireString(value.modelProvenance, `${label}.modelProvenance`),
    hasMemoryCandidates: requireBoolean(
      value.hasMemoryCandidates,
      `${label}.hasMemoryCandidates`
    )
  };
  optionalField(summary, 'projectID', optionalString(value.projectID, `${label}.projectID`));
  optionalField(summary, 'projectName', optionalString(value.projectName, `${label}.projectName`));
  optionalField(summary, 'resolvedAt', optionalDate(value.resolvedAt, `${label}.resolvedAt`));
  optionalField(
    summary,
    'resolutionNote',
    optionalString(value.resolutionNote, `${label}.resolutionNote`)
  );
  return summary;
}

function decodeItemDetail(raw: RawJsonValue, label: string): AIInboxItemDetail {
  const value = requireObject(raw, label);
  return {
    summary: decodeItemSummary(value.summary, `${label}.summary`),
    summaryMarkdown: requireStringValue(value.summaryMarkdown, `${label}.summaryMarkdown`),
    payload: decodeItemPayload(value.payload, `${label}.payload`),
    tickID: requireString(value.tickID, `${label}.tickID`)
  };
}

export function decodeAIInboxListResponse(raw: RawJsonValue): AIInboxListResponse {
  const value = requireObject(raw, 'inbox.list response');
  const response: AIInboxListResponse = {
    items: requireArray(value.items, 'inbox.list.items').map((entry, index) =>
      decodeItemSummary(entry, `inbox.list.items[${index}]`)
    ),
    openCount: clampInteger(value.openCount, 'inbox.list.openCount', 0, MAX_SAFE_COUNT)
  };
  optionalField(response, 'nextBefore', optionalDate(value.nextBefore, 'inbox.list.nextBefore'));
  return response;
}

export function decodeAIInboxGetResponse(raw: RawJsonValue): AIInboxGetResponse {
  const value = requireObject(raw, 'inbox.get response');
  if (value.item === undefined || value.item === null) return {};
  return { item: decodeItemDetail(value.item, 'inbox.get.item') };
}

function decodePresentationState(
  raw: RawJsonValue,
  label: string
): AIInboxItemPresentationState {
  const value = requireObject(raw, label);
  const state: AIInboxItemPresentationState = {};
  optionalField(state, 'readAt', optionalDate(value.readAt, `${label}.readAt`));
  optionalField(state, 'archivedAt', optionalDate(value.archivedAt, `${label}.archivedAt`));
  optionalField(
    state,
    'snoozedUntil',
    optionalDate(value.snoozedUntil, `${label}.snoozedUntil`)
  );
  optionalField(
    state,
    'feedback',
    optionalEnum(value.feedback, FEEDBACK_VALUES, `${label}.feedback`)
  );
  optionalField(state, 'updatedAt', optionalDate(value.updatedAt, `${label}.updatedAt`));
  return state;
}

function decodePresentationRow(raw: RawJsonValue, label: string): AIInboxPresentationRow {
  const value = requireObject(raw, label);
  return {
    item: decodeItemDetail(value.item, `${label}.item`),
    presentation: decodePresentationState(value.presentation, `${label}.presentation`)
  };
}

export function decodeAIInboxPresentationListResponse(
  raw: RawJsonValue
): AIInboxPresentationListResponse {
  const value = requireObject(raw, 'inbox.presentation.list response');
  const response: AIInboxPresentationListResponse = {
    rows: requireArray(value.rows, 'inbox.presentation.list.rows').map((entry, index) =>
      decodePresentationRow(entry, `inbox.presentation.list.rows[${index}]`)
    ),
    openCount: clampInteger(
      value.openCount,
      'inbox.presentation.list.openCount',
      0,
      MAX_SAFE_COUNT
    ),
    activeUnreadCount: clampInteger(
      value.activeUnreadCount,
      'inbox.presentation.list.activeUnreadCount',
      0,
      MAX_SAFE_COUNT
    )
  };
  optionalField(
    response,
    'nextBefore',
    optionalDate(value.nextBefore, 'inbox.presentation.list.nextBefore')
  );
  return response;
}

export function decodeAIInboxPresentationGetResponse(
  raw: RawJsonValue
): AIInboxPresentationGetResponse {
  const value = requireObject(raw, 'inbox.presentation.get response');
  if (value.row === undefined || value.row === null) return {};
  return { row: decodePresentationRow(value.row, 'inbox.presentation.get.row') };
}

export function decodeAIInboxPresentationMutationResponse(
  raw: RawJsonValue
): AIInboxPresentationMutationResponse {
  const value = requireObject(raw, 'inbox.presentation.mutate response');
  return {
    row: decodePresentationRow(value.row, 'inbox.presentation.mutate.row')
  };
}

export function decodeAIInboxPresentationMarkAllReadResponse(
  raw: RawJsonValue
): AIInboxPresentationMarkAllReadResponse {
  const value = requireObject(raw, 'inbox.presentation.mark_all_read response');
  return {
    updatedCount: clampInteger(
      value.updatedCount,
      'inbox.presentation.mark_all_read.updatedCount',
      0,
      MAX_SAFE_COUNT
    ),
    readAt: decodeSwiftDate(value.readAt, 'inbox.presentation.mark_all_read.readAt'),
    activeUnreadCount: clampInteger(
      value.activeUnreadCount,
      'inbox.presentation.mark_all_read.activeUnreadCount',
      0,
      MAX_SAFE_COUNT
    )
  };
}

function decodeRunTelemetry(raw: RawJsonValue, label: string) {
  const value = requireObject(raw, label);
  const run = {
    tickID: requireString(value.tickID, `${label}.tickID`),
    startedAt: decodeSwiftDate(value.startedAt, `${label}.startedAt`),
    gateResult: requireEnum(value.gateResult, RUN_GATE_RESULTS, `${label}.gateResult`),
    egressMode: requireEnum(value.egressMode, EGRESS_MODES, `${label}.egressMode`),
    llmCalls: clampInteger(value.llmCalls, `${label}.llmCalls`, 0, MAX_SAFE_COUNT),
    inputTokens: clampInteger(value.inputTokens, `${label}.inputTokens`, 0, MAX_SAFE_COUNT),
    outputTokens: clampInteger(value.outputTokens, `${label}.outputTokens`, 0, MAX_SAFE_COUNT),
    costUSD: clampNumber(value.costUSD, `${label}.costUSD`, 0, Number.MAX_VALUE),
    itemsNew: clampInteger(value.itemsNew, `${label}.itemsNew`, 0, MAX_SAFE_COUNT),
    itemsUpdated: clampInteger(value.itemsUpdated, `${label}.itemsUpdated`, 0, MAX_SAFE_COUNT),
    itemsResolved: clampInteger(value.itemsResolved, `${label}.itemsResolved`, 0, MAX_SAFE_COUNT)
  };
  const result = run as typeof run & { finishedAt?: string; error?: string };
  optionalField(result, 'finishedAt', optionalDate(value.finishedAt, `${label}.finishedAt`));
  optionalField(result, 'error', optionalString(value.error, `${label}.error`));
  return result;
}

export function decodeAIInboxRunsResponse(raw: RawJsonValue): AIInboxRunsResponse {
  const value = requireObject(raw, 'inbox.runs response');
  return {
    runs: requireArray(value.runs, 'inbox.runs.runs').map((entry, index) =>
      decodeRunTelemetry(entry, `inbox.runs.runs[${index}]`)
    ),
    todaySpendUSD: clampNumber(value.todaySpendUSD, 'inbox.runs.todaySpendUSD', 0, Number.MAX_VALUE),
    dailyBudgetUSD: clampNumber(value.dailyBudgetUSD, 'inbox.runs.dailyBudgetUSD', 0, Number.MAX_VALUE)
  };
}

export function decodeAIInboxConfig(raw: RawJsonValue): AIInboxConfig {
  const value = requireObject(raw, 'inbox.config response');
  return {
    enabled: requireBoolean(value.enabled, 'inbox.config.enabled'),
    egressMode: requireEnum(value.egressMode, EGRESS_MODES, 'inbox.config.egressMode'),
    tickSeconds: clampInteger(value.tickSeconds, 'inbox.config.tickSeconds', 60, 3_600),
    remotePhaseEveryNTicks: clampInteger(
      value.remotePhaseEveryNTicks,
      'inbox.config.remotePhaseEveryNTicks',
      1,
      60
    ),
    dailyBudgetUSD: clampNumber(value.dailyBudgetUSD, 'inbox.config.dailyBudgetUSD', 0, Number.MAX_VALUE),
    maxVerifierCallsPerTick: clampInteger(
      value.maxVerifierCallsPerTick,
      'inbox.config.maxVerifierCallsPerTick',
      0,
      25
    ),
    perTickPromptTokenCap: clampInteger(
      value.perTickPromptTokenCap,
      'inbox.config.perTickPromptTokenCap',
      2_000,
      500_000
    ),
    analystProviderID: requireStringValue(value.analystProviderID, 'inbox.config.analystProviderID'),
    analystModel: requireStringValue(value.analystModel, 'inbox.config.analystModel'),
    verifierProviderID: requireStringValue(value.verifierProviderID, 'inbox.config.verifierProviderID'),
    verifierModel: requireStringValue(value.verifierModel, 'inbox.config.verifierModel'),
    githubEnabled: requireBoolean(value.githubEnabled, 'inbox.config.githubEnabled'),
    notifyOnP1: requireBoolean(value.notifyOnP1, 'inbox.config.notifyOnP1'),
    lookbackMinutes: clampInteger(value.lookbackMinutes, 'inbox.config.lookbackMinutes', 15, 1_440),
    founderLensEnabled: requireBoolean(value.founderLensEnabled, 'inbox.config.founderLensEnabled'),
    perReplyBudgetUSD: clampNumber(value.perReplyBudgetUSD, 'inbox.config.perReplyBudgetUSD', 0, 5),
    maxThreadTurns: clampInteger(value.maxThreadTurns, 'inbox.config.maxThreadTurns', 2, 200),
    budgetCountsSubscriptionSpend: requireBoolean(
      value.budgetCountsSubscriptionSpend,
      'inbox.config.budgetCountsSubscriptionSpend'
    )
  };
}

export function decodeAIInboxRunNowResponse(raw: RawJsonValue): AIInboxRunNowResponse {
  const value = requireObject(raw, 'inbox.run_now response');
  const response: AIInboxRunNowResponse = {
    accepted: requireBoolean(value.accepted, 'inbox.run_now.accepted')
  };
  optionalField(response, 'tickID', optionalString(value.tickID, 'inbox.run_now.tickID'));
  optionalField(response, 'reason', optionalString(value.reason, 'inbox.run_now.reason'));
  return response;
}

function decodePlanCandidate(raw: RawJsonValue, label: string): AIInboxPlanCandidate {
  const value = requireObject(raw, label);
  const candidate: AIInboxPlanCandidate = {
    title: requireString(value.title, `${label}.title`),
    bodyMarkdown: requireStringValue(value.bodyMarkdown, `${label}.bodyMarkdown`),
    horizon: requireEnum(value.horizon, PLAN_HORIZONS, `${label}.horizon`),
    evidenceIDs: decodeStringArray(value.evidenceIDs, `${label}.evidenceIDs`)
  };
  optionalField(candidate, 'planID', optionalString(value.planID, `${label}.planID`));
  return candidate;
}

function decodeThreadMessage(raw: RawJsonValue, label: string): AIInboxThreadMessage {
  const value = requireObject(raw, label);
  const message: AIInboxThreadMessage = {
    id: requireString(value.id, `${label}.id`),
    fingerprint: requireString(value.fingerprint, `${label}.fingerprint`),
    role: requireEnum(value.role, THREAD_ROLES, `${label}.role`),
    bodyMarkdown: requireStringValue(value.bodyMarkdown, `${label}.bodyMarkdown`),
    planCandidates: requireArray(value.planCandidates, `${label}.planCandidates`).map(
      (entry, index) => decodePlanCandidate(entry, `${label}.planCandidates[${index}]`)
    ),
    costUSD: clampNumber(value.costUSD, `${label}.costUSD`, 0, Number.MAX_VALUE),
    createdAt: decodeSwiftDate(value.createdAt, `${label}.createdAt`)
  };
  optionalField(
    message,
    'modelProvenance',
    optionalString(value.modelProvenance, `${label}.modelProvenance`)
  );
  return message;
}

function decodeThread(raw: RawJsonValue, label: string): AIInboxThread {
  const value = requireObject(raw, label);
  const thread: AIInboxThread = {
    fingerprint: requireString(value.fingerprint, `${label}.fingerprint`),
    createdAt: decodeSwiftDate(value.createdAt, `${label}.createdAt`),
    updatedAt: decodeSwiftDate(value.updatedAt, `${label}.updatedAt`),
    turnCount: clampInteger(value.turnCount, `${label}.turnCount`, 0, MAX_SAFE_COUNT),
    totalCostUSD: clampNumber(value.totalCostUSD, `${label}.totalCostUSD`, 0, Number.MAX_VALUE),
    messages: requireArray(value.messages, `${label}.messages`).map((entry, index) =>
      decodeThreadMessage(entry, `${label}.messages[${index}]`)
    )
  };
  optionalField(thread, 'itemID', optionalString(value.itemID, `${label}.itemID`));
  return thread;
}

export function decodeAIInboxThreadGetResponse(raw: RawJsonValue): AIInboxThreadGetResponse {
  const value = requireObject(raw, 'inbox.thread.get response');
  if (value.thread === undefined || value.thread === null) return {};
  return { thread: decodeThread(value.thread, 'inbox.thread.get.thread') };
}

export function decodeAIInboxReplyResponse(raw: RawJsonValue): AIInboxReplyResponse {
  const value = requireObject(raw, 'inbox.reply response');
  const response: AIInboxReplyResponse = {};
  if (value.message !== undefined && value.message !== null) {
    response.message = decodeThreadMessage(value.message, 'inbox.reply.message');
  }
  optionalField(
    response,
    'refusalReason',
    optionalString(value.refusalReason, 'inbox.reply.refusalReason')
  );
  if (!response.message && !response.refusalReason) {
    throw new Error('inbox.reply response must contain a message or refusalReason.');
  }
  return response;
}

function decodePlanStep(raw: RawJsonValue, label: string): AIInboxPlanStep {
  const value = requireObject(raw, label);
  const step: AIInboxPlanStep = {
    id: requireString(value.id, `${label}.id`),
    planID: requireString(value.planID, `${label}.planID`),
    ordinal: clampInteger(value.ordinal, `${label}.ordinal`, 0, MAX_SAFE_COUNT),
    title: requireString(value.title, `${label}.title`),
    bodyMarkdown: requireStringValue(value.bodyMarkdown, `${label}.bodyMarkdown`),
    status: requireEnum(value.status, PLAN_STEP_STATUSES, `${label}.status`),
    evidenceIDs: decodeStringArray(value.evidenceIDs, `${label}.evidenceIDs`),
    createdAt: decodeSwiftDate(value.createdAt, `${label}.createdAt`),
    updatedAt: decodeSwiftDate(value.updatedAt, `${label}.updatedAt`)
  };
  optionalField(step, 'parentStepID', optionalString(value.parentStepID, `${label}.parentStepID`));
  optionalField(
    step,
    'nextMoveMarkdown',
    optionalString(value.nextMoveMarkdown, `${label}.nextMoveMarkdown`)
  );
  optionalField(step, 'missionID', optionalString(value.missionID, `${label}.missionID`));
  optionalField(step, 'followupID', optionalString(value.followupID, `${label}.followupID`));
  optionalField(step, 'memoryID', optionalString(value.memoryID, `${label}.memoryID`));
  optionalField(
    step,
    'inboxFingerprint',
    optionalString(value.inboxFingerprint, `${label}.inboxFingerprint`)
  );
  optionalField(step, 'grade', optionalClampedInteger(value.grade, `${label}.grade`, 0, 100));
  optionalField(
    step,
    'gradeNoteMarkdown',
    optionalString(value.gradeNoteMarkdown, `${label}.gradeNoteMarkdown`)
  );
  optionalField(step, 'gradedAt', optionalDate(value.gradedAt, `${label}.gradedAt`));
  optionalField(step, 'completedAt', optionalDate(value.completedAt, `${label}.completedAt`));
  return step;
}

function decodePlan(raw: RawJsonValue, label: string): AIInboxPlan {
  const value = requireObject(raw, label);
  const plan: AIInboxPlan = {
    id: requireString(value.id, `${label}.id`),
    title: requireString(value.title, `${label}.title`),
    horizon: requireEnum(value.horizon, PLAN_HORIZONS, `${label}.horizon`),
    pack: requireEnum(value.pack, FOUNDER_PACKS, `${label}.pack`),
    status: requireEnum(value.status, PLAN_STATUSES, `${label}.status`),
    summaryMarkdown: requireStringValue(value.summaryMarkdown, `${label}.summaryMarkdown`),
    createdAt: decodeSwiftDate(value.createdAt, `${label}.createdAt`),
    updatedAt: decodeSwiftDate(value.updatedAt, `${label}.updatedAt`),
    steps: requireArray(value.steps, `${label}.steps`).map((entry, index) =>
      decodePlanStep(entry, `${label}.steps[${index}]`)
    )
  };
  optionalField(
    plan,
    'originFingerprint',
    optionalString(value.originFingerprint, `${label}.originFingerprint`)
  );
  optionalField(plan, 'memoryID', optionalString(value.memoryID, `${label}.memoryID`));
  optionalField(
    plan,
    'pensieveVectorID',
    optionalString(value.pensieveVectorID, `${label}.pensieveVectorID`)
  );
  optionalField(
    plan,
    'gradeAverage',
    optionalClampedNumber(value.gradeAverage, `${label}.gradeAverage`, 0, 100)
  );
  return plan;
}

export function decodeAIInboxPlansListResponse(raw: RawJsonValue): AIInboxPlansListResponse {
  const value = requireObject(raw, 'inbox.plans.list response');
  return {
    plans: requireArray(value.plans, 'inbox.plans.list.plans').map((entry, index) =>
      decodePlan(entry, `inbox.plans.list.plans[${index}]`)
    )
  };
}

export function decodeAIInboxPlanGetResponse(raw: RawJsonValue): AIInboxPlanGetResponse {
  const value = requireObject(raw, 'inbox.plans.get response');
  if (value.plan === undefined || value.plan === null) return {};
  return { plan: decodePlan(value.plan, 'inbox.plans.get.plan') };
}

export function decodeAIInboxPlanAcceptResponse(raw: RawJsonValue): AIInboxPlanAcceptResponse {
  const value = requireObject(raw, 'inbox.plans.accept response');
  return {
    plan: decodePlan(value.plan, 'inbox.plans.accept.plan'),
    step: decodePlanStep(value.step, 'inbox.plans.accept.step')
  };
}

export function decodeAIInboxPlanUpdateStepResponse(
  raw: RawJsonValue
): AIInboxPlanUpdateStepResponse {
  const value = requireObject(raw, 'inbox.plans.update_step response');
  return { step: decodePlanStep(value.step, 'inbox.plans.update_step.step') };
}

export function decodeAIInboxPlanGradeResponse(raw: RawJsonValue): AIInboxPlanGradeResponse {
  const value = requireObject(raw, 'inbox.plans.grade response');
  const response: AIInboxPlanGradeResponse = {
    step: decodePlanStep(value.step, 'inbox.plans.grade.step')
  };
  optionalField(
    response,
    'planGradeAverage',
    optionalClampedNumber(
      value.planGradeAverage,
      'inbox.plans.grade.planGradeAverage',
      0,
      100
    )
  );
  return response;
}

function decodeMemoryApproval(raw: RawJsonValue, label: string): AIInboxMemoryApprovalResponse {
  const value = requireObject(raw, label);
  const response: AIInboxMemoryApprovalResponse = {
    memoryID: requireString(value.memoryID, `${label}.memoryID`),
    provenance: requireString(value.provenance, `${label}.provenance`),
    approvalAuditHash: requireString(value.approvalAuditHash, `${label}.approvalAuditHash`)
  };
  optionalField(
    response,
    'quarantineAuditHash',
    optionalString(value.quarantineAuditHash, `${label}.quarantineAuditHash`)
  );
  return response;
}

export function decodeAIInboxMemoryCandidateApproveResponse(
  raw: RawJsonValue
): AIInboxMemoryApprovalResponse {
  return decodeMemoryApproval(raw, 'inbox.memory_candidate.approve response');
}

export function decodeAIInboxPlanRememberStepResponse(
  raw: RawJsonValue
): AIInboxPlanRememberStepResponse {
  const value = requireObject(raw, 'inbox.plans.remember_step response');
  return {
    plan: decodePlan(value.plan, 'inbox.plans.remember_step.plan'),
    step: decodePlanStep(value.step, 'inbox.plans.remember_step.step'),
    memory: decodeMemoryApproval(value.memory, 'inbox.plans.remember_step.memory')
  };
}

export function decodeAIInboxPlanCreateFollowupResponse(
  raw: RawJsonValue
): AIInboxPlanCreateFollowupResponse {
  const value = requireObject(raw, 'inbox.plans.create_followup response');
  return {
    plan: decodePlan(value.plan, 'inbox.plans.create_followup.plan'),
    step: decodePlanStep(value.step, 'inbox.plans.create_followup.step'),
    followupID: requireString(value.followupID, 'inbox.plans.create_followup.followupID'),
    projectSlug: requireString(value.projectSlug, 'inbox.plans.create_followup.projectSlug'),
    title: requireString(value.title, 'inbox.plans.create_followup.title'),
    dueAt: decodeSwiftDate(value.dueAt, 'inbox.plans.create_followup.dueAt')
  };
}

export function decodeAIInboxMemoryExportResponse(raw: RawJsonValue): AIInboxMemoryExportResponse {
  const value = requireObject(raw, 'inbox.memory.export response');
  return {
    stored: clampInteger(value.stored, 'inbox.memory.export.stored', 0, MAX_SAFE_COUNT)
  };
}

export function encodeAIInboxListRequest(request: AIInboxListRequest = {}): Record<string, unknown> {
  const encoded: Record<string, unknown> = {
    limit: clampInteger(request.limit ?? 60, 'inbox.list.limit', 1, 300)
  };
  if (request.states !== undefined) {
    encoded.states = decodeEnumArray(request.states, ITEM_STATES, 'inbox.list.states');
  }
  if (request.kinds !== undefined) {
    encoded.kinds = decodeEnumArray(request.kinds, ITEM_KINDS, 'inbox.list.kinds');
  }
  if (request.projectID !== undefined) {
    encoded.projectID = requireString(request.projectID, 'inbox.list.projectID');
  }
  if (request.before !== undefined) {
    encoded.before = encodeSwiftDate(request.before, 'inbox.list.before');
  }
  return encoded;
}

export function encodeAIInboxPresentationListRequest(
  request: AIInboxPresentationListRequest = {}
): Record<string, unknown> {
  const encoded: Record<string, unknown> = {
    limit: clampInteger(request.limit ?? 200, 'inbox.presentation.list.limit', 1, 300)
  };
  if (request.states !== undefined) {
    encoded.states = request.states === null
      ? null
      : decodeEnumArray(request.states, ITEM_STATES, 'inbox.presentation.list.states');
  }
  if (request.kinds !== undefined) {
    encoded.kinds = decodeEnumArray(
      request.kinds,
      ITEM_KINDS,
      'inbox.presentation.list.kinds'
    );
  }
  if (request.priorities !== undefined) {
    encoded.priorities = decodePriorityArray(
      request.priorities,
      'inbox.presentation.list.priorities'
    );
  }
  if (request.projectID !== undefined) {
    encoded.projectID = requireString(
      request.projectID,
      'inbox.presentation.list.projectID'
    );
  }
  for (const [key, raw] of [
    ['isUnread', request.isUnread],
    ['isArchived', request.isArchived],
    ['isSnoozed', request.isSnoozed]
  ] as const) {
    const value = optionalBoolean(raw, `inbox.presentation.list.${key}`);
    if (value !== undefined) encoded[key] = value;
  }
  if (request.feedback !== undefined) {
    encoded.feedback = requireEnum(
      request.feedback,
      FEEDBACK_VALUES,
      'inbox.presentation.list.feedback'
    );
  }
  if (request.before !== undefined) {
    encoded.before = encodeSwiftDate(request.before, 'inbox.presentation.list.before');
  }
  return encoded;
}

export function encodeAIInboxPresentationGetRequest(id: string): { id: string } {
  return { id: requireString(id, 'inbox.presentation.get.id') };
}

export function encodeAIInboxPresentationMutationRequest(
  request: AIInboxPresentationMutationRequest
): Record<string, unknown> {
  const action = requireEnum(
    request.action,
    PRESENTATION_MUTATION_ACTIONS,
    'inbox.presentation.mutate.action'
  );
  const encoded: Record<string, unknown> = {
    itemID: requireString(request.itemID, 'inbox.presentation.mutate.itemID'),
    action
  };

  if (action === 'snooze') {
    if (request.snoozedUntil === undefined || request.feedback !== undefined) {
      throw new Error(
        'inbox.presentation.mutate snooze requires snoozedUntil and does not accept feedback.'
      );
    }
    encoded.snoozedUntil = encodeSwiftDate(
      request.snoozedUntil,
      'inbox.presentation.mutate.snoozedUntil'
    );
    return encoded;
  }

  if (action === 'set_feedback') {
    if (request.feedback === undefined || request.snoozedUntil !== undefined) {
      throw new Error(
        'inbox.presentation.mutate set_feedback requires feedback and does not accept snoozedUntil.'
      );
    }
    encoded.feedback = requireEnum(
      request.feedback,
      FEEDBACK_VALUES,
      'inbox.presentation.mutate.feedback'
    );
    return encoded;
  }

  if (request.snoozedUntil !== undefined || request.feedback !== undefined) {
    throw new Error(
      `inbox.presentation.mutate ${action} does not accept snoozedUntil or feedback.`
    );
  }
  return encoded;
}

export function encodeAIInboxPresentationMarkAllReadRequest(): Record<string, never> {
  return {};
}

export function encodeAIInboxRunsRequest(limit = 20): Record<string, unknown> {
  return { limit: clampInteger(limit, 'inbox.runs.limit', 1, 200) };
}

export function encodeAIInboxConfig(config: AIInboxConfig): AIInboxConfig {
  return decodeAIInboxConfig(config);
}

export function encodeAIInboxReplyRequest(request: AIInboxReplyRequest): AIInboxReplyRequest {
  return {
    fingerprint: requireString(request.fingerprint, 'inbox.reply.fingerprint'),
    bodyMarkdown: requireString(request.bodyMarkdown, 'inbox.reply.bodyMarkdown')
  };
}

function encodePlanCandidate(candidate: AIInboxPlanCandidate, label: string): AIInboxPlanCandidate {
  const encoded: AIInboxPlanCandidate = {
    title: requireString(candidate.title, `${label}.title`),
    bodyMarkdown: requireStringValue(candidate.bodyMarkdown, `${label}.bodyMarkdown`),
    horizon: requireEnum(candidate.horizon, PLAN_HORIZONS, `${label}.horizon`),
    evidenceIDs: decodeStringArray(candidate.evidenceIDs, `${label}.evidenceIDs`)
  };
  optionalField(encoded, 'planID', optionalString(candidate.planID, `${label}.planID`));
  return encoded;
}

export function encodeAIInboxPlansListRequest(
  request: AIInboxPlansListRequest = {}
): Record<string, unknown> {
  return {
    statuses: request.statuses === undefined
      ? []
      : decodeEnumArray(request.statuses, PLAN_STATUSES, 'inbox.plans.list.statuses'),
    limit: clampInteger(request.limit ?? 50, 'inbox.plans.list.limit', 1, 200)
  };
}

export function encodeAIInboxPlanAcceptRequest(
  request: AIInboxPlanAcceptRequest
): AIInboxPlanAcceptRequest {
  return {
    candidate: encodePlanCandidate(request.candidate, 'inbox.plans.accept.candidate'),
    pack: requireEnum(request.pack, FOUNDER_PACKS, 'inbox.plans.accept.pack')
  };
}

export function encodeAIInboxPlanUpdateStepRequest(
  request: AIInboxPlanUpdateStepRequest
): AIInboxPlanUpdateStepRequest {
  const encoded: AIInboxPlanUpdateStepRequest = {
    stepID: requireString(request.stepID, 'inbox.plans.update_step.stepID')
  };
  optionalField(
    encoded,
    'status',
    optionalEnum(request.status, PLAN_STEP_STATUSES, 'inbox.plans.update_step.status')
  );
  optionalField(
    encoded,
    'missionID',
    optionalString(request.missionID, 'inbox.plans.update_step.missionID')
  );
  optionalField(
    encoded,
    'followupID',
    optionalString(request.followupID, 'inbox.plans.update_step.followupID')
  );
  return encoded;
}

export function encodeAIInboxPlanGradeRequest(
  request: AIInboxPlanGradeRequest
): AIInboxPlanGradeRequest {
  const encoded: AIInboxPlanGradeRequest = {
    stepID: requireString(request.stepID, 'inbox.plans.grade.stepID'),
    grade: clampInteger(request.grade, 'inbox.plans.grade.grade', 0, 100)
  };
  optionalField(
    encoded,
    'noteMarkdown',
    optionalString(request.noteMarkdown, 'inbox.plans.grade.noteMarkdown')
  );
  return encoded;
}

export function encodeAIInboxMemoryCandidateApproveRequest(
  request: AIInboxMemoryCandidateApproveRequest
): AIInboxMemoryCandidateApproveRequest {
  const encoded: AIInboxMemoryCandidateApproveRequest = {
    itemID: requireString(request.itemID, 'inbox.memory_candidate.approve.itemID'),
    fingerprint: requireString(
      request.fingerprint,
      'inbox.memory_candidate.approve.fingerprint'
    ),
    candidateID: requireString(
      request.candidateID,
      'inbox.memory_candidate.approve.candidateID'
    )
  };
  optionalField(
    encoded,
    'projectPath',
    optionalString(request.projectPath, 'inbox.memory_candidate.approve.projectPath')
  );
  return encoded;
}

export function encodeAIInboxPlanRememberStepRequest(
  request: AIInboxPlanRememberStepRequest
): AIInboxPlanRememberStepRequest {
  const encoded: AIInboxPlanRememberStepRequest = {
    stepID: requireString(request.stepID, 'inbox.plans.remember_step.stepID')
  };
  optionalField(
    encoded,
    'projectPath',
    optionalString(request.projectPath, 'inbox.plans.remember_step.projectPath')
  );
  return encoded;
}

export function encodeAIInboxPlanCreateFollowupRequest(
  request: AIInboxPlanCreateFollowupRequest
): Record<string, unknown> {
  const encoded: Record<string, unknown> = {
    stepID: requireString(request.stepID, 'inbox.plans.create_followup.stepID'),
    projectSlug: requireString(
      request.projectSlug,
      'inbox.plans.create_followup.projectSlug'
    )
  };
  if (request.dueAt !== undefined) {
    encoded.dueAt = encodeSwiftDate(request.dueAt, 'inbox.plans.create_followup.dueAt');
  }
  return encoded;
}

export function encodeAIInboxMemoryExportRequest(
  request: AIInboxMemoryExportRequest
): { entries: Array<Record<string, unknown>> } {
  return {
    entries: requireArray(request.entries, 'inbox.memory.export.entries').map((raw, index) => {
      const entry = requireObject(raw, `inbox.memory.export.entries[${index}]`);
      return {
        memoryID: requireString(
          entry.memoryID,
          `inbox.memory.export.entries[${index}].memoryID`
        ),
        provenance: requireString(
          entry.provenance,
          `inbox.memory.export.entries[${index}].provenance`
        ),
        snippetMarkdown: requireStringValue(
          entry.snippetMarkdown,
          `inbox.memory.export.entries[${index}].snippetMarkdown`
        ),
        approvedAt: encodeSwiftDate(
          requireString(entry.approvedAt, `inbox.memory.export.entries[${index}].approvedAt`),
          `inbox.memory.export.entries[${index}].approvedAt`
        )
      };
    })
  };
}

export function encodeAIInboxGetRequest(id: string): { id: string } {
  return { id: requireString(id, 'inbox.get.id') };
}

export function encodeAIInboxRunNowRequest(force = false): { force: boolean } {
  return { force: requireBoolean(force, 'inbox.run_now.force') };
}

export function encodeAIInboxThreadGetRequest(fingerprint: string): { fingerprint: string } {
  return { fingerprint: requireString(fingerprint, 'inbox.thread.get.fingerprint') };
}

export function encodeAIInboxPlanGetRequest(id: string): { id: string } {
  return { id: requireString(id, 'inbox.plans.get.id') };
}

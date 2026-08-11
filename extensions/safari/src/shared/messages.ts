import type {
  BridgeAgentOption,
  BridgeRuntimeState,
  ContentAction,
  ContentActionResult,
  ContentPageState,
  ExtractedPageContext,
  PageContext,
  PageState,
  SafariMode,
  ScreenshotResult
} from './protocol';
import type { SerializedError } from './errors';

export interface TrustSettings {
  globalKillSwitch: boolean;
  onlyCurrentTab: boolean;
  siteAllowed: boolean;
  sensitiveSiteOverride: boolean;
  cloudScreenshotAcknowledged: boolean;
}

export interface LearningState {
  eligible: boolean;
  optedIn: boolean;
  consentSeen: boolean;
  items: LearningItem[];
}

export interface LearningItem {
  id: string;
  version: number;
  title: string;
  kind: 'memory' | 'skill' | 'site-rule';
  status: 'proposed' | 'accepted' | 'stale' | 'archived';
  summary: string;
  createdAt: string;
}

export interface TranscriptEntry {
  id: string;
  role: 'user' | 'assistant' | 'system' | 'activity';
  text: string;
  createdAt: string;
  streaming?: boolean;
  error?: boolean;
}

export interface ApprovalPreview {
  id: string;
  runId: string;
  title: string;
  summary: string;
  url: string;
  risk: 'read' | 'write' | 'sensitive' | 'destructive';
  requestedAt: string;
}

export interface ActivityEvent {
  id: string;
  runId?: string;
  text: string;
  tone: 'muted' | 'active' | 'success' | 'warning' | 'error';
  createdAt: string;
}

export interface PopupSnapshot {
  stateVersion: number;
  bridge: BridgeRuntimeState;
  mode: SafariMode;
  selectedAgentId?: string;
  page?: PageState & {
    sensitive: boolean;
    permission: 'granted' | 'prompt' | 'denied' | 'unsupported';
  };
  trust: TrustSettings;
  learning: LearningState;
  transcript: TranscriptEntry[];
  approvals: ApprovalPreview[];
  activity: ActivityEvent[];
  running: boolean;
  busy: boolean;
  lastError?: SerializedError;
}

export type PopupRequest =
  | { type: 'popup.bootstrap' }
  | { type: 'popup.refresh' }
  | { type: 'popup.setMode'; mode: SafariMode }
  | { type: 'popup.selectAgent'; agentId: string }
  | { type: 'popup.ask'; prompt: string }
  | { type: 'popup.startAgentic'; prompt: string }
  | { type: 'popup.handoff'; prompt: string }
  | { type: 'popup.approval'; approvalId: string; decision: 'allow_once' | 'allow_session' | 'block' }
  | { type: 'popup.abort' }
  | { type: 'popup.setTrust'; patch: Partial<TrustSettings> }
  | { type: 'popup.requestSitePermission' }
  | { type: 'popup.setLearning'; optedIn: boolean }
  | { type: 'popup.teachCorrection'; correction: string }
  | { type: 'popup.learningReview'; itemId: string; decision: 'approve' | 'reject' | 'forget' };

const MAX_LEARNING_CORRECTION_BYTES = 4 * 1024;
const MIN_LEARNING_CORRECTION_BYTES = 8;
const TRUST_PATCH_KEYS = new Set<keyof TrustSettings>([
  'globalKillSwitch',
  'onlyCurrentTab',
  'siteAllowed',
  'sensitiveSiteOverride',
  'cloudScreenshotAcknowledged'
]);

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function hasExactKeys(record: Record<string, unknown>, keys: readonly string[]): boolean {
  const actualKeys = Object.keys(record);
  return actualKeys.length === keys.length && keys.every((key) => Object.hasOwn(record, key));
}

function hasAllowedKeys(
  record: Record<string, unknown>,
  requiredKeys: readonly string[],
  allowedKeys: readonly string[]
): boolean {
  const allowed = new Set(allowedKeys);
  return (
    requiredKeys.every((key) => Object.hasOwn(record, key)) && Object.keys(record).every((key) => allowed.has(key))
  );
}

function isNonEmptyString(value: unknown): value is string {
  return typeof value === 'string' && value.trim().length > 0;
}

function isBoundedLearningCorrection(value: unknown): value is string {
  if (typeof value !== 'string') {
    return false;
  }
  const byteLength = new TextEncoder().encode(value.trim()).byteLength;
  return byteLength >= MIN_LEARNING_CORRECTION_BYTES && byteLength <= MAX_LEARNING_CORRECTION_BYTES;
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value);
}

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((item) => typeof item === 'string');
}

function isTrustPatch(value: unknown): value is Partial<TrustSettings> {
  if (!isRecord(value)) {
    return false;
  }
  const keys = Object.keys(value);
  return (
    keys.length > 0 &&
    keys.every((key) => TRUST_PATCH_KEYS.has(key as keyof TrustSettings) && typeof value[key] === 'boolean')
  );
}

export function isPopupRequest(value: unknown): value is PopupRequest {
  if (!isRecord(value) || typeof value.type !== 'string') {
    return false;
  }
  switch (value.type) {
    case 'popup.bootstrap':
    case 'popup.refresh':
    case 'popup.abort':
    case 'popup.requestSitePermission':
      return hasExactKeys(value, ['type']);
    case 'popup.setMode':
      return (
        hasExactKeys(value, ['type', 'mode']) &&
        (value.mode === 'ask' || value.mode === 'agentic' || value.mode === 'watch' || value.mode === 'handoff')
      );
    case 'popup.selectAgent':
      return hasExactKeys(value, ['type', 'agentId']) && isNonEmptyString(value.agentId);
    case 'popup.ask':
    case 'popup.startAgentic':
    case 'popup.handoff':
      return hasExactKeys(value, ['type', 'prompt']) && typeof value.prompt === 'string';
    case 'popup.approval':
      return (
        hasExactKeys(value, ['type', 'approvalId', 'decision']) &&
        isNonEmptyString(value.approvalId) &&
        (value.decision === 'allow_once' || value.decision === 'allow_session' || value.decision === 'block')
      );
    case 'popup.setTrust':
      return hasExactKeys(value, ['type', 'patch']) && isTrustPatch(value.patch);
    case 'popup.setLearning':
      return hasExactKeys(value, ['type', 'optedIn']) && typeof value.optedIn === 'boolean';
    case 'popup.teachCorrection':
      return hasExactKeys(value, ['type', 'correction']) && isBoundedLearningCorrection(value.correction);
    case 'popup.learningReview':
      return (
        hasExactKeys(value, ['type', 'itemId', 'decision']) &&
        isNonEmptyString(value.itemId) &&
        (value.decision === 'approve' || value.decision === 'reject' || value.decision === 'forget')
      );
    default:
      return false;
  }
}

export type PopupResponse =
  | { ok: true; snapshot: PopupSnapshot }
  | { ok: false; error: SerializedError; snapshot?: PopupSnapshot };

export type BackgroundPush = { type: 'background.snapshot'; snapshot: PopupSnapshot };

export type ContentRequest =
  | { type: 'content.ping' }
  | { type: 'content.pageContext' }
  | { type: 'content.execute'; action: ContentAction }
  | { type: 'content.capture.prepare'; token: string }
  | { type: 'content.capture.scroll'; token: string; y: number }
  | { type: 'content.capture.restore'; token: string }
  | { type: 'content.abort'; reason: string }
  | { type: 'content.image.resize'; dataUrl: string; maxLongEdge: number; quality: number };

function isActionTarget(value: unknown): boolean {
  if (!isRecord(value) || !hasAllowedKeys(value, [], ['ref', 'selector', 'point'])) {
    return false;
  }
  const hasReference = Object.hasOwn(value, 'ref');
  const hasSelector = Object.hasOwn(value, 'selector');
  const hasPoint = Object.hasOwn(value, 'point');
  if (hasReference && !isNonEmptyString(value.ref)) {
    return false;
  }
  if (hasSelector && !isNonEmptyString(value.selector)) {
    return false;
  }
  if (hasPoint) {
    if (
      !isRecord(value.point) ||
      !hasExactKeys(value.point, ['x', 'y']) ||
      !isFiniteNumber(value.point.x) ||
      !isFiniteNumber(value.point.y)
    ) {
      return false;
    }
  }
  return hasReference || hasSelector || hasPoint;
}

function hasOptionalBoolean(record: Record<string, unknown>, key: string): boolean {
  return !Object.hasOwn(record, key) || typeof record[key] === 'boolean';
}

function hasOptionalFiniteNumber(record: Record<string, unknown>, key: string): boolean {
  return !Object.hasOwn(record, key) || isFiniteNumber(record[key]);
}

function hasOptionalTarget(record: Record<string, unknown>): boolean {
  return !Object.hasOwn(record, 'target') || isActionTarget(record.target);
}

function isContentAction(value: unknown): value is ContentAction {
  if (!isRecord(value) || typeof value.kind !== 'string') {
    return false;
  }
  switch (value.kind) {
    case 'click':
      return (
        hasAllowedKeys(value, ['kind', 'target'], ['kind', 'target', 'button', 'clickCount']) &&
        isActionTarget(value.target) &&
        (!Object.hasOwn(value, 'button') ||
          value.button === 'left' ||
          value.button === 'middle' ||
          value.button === 'right') &&
        (!Object.hasOwn(value, 'clickCount') || value.clickCount === 1 || value.clickCount === 2)
      );
    case 'type':
      return (
        hasAllowedKeys(value, ['kind', 'text'], ['kind', 'target', 'text', 'clear', 'submit', 'allowSensitive']) &&
        hasOptionalTarget(value) &&
        typeof value.text === 'string' &&
        hasOptionalBoolean(value, 'clear') &&
        hasOptionalBoolean(value, 'submit') &&
        hasOptionalBoolean(value, 'allowSensitive')
      );
    case 'press_key':
      return (
        hasAllowedKeys(value, ['kind', 'key'], ['kind', 'key', 'target', 'modifiers']) &&
        isNonEmptyString(value.key) &&
        hasOptionalTarget(value) &&
        (!Object.hasOwn(value, 'modifiers') ||
          (Array.isArray(value.modifiers) &&
            value.modifiers.every(
              (modifier) => modifier === 'Alt' || modifier === 'Control' || modifier === 'Meta' || modifier === 'Shift'
            )))
      );
    case 'scroll':
      return (
        hasAllowedKeys(value, ['kind'], ['kind', 'deltaX', 'deltaY', 'target', 'behavior']) &&
        hasOptionalFiniteNumber(value, 'deltaX') &&
        hasOptionalFiniteNumber(value, 'deltaY') &&
        hasOptionalTarget(value) &&
        (!Object.hasOwn(value, 'behavior') || value.behavior === 'auto' || value.behavior === 'smooth')
      );
    case 'hover':
    case 'focus':
      return hasExactKeys(value, ['kind', 'target']) && isActionTarget(value.target);
    case 'select_option':
      return (
        hasExactKeys(value, ['kind', 'target', 'values']) && isActionTarget(value.target) && isStringArray(value.values)
      );
    case 'wait_for':
      return (
        hasAllowedKeys(value, ['kind'], ['kind', 'selector', 'text', 'state', 'timeoutMs']) &&
        (!Object.hasOwn(value, 'selector') || typeof value.selector === 'string') &&
        (!Object.hasOwn(value, 'text') || typeof value.text === 'string') &&
        (!Object.hasOwn(value, 'state') ||
          value.state === 'attached' ||
          value.state === 'detached' ||
          value.state === 'visible' ||
          value.state === 'hidden') &&
        hasOptionalFiniteNumber(value, 'timeoutMs')
      );
    case 'run_javascript':
      return (
        hasAllowedKeys(value, ['kind', 'source', 'approved'], ['kind', 'source', 'approved', 'world', 'timeoutMs']) &&
        typeof value.source === 'string' &&
        typeof value.approved === 'boolean' &&
        (!Object.hasOwn(value, 'world') || value.world === 'isolated' || value.world === 'page') &&
        hasOptionalFiniteNumber(value, 'timeoutMs')
      );
    case 'extract':
      return (
        hasAllowedKeys(value, ['kind', 'selector'], ['kind', 'selector', 'attributes', 'limit']) &&
        typeof value.selector === 'string' &&
        (!Object.hasOwn(value, 'attributes') || isStringArray(value.attributes)) &&
        hasOptionalFiniteNumber(value, 'limit')
      );
    default:
      return false;
  }
}

export function isContentRequest(value: unknown): value is ContentRequest {
  if (!isRecord(value) || typeof value.type !== 'string') {
    return false;
  }
  switch (value.type) {
    case 'content.ping':
    case 'content.pageContext':
      return hasExactKeys(value, ['type']);
    case 'content.execute':
      return hasExactKeys(value, ['type', 'action']) && isContentAction(value.action);
    case 'content.capture.prepare':
    case 'content.capture.restore':
      return hasExactKeys(value, ['type', 'token']) && isNonEmptyString(value.token);
    case 'content.capture.scroll':
      return hasExactKeys(value, ['type', 'token', 'y']) && isNonEmptyString(value.token) && isFiniteNumber(value.y);
    case 'content.abort':
      return hasExactKeys(value, ['type', 'reason']) && isNonEmptyString(value.reason);
    case 'content.image.resize':
      return (
        hasExactKeys(value, ['type', 'dataUrl', 'maxLongEdge', 'quality']) &&
        isNonEmptyString(value.dataUrl) &&
        isFiniteNumber(value.maxLongEdge) &&
        isFiniteNumber(value.quality)
      );
    default:
      return false;
  }
}

export type ContentResponse =
  | { ok: true; result: { ready: true }; pageState: ContentPageState }
  | { ok: true; result: ExtractedPageContext; pageState: ContentPageState }
  | { ok: true; result: ContentActionResult; pageState: ContentPageState }
  | {
      ok: true;
      result: {
        token: string;
        originalScrollX: number;
        originalScrollY: number;
        pageWidth: number;
        pageHeight: number;
        viewportWidth: number;
        viewportHeight: number;
        devicePixelRatio: number;
      };
      pageState: ContentPageState;
    }
  | { ok: true; result: { scrollX: number; scrollY: number }; pageState: ContentPageState }
  | { ok: true; result: ScreenshotResult; pageState: ContentPageState }
  | { ok: false; error: SerializedError; pageState: ContentPageState };

export interface PopupActionPayloads {
  ask: {
    prompt: string;
    agentId: string;
    pageContext: PageContext;
    screenshot: ScreenshotResult;
    cloudScreenshotAcknowledged: boolean;
    learningOptedIn: boolean;
  };
  agentic: {
    prompt: string;
    agentId: string;
    pageContext: PageContext;
    screenshot: ScreenshotResult;
    tabId: number;
    url: string;
    learningOptedIn: boolean;
  };
  handoff: {
    prompt: string;
    agentId: string;
    pageContext: PageContext;
    screenshot: ScreenshotResult;
    tabId: number;
  };
  approval: {
    approvalId: string;
    decision: 'allow_once' | 'allow_session' | 'block';
  };
  abort: {
    activeRunId?: string;
    reason: 'user_stop';
  };
  trust: {
    origin: string;
    settings: TrustSettings;
  };
  learning: {
    operation: 'opt_in' | 'opt_out' | 'approve' | 'reject' | 'forget';
    itemId?: string;
    expectedVersion?: number;
  };
  'learning.recall': {
    query: string;
    limit: number;
  };
  'learning.propose': {
    correctionId: string;
    correction: string;
    tabId: number;
    url: string;
  };
}

export type PopupActionName = keyof PopupActionPayloads;

export function agentsForMode(agents: BridgeAgentOption[], mode: SafariMode): BridgeAgentOption[] {
  if (mode === 'handoff') {
    return agents.filter((agent) => agent.kind === 'cli' && agent.installed);
  }
  if (mode === 'ask') {
    return agents.filter((agent) => agent.kind === 'model' && agent.supportsVision);
  }
  return agents.filter((agent) => agent.kind === 'model');
}

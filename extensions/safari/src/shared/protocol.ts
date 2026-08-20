import { SafariExtensionError, type SerializedError } from './errors';

export const SAFARI_BRIDGE_PROTOCOL_VERSION = 1 as const;
export const SAFARI_BRIDGE_CHUNK_BYTES = 384 * 1024;
export const SAFARI_SCREENSHOT_MAX_LONG_EDGE = 1568;
export const SAFARI_SCREENSHOT_JPEG_QUALITY = 82;

export type SafariMode = 'ask' | 'agentic' | 'watch' | 'handoff';

export interface ContentPageState {
  url: string;
  title: string;
  navigationEpoch: number;
  isTopFrame: boolean;
  capturedAt: string;
}

export interface PageState extends ContentPageState {
  tabId: number;
  windowId?: number;
  isActive: boolean;
}

export interface ViewportInfo {
  width: number;
  height: number;
  scrollX: number;
  scrollY: number;
  pageWidth: number;
  pageHeight: number;
  devicePixelRatio: number;
  visualViewportOffsetLeft: number;
  visualViewportOffsetTop: number;
  visualViewportScale: number;
}

export interface BoundingBox {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface SnapshotNode {
  ref: string;
  role: string;
  name: string;
  selector: string;
  box?: BoundingBox;
  description?: string;
  value?: string;
  checked?: boolean;
  disabled?: boolean;
  expanded?: boolean;
  focused?: boolean;
  selected?: boolean;
  sensitive?: boolean;
}

export interface PageContext {
  pageState: PageState;
  viewport: ViewportInfo;
  markdown: string;
  snapshot: string;
  nodes: SnapshotNode[];
  truncated: boolean;
  sensitive: boolean;
  capturedAt: string;
}

export interface ExtractedPageContext extends Omit<PageContext, 'pageState'> {
  pageState: ContentPageState;
}

export interface ScreenshotResult {
  dataUrl: string;
  mediaType: 'image/jpeg';
  width: number;
  height: number;
  byteLength: number;
  source: 'viewport' | 'full-page';
  truncated: boolean;
}

export interface ActionTarget {
  ref?: string;
  selector?: string;
  point?: {
    x: number;
    y: number;
  };
}

export interface ClickAction {
  kind: 'click';
  target: ActionTarget;
  button?: 'left' | 'middle' | 'right';
  clickCount?: 1 | 2;
}

export interface TypeAction {
  kind: 'type';
  target?: ActionTarget;
  text: string;
  clear?: boolean;
  submit?: boolean;
  allowSensitive?: boolean;
}

export interface PressKeyAction {
  kind: 'press_key';
  key: string;
  target?: ActionTarget;
  modifiers?: Array<'Alt' | 'Control' | 'Meta' | 'Shift'>;
}

export interface ScrollAction {
  kind: 'scroll';
  deltaX?: number;
  deltaY?: number;
  target?: ActionTarget;
  behavior?: 'auto' | 'smooth';
}

export interface HoverAction {
  kind: 'hover';
  target: ActionTarget;
}

export interface FocusAction {
  kind: 'focus';
  target: ActionTarget;
}

export interface SelectOptionAction {
  kind: 'select_option';
  target: ActionTarget;
  values: string[];
}

export interface WaitForAction {
  kind: 'wait_for';
  selector?: string;
  text?: string;
  state?: 'attached' | 'detached' | 'visible' | 'hidden';
  timeoutMs?: number;
}

export interface RunJavaScriptAction {
  kind: 'run_javascript';
  source: string;
  approved: boolean;
  world?: 'isolated' | 'page';
  timeoutMs?: number;
}

export interface ExtractAction {
  kind: 'extract';
  selector: string;
  attributes?: string[];
  limit?: number;
}

export type ContentAction =
  | ClickAction
  | TypeAction
  | PressKeyAction
  | ScrollAction
  | HoverAction
  | FocusAction
  | SelectOptionAction
  | WaitForAction
  | RunJavaScriptAction
  | ExtractAction;

export interface ActionVerification {
  url: string;
  title: string;
  activeElement?: string;
  target?: {
    ref?: string;
    selector?: string;
    box?: BoundingBox;
    text?: string;
    value?: string;
    checked?: boolean;
  };
}

export interface ContentActionResult {
  ok: boolean;
  result?: unknown;
  error?: SerializedError;
  pageState: ContentPageState;
  verification: ActionVerification;
}

export const SAFARI_ACTION_KINDS = [
  'page_context',
  'screenshot',
  'full_page_screenshot',
  'click',
  'type',
  'press_key',
  'scroll',
  'hover',
  'focus',
  'select_option',
  'navigate',
  'open_tab',
  'close_tab',
  'list_tabs',
  'wait_for',
  'run_javascript',
  'extract',
  'abort'
] as const;

export type SafariActionKind = (typeof SAFARI_ACTION_KINDS)[number];

export interface NativeCommand {
  commandId: string;
  sessionId: string;
  action: SafariActionKind;
  arguments: Record<string, unknown>;
  targetTabId?: number;
  expectedNavigationEpoch?: number;
  issuedAt: string;
  expiresAt: string;
}

export type BridgeMethod =
  | 'bridge.hello'
  | 'bridge.poll'
  | 'bridge.complete'
  | 'bridge.popupAction'
  | 'bridge.chunk.begin'
  | 'bridge.chunk.append'
  | 'bridge.chunk.commit';

export interface NativeRequestEnvelope<TParams extends Record<string, unknown> = Record<string, unknown>> {
  protocolVersion: typeof SAFARI_BRIDGE_PROTOCOL_VERSION;
  id: string;
  method: BridgeMethod;
  params: TParams;
}

interface NativeResponseEnvelope<TResult = unknown> {
  protocolVersion: typeof SAFARI_BRIDGE_PROTOCOL_VERSION;
  id: string;
  result?: TResult;
  error?: SerializedError;
}

export interface BridgeHelloParams extends Record<string, unknown> {
  extensionInstanceId: string;
  clientName: string;
  supportedProtocolVersions: number[];
  activePage?: PageState;
  capabilities: SafariExtensionCapabilities;
}

export interface SafariExtensionCapabilities {
  captureVisibleTab: boolean;
  scripting: boolean;
  nativeMessaging: boolean;
  activeTabPermission: boolean;
  siteAccessGranted: boolean;
}

export interface BridgeHelloResult {
  sessionId: string;
  protocolVersion: number;
  leaseExpiresAt: string;
  pollAfterMillis: number;
}

export interface SafariTabSnapshot {
  tabId: number;
  windowId?: number;
  url: string;
  title: string;
  isActive: boolean;
  isOwned: boolean;
  navigationEpoch: number;
}

export interface BridgePollParams extends Record<string, unknown> {
  sessionId: string;
  activePage?: PageState;
  knownTabs: SafariTabSnapshot[];
}

export interface BridgePollResult {
  command?: NativeCommand;
  leaseExpiresAt: string;
  pollAfterMillis: number;
}

export interface BridgeCompleteParams extends Record<string, unknown> {
  sessionId: string;
  commandId: string;
  ok: boolean;
  result?: unknown;
  error?: string;
  pageState: PageState;
  tabs: SafariTabSnapshot[];
}

interface BridgeCompleteResult {
  accepted: boolean;
}

export interface BridgePopupActionParams extends Record<string, unknown> {
  sessionId: string;
  action: string;
  payload: Record<string, unknown>;
}

export interface BridgePopupActionResult {
  accepted: boolean;
  requestId?: string;
  state?: BridgeRuntimeState;
  output?: unknown;
}

export interface BridgeRuntimeState {
  connection: 'connected' | 'degraded' | 'disconnected';
  daemonVersion?: string;
  gatewayReady: boolean;
  killSwitchEnabled: boolean;
  membership?: 'free' | 'pro' | 'pro_max' | 'ultra';
  agents: BridgeAgentOption[];
  activeRunId?: string;
}

export interface BridgeAgentOption {
  id: string;
  displayName: string;
  providerName: string;
  kind: 'model' | 'cli';
  installed: boolean;
  cloud: boolean;
  supportsVision: boolean;
}

export interface SafariBootstrapResponse {
  daemonVersion: string;
  protocolVersion: number;
  gatewayBaseURL?: string;
  gatewayBearerToken?: string;
  gatewayAttributionCapability?: string;
  gatewayAttributionExpiresAt?: string;
  gatewayAvailable: boolean;
  computerUseAvailable: boolean;
  learningAvailable: boolean;
  learningOptedIn: boolean;
  tier: string;
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    return false;
  }
  return Object.getPrototypeOf(value) === Object.prototype || Object.getPrototypeOf(value) === null;
}

export function isStringLiteral<TValue extends string>(value: unknown, allowed: readonly TValue[]): value is TValue {
  return typeof value === 'string' && allowed.some((candidate) => candidate === value);
}

export function isSafariActionKind(value: unknown): value is SafariActionKind {
  return isStringLiteral(value, SAFARI_ACTION_KINDS);
}

function isBridgeMethod(value: unknown): value is BridgeMethod {
  return (
    typeof value === 'string' &&
    (value === 'bridge.hello' ||
      value === 'bridge.poll' ||
      value === 'bridge.complete' ||
      value === 'bridge.popupAction' ||
      value === 'bridge.chunk.begin' ||
      value === 'bridge.chunk.append' ||
      value === 'bridge.chunk.commit')
  );
}

function assertExactKeys(value: Record<string, unknown>, allowed: ReadonlySet<string>, label: string): void {
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) {
      throw new SafariExtensionError('invalid_bridge_schema', `${label} contains unknown field "${key}".`);
    }
  }
}

function requireString(record: Record<string, unknown>, key: string, label: string): string {
  const value = record[key];
  if (typeof value !== 'string' || value.length === 0) {
    throw new SafariExtensionError('invalid_bridge_schema', `${label}.${key} must be a non-empty string.`);
  }
  return value;
}

function optionalString(record: Record<string, unknown>, key: string, label: string): string | undefined {
  const value = record[key];
  if (value === undefined) {
    return undefined;
  }
  if (typeof value !== 'string') {
    throw new SafariExtensionError('invalid_bridge_schema', `${label}.${key} must be a string.`);
  }
  return value;
}

function requireSafeInteger(record: Record<string, unknown>, key: string, label: string): number {
  const value = record[key];
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 0) {
    throw new SafariExtensionError('invalid_bridge_schema', `${label}.${key} must be a non-negative safe integer.`);
  }
  return value;
}

function optionalSafeInteger(record: Record<string, unknown>, key: string, label: string): number | undefined {
  if (record[key] === undefined) {
    return undefined;
  }
  return requireSafeInteger(record, key, label);
}

function requireBoolean(record: Record<string, unknown>, key: string, label: string): boolean {
  const value = record[key];
  if (typeof value !== 'boolean') {
    throw new SafariExtensionError('invalid_bridge_schema', `${label}.${key} must be boolean.`);
  }
  return value;
}

function requireISODate(record: Record<string, unknown>, key: string, label: string): string {
  const value = requireString(record, key, label);
  if (!Number.isFinite(Date.parse(value))) {
    throw new SafariExtensionError('invalid_bridge_schema', `${label}.${key} must be an ISO-8601 date.`);
  }
  return value;
}

export function createNativeRequest<TParams extends Record<string, unknown>>(
  id: string,
  method: BridgeMethod,
  params: TParams
): NativeRequestEnvelope<TParams> {
  const envelope: NativeRequestEnvelope<TParams> = {
    protocolVersion: SAFARI_BRIDGE_PROTOCOL_VERSION,
    id,
    method,
    params
  };
  validateNativeRequest(envelope);
  return envelope;
}

export function validateNativeRequest(value: unknown): asserts value is NativeRequestEnvelope {
  if (!isRecord(value)) {
    throw new SafariExtensionError('invalid_bridge_schema', 'Native request must be an object.');
  }
  assertExactKeys(value, new Set(['protocolVersion', 'id', 'method', 'params']), 'request');
  if (value.protocolVersion !== SAFARI_BRIDGE_PROTOCOL_VERSION) {
    throw new SafariExtensionError('protocol_mismatch', 'Unsupported Safari bridge protocol version.');
  }
  requireString(value, 'id', 'request');
  const method = requireString(value, 'method', 'request');
  if (!isBridgeMethod(method)) {
    throw new SafariExtensionError('invalid_bridge_method', `Unsupported Safari bridge method "${method}".`);
  }
  if (!isRecord(value.params)) {
    throw new SafariExtensionError('invalid_bridge_schema', 'request.params must be an object.');
  }
  validateMethodParams(method, value.params);
}

function validateMethodParams(method: BridgeMethod, params: Record<string, unknown>): void {
  switch (method) {
    case 'bridge.hello':
      validateHelloParams(params);
      break;
    case 'bridge.poll':
      validatePollParams(params);
      break;
    case 'bridge.complete':
      validateCompleteParams(params);
      break;
    case 'bridge.popupAction':
      validatePopupActionParams(params);
      break;
    case 'bridge.chunk.begin':
      validateChunkBeginParams(params);
      break;
    case 'bridge.chunk.append':
      validateChunkAppendParams(params);
      break;
    case 'bridge.chunk.commit':
      validateChunkCommitParams(params);
      break;
  }
}

function validateHelloParams(params: Record<string, unknown>): void {
  assertExactKeys(
    params,
    new Set(['extensionInstanceId', 'clientName', 'supportedProtocolVersions', 'activePage', 'capabilities']),
    'bridge.hello.params'
  );
  requireString(params, 'extensionInstanceId', 'bridge.hello.params');
  requireString(params, 'clientName', 'bridge.hello.params');
  if (
    !Array.isArray(params.supportedProtocolVersions) ||
    params.supportedProtocolVersions.length === 0 ||
    !params.supportedProtocolVersions.every((version) => Number.isSafeInteger(version) && Number(version) > 0)
  ) {
    throw new SafariExtensionError(
      'invalid_bridge_schema',
      'bridge.hello.params.supportedProtocolVersions must contain positive integers.'
    );
  }
  if (params.activePage !== undefined) {
    validatePageState(params.activePage, 'bridge.hello.params.activePage');
  }
  if (!isRecord(params.capabilities)) {
    throw new SafariExtensionError('invalid_bridge_schema', 'bridge.hello.params.capabilities must be an object.');
  }
  assertExactKeys(
    params.capabilities,
    new Set(['captureVisibleTab', 'scripting', 'nativeMessaging', 'activeTabPermission', 'siteAccessGranted']),
    'bridge.hello.params.capabilities'
  );
  for (const field of [
    'captureVisibleTab',
    'scripting',
    'nativeMessaging',
    'activeTabPermission',
    'siteAccessGranted'
  ]) {
    requireBoolean(params.capabilities, field, 'bridge.hello.params.capabilities');
  }
}

function validatePollParams(params: Record<string, unknown>): void {
  assertExactKeys(params, new Set(['sessionId', 'activePage', 'knownTabs']), 'bridge.poll.params');
  requireString(params, 'sessionId', 'bridge.poll.params');
  if (params.activePage !== undefined) {
    validatePageState(params.activePage, 'bridge.poll.params.activePage');
  }
  if (!Array.isArray(params.knownTabs)) {
    throw new SafariExtensionError('invalid_bridge_schema', 'bridge.poll.params.knownTabs must be an array.');
  }
  for (const tab of params.knownTabs) {
    validateTabSnapshot(tab, 'bridge.poll.params.knownTabs[]');
  }
}

function validateCompleteParams(params: Record<string, unknown>): void {
  assertExactKeys(
    params,
    new Set(['sessionId', 'commandId', 'ok', 'result', 'error', 'pageState', 'tabs']),
    'bridge.complete.params'
  );
  requireString(params, 'sessionId', 'bridge.complete.params');
  requireString(params, 'commandId', 'bridge.complete.params');
  requireBoolean(params, 'ok', 'bridge.complete.params');
  if (params.error !== undefined && typeof params.error !== 'string') {
    throw new SafariExtensionError('invalid_bridge_schema', 'bridge.complete.params.error must be a string.');
  }
  validatePageState(params.pageState, 'bridge.complete.params.pageState');
  if (!Array.isArray(params.tabs)) {
    throw new SafariExtensionError('invalid_bridge_schema', 'bridge.complete.params.tabs must be an array.');
  }
  for (const tab of params.tabs) {
    validateTabSnapshot(tab, 'bridge.complete.params.tabs[]');
  }
}

function validatePageState(value: unknown, label: string): asserts value is PageState {
  if (!isRecord(value)) {
    throw new SafariExtensionError('invalid_bridge_schema', `${label} must be an object.`);
  }
  assertExactKeys(
    value,
    new Set(['tabId', 'windowId', 'url', 'title', 'navigationEpoch', 'isActive', 'isTopFrame', 'capturedAt']),
    label
  );
  requireSafeInteger(value, 'tabId', label);
  optionalSafeInteger(value, 'windowId', label);
  requireString(value, 'url', label);
  if (typeof value.title !== 'string') {
    throw new SafariExtensionError('invalid_bridge_schema', `${label}.title must be a string.`);
  }
  requireSafeInteger(value, 'navigationEpoch', label);
  requireBoolean(value, 'isActive', label);
  requireBoolean(value, 'isTopFrame', label);
  requireISODate(value, 'capturedAt', label);
}

function validateTabSnapshot(value: unknown, label: string): asserts value is SafariTabSnapshot {
  if (!isRecord(value)) {
    throw new SafariExtensionError('invalid_bridge_schema', `${label} must be an object.`);
  }
  assertExactKeys(
    value,
    new Set(['tabId', 'windowId', 'url', 'title', 'isActive', 'isOwned', 'navigationEpoch']),
    label
  );
  requireSafeInteger(value, 'tabId', label);
  optionalSafeInteger(value, 'windowId', label);
  requireString(value, 'url', label);
  if (typeof value.title !== 'string') {
    throw new SafariExtensionError('invalid_bridge_schema', `${label}.title must be a string.`);
  }
  requireBoolean(value, 'isActive', label);
  requireBoolean(value, 'isOwned', label);
  requireSafeInteger(value, 'navigationEpoch', label);
}

function validatePopupActionParams(params: Record<string, unknown>): void {
  assertExactKeys(params, new Set(['sessionId', 'action', 'payload']), 'bridge.popupAction.params');
  requireString(params, 'sessionId', 'bridge.popupAction.params');
  requireString(params, 'action', 'bridge.popupAction.params');
  if (!isRecord(params.payload)) {
    throw new SafariExtensionError('invalid_bridge_schema', 'bridge.popupAction.params.payload must be an object.');
  }
}

function validateChunkBeginParams(params: Record<string, unknown>): void {
  assertExactKeys(
    params,
    new Set(['transferId', 'originalMethod', 'byteLength', 'chunkCount', 'sha256']),
    'bridge.chunk.begin.params'
  );
  requireString(params, 'transferId', 'bridge.chunk.begin.params');
  const originalMethod = requireString(params, 'originalMethod', 'bridge.chunk.begin.params');
  if (!isBridgeMethod(originalMethod) || originalMethod.startsWith('bridge.chunk.')) {
    throw new SafariExtensionError('invalid_bridge_schema', 'bridge.chunk.begin originalMethod is invalid.');
  }
  requireSafeInteger(params, 'byteLength', 'bridge.chunk.begin.params');
  const chunkCount = requireSafeInteger(params, 'chunkCount', 'bridge.chunk.begin.params');
  if (chunkCount < 1 || chunkCount > 4096) {
    throw new SafariExtensionError('invalid_bridge_schema', 'bridge.chunk.begin chunkCount is out of range.');
  }
  const sha256 = requireString(params, 'sha256', 'bridge.chunk.begin.params');
  if (!/^[a-f0-9]{64}$/u.test(sha256)) {
    throw new SafariExtensionError('invalid_bridge_schema', 'bridge.chunk.begin sha256 must be lowercase hex.');
  }
}

function validateChunkAppendParams(params: Record<string, unknown>): void {
  assertExactKeys(params, new Set(['transferId', 'index', 'data']), 'bridge.chunk.append.params');
  requireString(params, 'transferId', 'bridge.chunk.append.params');
  requireSafeInteger(params, 'index', 'bridge.chunk.append.params');
  requireString(params, 'data', 'bridge.chunk.append.params');
}

function validateChunkCommitParams(params: Record<string, unknown>): void {
  assertExactKeys(params, new Set(['transferId']), 'bridge.chunk.commit.params');
  requireString(params, 'transferId', 'bridge.chunk.commit.params');
}

export function parseNativeResponse(value: unknown, expectedId: string): NativeResponseEnvelope {
  if (!isRecord(value)) {
    throw new SafariExtensionError('invalid_bridge_schema', 'Native response must be an object.');
  }
  assertExactKeys(value, new Set(['protocolVersion', 'id', 'result', 'error']), 'response');
  if (value.protocolVersion !== SAFARI_BRIDGE_PROTOCOL_VERSION) {
    throw new SafariExtensionError('protocol_mismatch', 'Native response protocol version does not match.');
  }
  if (requireString(value, 'id', 'response') !== expectedId) {
    throw new SafariExtensionError('bridge_response_mismatch', 'Native response ID does not match its request.');
  }
  const hasResult = Object.hasOwn(value, 'result');
  const hasError = Object.hasOwn(value, 'error');
  if (hasResult === hasError) {
    throw new SafariExtensionError(
      'invalid_bridge_schema',
      'Native response must contain exactly one of result or error.'
    );
  }
  if (hasError) {
    validateSerializedError(value.error);
    return {
      protocolVersion: SAFARI_BRIDGE_PROTOCOL_VERSION,
      id: expectedId,
      error: value.error
    };
  }
  return {
    protocolVersion: SAFARI_BRIDGE_PROTOCOL_VERSION,
    id: expectedId,
    result: value.result
  };
}

export function parseBridgeHelloResult(value: unknown): BridgeHelloResult {
  if (!isRecord(value)) {
    throw new SafariExtensionError('invalid_bridge_schema', 'bridge.hello result must be an object.');
  }
  assertExactKeys(
    value,
    new Set(['sessionId', 'protocolVersion', 'leaseExpiresAt', 'pollAfterMillis']),
    'bridge.hello.result'
  );
  return {
    sessionId: requireString(value, 'sessionId', 'bridge.hello.result'),
    protocolVersion: requireSafeInteger(value, 'protocolVersion', 'bridge.hello.result'),
    leaseExpiresAt: requireISODate(value, 'leaseExpiresAt', 'bridge.hello.result'),
    pollAfterMillis: requireSafeInteger(value, 'pollAfterMillis', 'bridge.hello.result')
  };
}

export function parseBridgePollResult(value: unknown): BridgePollResult {
  if (!isRecord(value)) {
    throw new SafariExtensionError('invalid_bridge_schema', 'bridge.poll result must be an object.');
  }
  assertExactKeys(value, new Set(['command', 'leaseExpiresAt', 'pollAfterMillis']), 'bridge.poll.result');
  const command = value.command === undefined || value.command === null ? undefined : parseNativeCommand(value.command);
  return {
    leaseExpiresAt: requireISODate(value, 'leaseExpiresAt', 'bridge.poll.result'),
    pollAfterMillis: requireSafeInteger(value, 'pollAfterMillis', 'bridge.poll.result'),
    ...(command === undefined ? {} : { command })
  };
}

export function parseBridgeCompleteResult(value: unknown): BridgeCompleteResult {
  if (!isRecord(value)) {
    throw new SafariExtensionError('invalid_bridge_schema', 'bridge.complete result must be an object.');
  }
  assertExactKeys(value, new Set(['accepted']), 'bridge.complete.result');
  return {
    accepted: requireBoolean(value, 'accepted', 'bridge.complete.result')
  };
}

export function parseBridgePopupActionResult(value: unknown): BridgePopupActionResult {
  if (!isRecord(value)) {
    throw new SafariExtensionError('invalid_bridge_schema', 'bridge.popupAction result must be an object.');
  }
  assertExactKeys(value, new Set(['accepted', 'requestId', 'state', 'output']), 'bridge.popupAction.result');
  if (typeof value.accepted !== 'boolean') {
    throw new SafariExtensionError('invalid_bridge_schema', 'bridge.popupAction result.accepted must be boolean.');
  }
  const requestId = optionalString(value, 'requestId', 'bridge.popupAction.result');
  const state = value.state === undefined ? undefined : parseBridgeRuntimeState(value.state);
  return {
    accepted: value.accepted,
    ...(requestId === undefined ? {} : { requestId }),
    ...(state === undefined ? {} : { state }),
    ...(Object.hasOwn(value, 'output') ? { output: value.output } : {})
  };
}

export function parseBridgeRuntimeState(value: unknown): BridgeRuntimeState {
  if (!isRecord(value)) {
    throw new SafariExtensionError('invalid_bridge_schema', 'Bridge runtime state must be an object.');
  }
  assertExactKeys(
    value,
    new Set([
      'connection',
      'daemonVersion',
      'gatewayReady',
      'killSwitchEnabled',
      'membership',
      'agents',
      'activeRunId'
    ]),
    'bridge.state'
  );
  if (!isStringLiteral(value.connection, ['connected', 'degraded', 'disconnected'])) {
    throw new SafariExtensionError('invalid_bridge_schema', 'bridge.state.connection is invalid.');
  }
  if (typeof value.gatewayReady !== 'boolean' || typeof value.killSwitchEnabled !== 'boolean') {
    throw new SafariExtensionError('invalid_bridge_schema', 'bridge.state readiness fields must be boolean.');
  }
  if (!Array.isArray(value.agents)) {
    throw new SafariExtensionError('invalid_bridge_schema', 'bridge.state.agents must be an array.');
  }
  const daemonVersion = optionalString(value, 'daemonVersion', 'bridge.state');
  const activeRunId = optionalString(value, 'activeRunId', 'bridge.state');
  let membership: BridgeRuntimeState['membership'];
  if (value.membership !== undefined) {
    if (!isStringLiteral(value.membership, ['free', 'pro', 'pro_max', 'ultra'])) {
      throw new SafariExtensionError('invalid_bridge_schema', 'bridge.state.membership is invalid.');
    }
    membership = value.membership;
  }
  return {
    connection: value.connection,
    gatewayReady: value.gatewayReady,
    killSwitchEnabled: value.killSwitchEnabled,
    agents: value.agents.map((agent) => parseAgentOption(agent)),
    ...(daemonVersion === undefined ? {} : { daemonVersion }),
    ...(membership === undefined ? {} : { membership }),
    ...(activeRunId === undefined ? {} : { activeRunId })
  };
}

export function parseSafariBootstrapResponse(value: unknown): SafariBootstrapResponse {
  if (!isRecord(value)) {
    throw new SafariExtensionError('invalid_bridge_schema', 'Safari bootstrap response must be an object.');
  }
  assertExactKeys(
    value,
    new Set([
      'daemonVersion',
      'protocolVersion',
      'gatewayBaseURL',
      'gatewayBearerToken',
      'gatewayAttributionCapability',
      'gatewayAttributionExpiresAt',
      'gatewayAvailable',
      'computerUseAvailable',
      'learningAvailable',
      'learningOptedIn',
      'tier'
    ]),
    'safari.bootstrap'
  );
  const gatewayBaseURL = optionalString(value, 'gatewayBaseURL', 'safari.bootstrap');
  const gatewayBearerToken = optionalString(value, 'gatewayBearerToken', 'safari.bootstrap');
  const gatewayAttributionCapability = optionalString(value, 'gatewayAttributionCapability', 'safari.bootstrap');
  const gatewayAttributionExpiresAt = optionalString(value, 'gatewayAttributionExpiresAt', 'safari.bootstrap');
  return {
    daemonVersion: requireString(value, 'daemonVersion', 'safari.bootstrap'),
    protocolVersion: requireSafeInteger(value, 'protocolVersion', 'safari.bootstrap'),
    gatewayAvailable: requireBoolean(value, 'gatewayAvailable', 'safari.bootstrap'),
    computerUseAvailable: requireBoolean(value, 'computerUseAvailable', 'safari.bootstrap'),
    learningAvailable: requireBoolean(value, 'learningAvailable', 'safari.bootstrap'),
    learningOptedIn: requireBoolean(value, 'learningOptedIn', 'safari.bootstrap'),
    tier: requireString(value, 'tier', 'safari.bootstrap'),
    ...(gatewayBaseURL === undefined ? {} : { gatewayBaseURL }),
    ...(gatewayBearerToken === undefined ? {} : { gatewayBearerToken }),
    ...(gatewayAttributionCapability === undefined ? {} : { gatewayAttributionCapability }),
    ...(gatewayAttributionExpiresAt === undefined ? {} : { gatewayAttributionExpiresAt })
  };
}

function parseAgentOption(value: unknown): BridgeAgentOption {
  if (!isRecord(value)) {
    throw new SafariExtensionError('invalid_bridge_schema', 'Agent option must be an object.');
  }
  assertExactKeys(
    value,
    new Set(['id', 'displayName', 'providerName', 'kind', 'installed', 'cloud', 'supportsVision']),
    'bridge.agent'
  );
  const kind = requireString(value, 'kind', 'bridge.agent');
  if (kind !== 'model' && kind !== 'cli') {
    throw new SafariExtensionError('invalid_bridge_schema', 'bridge.agent.kind is invalid.');
  }
  if (
    typeof value.installed !== 'boolean' ||
    typeof value.cloud !== 'boolean' ||
    typeof value.supportsVision !== 'boolean'
  ) {
    throw new SafariExtensionError('invalid_bridge_schema', 'bridge.agent boolean fields are invalid.');
  }
  return {
    id: requireString(value, 'id', 'bridge.agent'),
    displayName: requireString(value, 'displayName', 'bridge.agent'),
    providerName: requireString(value, 'providerName', 'bridge.agent'),
    kind,
    installed: value.installed,
    cloud: value.cloud,
    supportsVision: value.supportsVision
  };
}

function parseNativeCommand(value: unknown): NativeCommand {
  if (!isRecord(value)) {
    throw new SafariExtensionError('invalid_bridge_schema', 'Native command must be an object.');
  }
  assertExactKeys(
    value,
    new Set([
      'commandId',
      'sessionId',
      'action',
      'arguments',
      'targetTabId',
      'expectedNavigationEpoch',
      'issuedAt',
      'expiresAt'
    ]),
    'bridge.command'
  );
  const action = requireString(value, 'action', 'bridge.command');
  if (!isSafariActionKind(action)) {
    throw new SafariExtensionError('invalid_bridge_schema', `Unsupported Safari command action "${action}".`);
  }
  if (!isRecord(value.arguments)) {
    throw new SafariExtensionError('invalid_bridge_schema', 'bridge.command.arguments must be an object.');
  }
  const targetTabId = optionalSafeInteger(value, 'targetTabId', 'bridge.command');
  const expectedNavigationEpoch = optionalSafeInteger(value, 'expectedNavigationEpoch', 'bridge.command');
  return {
    commandId: requireString(value, 'commandId', 'bridge.command'),
    sessionId: requireString(value, 'sessionId', 'bridge.command'),
    action,
    arguments: value.arguments,
    issuedAt: requireISODate(value, 'issuedAt', 'bridge.command'),
    expiresAt: requireISODate(value, 'expiresAt', 'bridge.command'),
    ...(targetTabId === undefined ? {} : { targetTabId }),
    ...(expectedNavigationEpoch === undefined ? {} : { expectedNavigationEpoch })
  };
}

function validateSerializedError(value: unknown): asserts value is SerializedError {
  if (!isRecord(value)) {
    throw new SafariExtensionError('invalid_bridge_schema', 'response.error must be an object.');
  }
  assertExactKeys(value, new Set(['code', 'message', 'retryable', 'details']), 'response.error');
  requireString(value, 'code', 'response.error');
  requireString(value, 'message', 'response.error');
  if (typeof value.retryable !== 'boolean') {
    throw new SafariExtensionError('invalid_bridge_schema', 'response.error.retryable must be boolean.');
  }
}

export function unwrapNativeResponse(response: NativeResponseEnvelope): unknown {
  if (response.error) {
    throw new SafariExtensionError(response.error.code, response.error.message, {
      retryable: response.error.retryable,
      ...(response.error.details === undefined ? {} : { details: response.error.details })
    });
  }
  return response.result;
}

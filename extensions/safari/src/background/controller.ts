import { SafariCaptureService } from './capture';
import { SafariGatewayClient } from './gatewayClient';
import type { NativeBridge } from './nativeBridge';
import { SafariPageAdapter } from './pageAdapter';
import { SafariPerformanceRecorder } from './performance';
import { SitePermissionController, type SitePermissionStatus } from './permissions';
import { SafariSessionStore, type SafariPreferences } from './sessionStore';
import { TabOwnershipRegistry } from './tabOwnership';
import { activeTab, type BrowserAPI, type BrowserTab } from '../shared/browser';
import { SafariExtensionError, serializeError } from '../shared/errors';
import {
  agentsForMode,
  type ActivityEvent,
  type ApprovalPreview,
  type BackgroundPush,
  type LearningItem,
  type PopupActionName,
  type PopupActionPayloads,
  type PopupRequest,
  type PopupResponse,
  type PopupSnapshot,
  type TranscriptEntry,
  type TrustSettings
} from '../shared/messages';
import {
  isRecord,
  parseSafariBootstrapResponse,
  type ActionTarget,
  type BridgeAgentOption,
  type BridgeRuntimeState,
  type ContentAction,
  type NativeCommand,
  type PageContext,
  type PageState,
  type SafariActionKind,
  type SafariExtensionCapabilities,
  type SafariMode,
  type SafariTabSnapshot,
  type ScreenshotResult
} from '../shared/protocol';
import type {
  SafariPerformanceContext,
  SafariPerformanceMetricName,
  SafariPerformanceOutcome
} from '../shared/performance';

const MAX_TRANSCRIPT_ENTRIES = 80;
const MAX_ACTIVITY_ENTRIES = 80;
const MAX_APPROVALS = 20;
const MAX_LEARNED_CONTEXT_BYTES = 16 * 1024;
const MAX_LEARNING_CORRECTION_BYTES = 4 * 1024;
const MAX_LEARNING_RECALL_QUERY_BYTES = 2 * 1024;
const MIN_LEARNING_CORRECTION_BYTES = 8;
const LEARNING_RECALL_LIMIT = 8;
const POLL_ERROR_BACKOFF_MS = 1_500;
const ASK_STREAM_FLUSH_INTERVAL_MS = 40;
const ASK_LENGTH_LIMIT_NOTE = 'The model reached its output limit, so this answer may be cut short.';
const UTF8_ENCODER = new TextEncoder();
const SAFARI_HANDOFF_BLOCKED_AGENT_IDS = new Set(['droid', 'forge', 'kimi', 'junie']);

const INITIAL_BRIDGE_STATE: BridgeRuntimeState = {
  connection: 'disconnected',
  gatewayReady: false,
  killSwitchEnabled: false,
  agents: []
};

interface SafariBackgroundControllerOptions {
  startPolling?: boolean;
  performanceRecorder?: SafariPerformanceRecorder;
}

interface AskTiming {
  startedAt: number;
  recorded: boolean;
  route: NonNullable<SafariPerformanceContext['route']>;
}

function nowISO(): string {
  return new Date().toISOString();
}

function sleep(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function pageURLLooksSensitive(url: string): boolean {
  return /(?:^|[./_-])(bank|billing|checkout|credential|login|oauth|payment|signin)(?:[./_?&=-]|$)/iu.test(url);
}

function originForURL(url: string | undefined): string | undefined {
  if (!url) {
    return undefined;
  }
  try {
    const parsed = new URL(url);
    return ['http:', 'https:'].includes(parsed.protocol) ? parsed.origin : undefined;
  } catch {
    return undefined;
  }
}

function stringField(record: Record<string, unknown>, key: string): string | undefined {
  const value = record[key];
  return typeof value === 'string' ? value : undefined;
}

function booleanField(record: Record<string, unknown>, key: string): boolean | undefined {
  const value = record[key];
  return typeof value === 'boolean' ? value : undefined;
}

function numberField(record: Record<string, unknown>, key: string): number | undefined {
  const value = record[key];
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined;
}

function utf8ByteLength(value: string): number {
  return UTF8_ENCODER.encode(value).byteLength;
}

function boundedUTF8Prefix(value: string, maximumBytes: number): string {
  if (utf8ByteLength(value) <= maximumBytes) {
    return value;
  }
  let result = '';
  let bytes = 0;
  for (const character of value) {
    const characterBytes = utf8ByteLength(character);
    if (bytes + characterBytes > maximumBytes) {
      break;
    }
    result += character;
    bytes += characterBytes;
  }
  return result;
}

function pageTitleForTab(tab: BrowserTab): string {
  const title = tab.title?.trim();
  if (title) {
    return boundedUTF8Prefix(title, 8192);
  }
  try {
    const parsed = new URL(tab.url ?? '');
    const path = parsed.pathname && parsed.pathname !== '/' ? parsed.pathname : '';
    const fallback = `${parsed.hostname}${path}`.trim();
    return boundedUTF8Prefix(fallback || 'Safari page', 8192);
  } catch {
    return 'Safari page';
  }
}

function targetFromArguments(argumentsValue: Record<string, unknown>): ActionTarget {
  const candidate = isRecord(argumentsValue.target) ? argumentsValue.target : argumentsValue;
  const target: ActionTarget = {};
  if (typeof candidate.ref === 'string') {
    target.ref = candidate.ref;
  }
  if (typeof candidate.selector === 'string') {
    target.selector = candidate.selector;
  }
  if (isRecord(candidate.point) && typeof candidate.point.x === 'number' && typeof candidate.point.y === 'number') {
    target.point = {
      x: candidate.point.x,
      y: candidate.point.y
    };
  } else if (typeof candidate.x === 'number' && typeof candidate.y === 'number') {
    target.point = {
      x: candidate.x,
      y: candidate.y
    };
  } else if (typeof candidate.positionX === 'number' && typeof candidate.positionY === 'number') {
    target.point = {
      x: candidate.positionX,
      y: candidate.positionY
    };
  }
  if (!target.ref && !target.selector && !target.point) {
    throw new SafariExtensionError('missing_target', 'The Safari command does not contain a target.');
  }
  return target;
}

function hasTargetArguments(argumentsValue: Record<string, unknown>): boolean {
  const candidate = isRecord(argumentsValue.target) ? argumentsValue.target : argumentsValue;
  return (
    typeof candidate.ref === 'string' ||
    typeof candidate.selector === 'string' ||
    (isRecord(candidate.point) && typeof candidate.point.x === 'number' && typeof candidate.point.y === 'number') ||
    (typeof candidate.x === 'number' && typeof candidate.y === 'number') ||
    (typeof candidate.positionX === 'number' && typeof candidate.positionY === 'number')
  );
}

function safeWebURL(value: unknown): string {
  if (typeof value !== 'string') {
    throw new SafariExtensionError('navigation_url_missing', 'Navigation requires a URL.');
  }
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new SafariExtensionError('navigation_url_invalid', 'The requested URL is invalid.');
  }
  if (!['http:', 'https:'].includes(url.protocol)) {
    throw new SafariExtensionError(
      'navigation_protocol_blocked',
      'OpenBurnBar blocks non-HTTP navigation such as file:, data:, and javascript: URLs.'
    );
  }
  return url.href;
}

function selectedAgentForMode(
  agents: BridgeAgentOption[],
  mode: SafariMode,
  selectedAgentId: string | undefined
): BridgeAgentOption | undefined {
  const compatible = agentsForMode(agents, mode);
  return compatible.find((agent) => agent.id === selectedAgentId) ?? compatible[0];
}

function incompatibleAgentError(mode: 'ask' | 'agentic' | 'handoff'): SafariExtensionError {
  if (mode === 'handoff') {
    return new SafariExtensionError('agent_not_installed', 'Hand-off requires an installed agent CLI.');
  }
  if (mode === 'ask') {
    return new SafariExtensionError('vision_model_required', 'Ask mode requires an available vision-capable model.');
  }
  return new SafariExtensionError('model_required', 'Agentic mode requires an available model.');
}

function performanceOutcome(error: unknown): SafariPerformanceOutcome {
  if (
    (error instanceof SafariExtensionError && error.code === 'gateway_aborted') ||
    (error instanceof Error && error.name === 'AbortError')
  ) {
    return 'aborted';
  }
  return 'error';
}

function measuresActionVerification(action: SafariActionKind): boolean {
  switch (action) {
    case 'page_context':
    case 'screenshot':
    case 'full_page_screenshot':
    case 'list_tabs':
    case 'extract':
    case 'abort':
      return false;
    default:
      return true;
  }
}

export class SafariBackgroundController {
  private readonly pageAdapter: SafariPageAdapter;
  private readonly captureService: SafariCaptureService;
  private readonly permissionController: SitePermissionController;
  private readonly store: SafariSessionStore;
  private readonly performanceRecorder: SafariPerformanceRecorder;
  private readonly ownership = new TabOwnershipRegistry();
  private readonly nativeTrustedOrigins = new Set<string>();
  private preferences: SafariPreferences = {
    mode: 'ask',
    onlyCurrentTab: true,
    automaticallyTrustInvokedWebsites: false,
    cloudScreenshotDisclosureAcknowledged: false,
    learningOptedIn: false,
    learningConsentSeen: false,
    sites: {}
  };
  private snapshot: PopupSnapshot = {
    stateVersion: 1,
    bridge: { ...INITIAL_BRIDGE_STATE },
    mode: 'ask',
    trust: {
      globalKillSwitch: false,
      onlyCurrentTab: true,
      siteAllowed: false,
      sensitiveSiteOverride: false,
      cloudScreenshotAcknowledged: false
    },
    learning: {
      eligible: false,
      optedIn: false,
      consentSeen: false,
      items: []
    },
    transcript: [],
    approvals: [],
    activity: [],
    running: false,
    busy: false
  };
  private initialized = false;
  private initializing: Promise<void> | undefined;
  private attachmentTail: Promise<void> = Promise.resolve();
  private pollLoopRunning = false;
  private pollGeneration = 0;
  private localWorkGeneration = 0;
  private localTurnActive = false;
  private nativeProjectionInFlight: Promise<void> | undefined;
  private pageAuthorizationInFlight:
    | {
        key: string;
        promise: Promise<void>;
      }
    | undefined;
  private locallyHaltedSession: { sessionId: string | undefined } | undefined;
  private readonly navigationEpochs = new Map<number, number>();

  constructor(
    private readonly browserAPI: BrowserAPI,
    private readonly bridge: NativeBridge,
    private readonly gatewayClient = new SafariGatewayClient(),
    private readonly options: SafariBackgroundControllerOptions = {}
  ) {
    this.performanceRecorder = options.performanceRecorder ?? new SafariPerformanceRecorder(browserAPI);
    this.pageAdapter = new SafariPageAdapter(browserAPI);
    this.captureService = new SafariCaptureService(browserAPI, this.pageAdapter, undefined, this.performanceRecorder);
    this.permissionController = new SitePermissionController(browserAPI);
    this.store = new SafariSessionStore(browserAPI);
    this.gatewayClient.setConfigurationRenewer((signal) => this.requestNativeBootstrap(signal));
    this.browserAPI.tabs.onRemoved?.addListener((tabId) => {
      this.ownership.release(tabId);
      this.navigationEpochs.delete(tabId);
    });
    this.browserAPI.tabs.onUpdated?.addListener((tabId, changeInfo) => {
      if (typeof changeInfo.url === 'string' || changeInfo.status === 'loading') {
        this.navigationEpochs.set(tabId, (this.navigationEpochs.get(tabId) ?? 0) + 1);
      }
    });
  }

  async initialize(force = false): Promise<void> {
    if (this.initialized && !force) {
      return;
    }
    if (force && this.pageAuthorizationInFlight) {
      await this.pageAuthorizationInFlight.promise;
    }
    if (this.initializing) {
      return this.initializing;
    }
    this.initializing = this.performInitialization()
      .then(() => {
        this.initialized = true;
      })
      .finally(() => {
        this.initializing = undefined;
      });
    return this.initializing;
  }

  async handlePopupRequest(request: PopupRequest): Promise<PopupResponse> {
    if (
      request.type === 'popup.performanceSnapshot' ||
      request.type === 'popup.clearPerformance' ||
      request.type === 'popup.recordPerformance'
    ) {
      await this.performanceRecorder.load();
      if (request.type === 'popup.clearPerformance') {
        await this.performanceRecorder.clear();
      } else {
        if (request.type === 'popup.recordPerformance') {
          this.performanceRecorder.recordDuration(request.metric, request.durationMs, request.outcome);
        }
        await this.performanceRecorder.flush();
      }
      return { ok: true, snapshot: this.copySnapshot() };
    }
    const errorAtStart = this.snapshot.lastError;
    try {
      await this.initialize();
      switch (request.type) {
        case 'popup.bootstrap':
          await this.refreshPopupProjection();
          break;
        case 'popup.refresh':
          await this.refreshPopupProjection();
          break;
        case 'popup.setMode':
          await this.setMode(request.mode);
          break;
        case 'popup.selectAgent':
          await this.selectAgent(request.agentId);
          break;
        case 'popup.ask':
          await this.submitTurn('ask', request.prompt);
          break;
        case 'popup.startAgentic':
          await this.submitTurn('agentic', request.prompt);
          break;
        case 'popup.handoff':
          await this.submitTurn('handoff', request.prompt);
          break;
        case 'popup.approval':
          await this.respondToApproval(request.approvalId, request.decision);
          break;
        case 'popup.abort':
          await this.measurePerformance('stop_panic', { trigger: request.trigger }, () => this.abortRun());
          break;
        case 'popup.setTrust':
          await this.setTrust(request.patch);
          break;
        case 'popup.requestSitePermission':
          await this.requestSitePermission();
          break;
        case 'popup.authorizePage':
          await this.authorizePage(request);
          break;
        case 'popup.setLearning':
          await this.measurePerformance(
            'learning_mutation',
            { learningOperation: request.optedIn ? 'opt_in' : 'opt_out' },
            () => this.setLearning(request.optedIn)
          );
          break;
        case 'popup.teachCorrection':
          await this.measurePerformance('learning_mutation', { learningOperation: 'propose' }, () =>
            this.teachCorrection(request.correction)
          );
          break;
        case 'popup.learningReview':
          await this.measurePerformance('learning_mutation', { learningOperation: request.decision }, () =>
            this.reviewLearning(request.itemId, request.decision)
          );
          break;
      }
      this.clearError(errorAtStart);
      return { ok: true, snapshot: this.copySnapshot() };
    } catch (error) {
      const serialized = serializeError(error, 'popup_request_failed');
      this.mutate((state) => {
        state.lastError = serialized;
        state.busy = false;
      });
      return { ok: false, error: serialized, snapshot: this.copySnapshot() };
    }
  }

  currentSnapshot(): PopupSnapshot {
    return this.copySnapshot();
  }

  private async performInitialization(): Promise<void> {
    const [preferences] = await Promise.all([this.store.load(), this.performanceRecorder.load()]);
    this.preferences = preferences;
    this.mutate((state) => {
      state.mode = this.preferences.mode;
      if (this.preferences.selectedAgentId) {
        state.selectedAgentId = this.preferences.selectedAgentId;
      } else {
        delete state.selectedAgentId;
      }
      state.trust.onlyCurrentTab = this.preferences.onlyCurrentTab;
      state.trust.cloudScreenshotAcknowledged = this.preferences.cloudScreenshotDisclosureAcknowledged;
      state.learning.optedIn = this.preferences.learningOptedIn;
      state.learning.consentSeen = this.preferences.learningConsentSeen;
      state.busy = true;
    });

    const tab = await activeTab(this.browserAPI);
    const activePage = tab ? this.pageStateFromTab(tab) : undefined;
    const permission = tab?.url ? await this.permissionController.status(tab.url) : 'unsupported';
    const capabilities = this.capabilities(permission);
    this.publishCurrentPage(tab, permission);

    try {
      await this.withAttachmentLock(async () => {
        const previousSessionId = this.bridge.sessionId;
        const attached = await this.measurePerformance('native_attach', undefined, async () => {
          const response = await this.bridge.hello(activePage, capabilities);
          if (response.protocolVersion !== 1) {
            throw new SafariExtensionError(
              'protocol_mismatch',
              `OpenBurnBar negotiated unsupported Safari protocol ${response.protocolVersion}.`
            );
          }
          return response;
        });
        if (previousSessionId !== attached.sessionId) {
          if (previousSessionId) {
            this.ownership.releaseSession(previousSessionId);
          }
          this.locallyHaltedSession = undefined;
          this.nativeTrustedOrigins.clear();
          this.localWorkGeneration += 1;
        }
        if (tab) {
          this.ownership.claimUserHanded(tab, attached.sessionId);
        }
        await this.bootstrapNative();
        await this.refreshNativeProjection();
        await this.refreshCatalog();
        this.mutate((state) => {
          state.bridge.connection = 'connected';
          state.busy = false;
        });
      });
      if (this.options.startPolling !== false) {
        this.startPollLoop();
      }
    } catch (error) {
      this.gatewayClient.clear();
      this.mutate((state) => {
        state.bridge = {
          ...INITIAL_BRIDGE_STATE,
          connection: 'disconnected'
        };
        state.busy = false;
        state.lastError = serializeError(error, 'native_bridge_unavailable');
      });
    }
    await this.refreshCurrentPage(false);
  }

  private async withAttachmentLock<TResult>(operation: () => Promise<TResult>): Promise<TResult> {
    const predecessor = this.attachmentTail;
    let release: (() => void) | undefined;
    this.attachmentTail = new Promise<void>((resolve) => {
      release = resolve;
    });
    await predecessor;
    try {
      return await operation();
    } finally {
      release?.();
    }
  }

  private capabilities(permission: SitePermissionStatus): SafariExtensionCapabilities {
    return {
      captureVisibleTab: typeof this.browserAPI.tabs.captureVisibleTab === 'function',
      scripting: typeof this.browserAPI.scripting.executeScript === 'function',
      nativeMessaging: typeof this.browserAPI.runtime.sendNativeMessage === 'function',
      activeTabPermission: true,
      siteAccessGranted: permission === 'granted'
    };
  }

  private async bootstrapNative(): Promise<void> {
    const bootstrap = await this.requestNativeBootstrap();
    let gatewayConfigurationError: ReturnType<typeof serializeError> | undefined;
    try {
      this.gatewayClient.configure(bootstrap);
    } catch (error) {
      this.gatewayClient.clear();
      gatewayConfigurationError = serializeError(error, 'gateway_configuration_invalid');
    }
    const membership = normalizeMembership(bootstrap.tier);
    this.mutate((state) => {
      state.bridge.connection =
        this.gatewayClient.isConfigured || bootstrap.computerUseAvailable ? 'connected' : 'degraded';
      state.bridge.daemonVersion = bootstrap.daemonVersion;
      state.bridge.gatewayReady = this.gatewayClient.isConfigured;
      state.learning.eligible = bootstrap.learningAvailable && membership !== 'free';
      state.learning.optedIn = state.learning.eligible && bootstrap.learningOptedIn;
      state.bridge.membership = membership;
      if (gatewayConfigurationError) {
        state.lastError = gatewayConfigurationError;
        this.appendActivityTo(
          state,
          'The local Ask gateway was rejected because its loopback connection details were unsafe or incomplete.',
          'error'
        );
      }
      if (!bootstrap.computerUseAvailable) {
        this.appendActivityTo(
          state,
          'Computer Use is unavailable; Ask mode remains available when the gateway is ready.',
          'warning'
        );
      }
    });
  }

  private async requestNativeBootstrap(signal?: AbortSignal): Promise<ReturnType<typeof parseSafariBootstrapResponse>> {
    const nativeRequest = this.bridge.popupAction('bootstrap', {
      ...(this.bridge.sessionId ? { sessionId: this.bridge.sessionId } : {})
    });
    const response = signal ? await this.awaitUnlessAborted(nativeRequest, signal) : await nativeRequest;
    const output =
      isRecord(response.output) && 'bootstrap' in response.output ? response.output.bootstrap : response.output;
    const bootstrap = parseSafariBootstrapResponse(output);
    if (bootstrap.protocolVersion !== 1) {
      throw new SafariExtensionError(
        'protocol_mismatch',
        `OpenBurnBar returned unsupported Safari bootstrap protocol ${bootstrap.protocolVersion}.`
      );
    }
    return bootstrap;
  }

  private async awaitUnlessAborted<T>(operation: Promise<T>, signal: AbortSignal): Promise<T> {
    if (signal.aborted) {
      throw new SafariExtensionError('gateway_aborted', 'Stopped.');
    }
    return new Promise<T>((resolve, reject) => {
      const abort = (): void => {
        reject(new SafariExtensionError('gateway_aborted', 'Stopped.'));
      };
      signal.addEventListener('abort', abort, { once: true });
      operation.then(resolve, reject).finally(() => {
        signal.removeEventListener('abort', abort);
      });
    });
  }

  private async refreshCatalog(): Promise<void> {
    try {
      const response = await this.bridge.popupAction('catalog', {});
      const catalogModels = normalizeAgents(response.output).filter((agent) => agent.kind === 'model');
      this.mutate((state) => {
        const installedAgents = state.bridge.agents.filter((agent) => agent.kind === 'cli');
        const agents = sortUniqueAgents([...catalogModels, ...installedAgents]);
        state.bridge.agents = agents;
        const selectedAgent = selectedAgentForMode(agents, state.mode, state.selectedAgentId);
        if (selectedAgent) {
          state.selectedAgentId = selectedAgent.id;
        } else {
          delete state.selectedAgentId;
        }
      });
      if (this.snapshot.selectedAgentId) {
        this.preferences.selectedAgentId = this.snapshot.selectedAgentId;
      } else {
        delete this.preferences.selectedAgentId;
      }
      await this.store.save(this.preferences);
    } catch (error) {
      this.appendActivity('Agent catalog is temporarily unavailable.', 'warning');
      if (this.snapshot.bridge.agents.length === 0) {
        throw error;
      }
    }
  }

  private startPollLoop(): void {
    if (this.pollLoopRunning) {
      return;
    }
    this.pollLoopRunning = true;
    const generation = ++this.pollGeneration;
    void this.pollLoop(generation).finally(() => {
      if (generation === this.pollGeneration) {
        this.pollLoopRunning = false;
      }
    });
  }

  private async pollLoop(generation: number): Promise<void> {
    while (generation === this.pollGeneration && this.bridge.sessionId) {
      try {
        await sleep(await this.pollOnce());
      } catch (error) {
        this.mutate((state) => {
          state.bridge.connection = 'degraded';
          state.lastError = serializeError(error, 'native_poll_failed');
        });
        await sleep(POLL_ERROR_BACKOFF_MS);
      }
    }
  }

  async pollOnce(): Promise<number> {
    if (!this.bridge.sessionId) {
      throw new SafariExtensionError('safari_session_detached', 'The Safari extension is not attached to OpenBurnBar.');
    }
    const startedAt = this.performanceRecorder.start();
    let poll: Awaited<ReturnType<NativeBridge['poll']>>;
    try {
      const knownTabs = await this.knownTabs();
      const activePage = await this.activeNativePage();
      poll = await this.bridge.poll(activePage, knownTabs);
      this.performanceRecorder.recordElapsed('command_poll', startedAt, 'success', {
        command: poll.command ? 'issued' : 'empty'
      });
    } catch (error) {
      this.performanceRecorder.recordElapsed('command_poll', startedAt, performanceOutcome(error));
      throw error;
    }
    if (poll.command) {
      await this.executeAndComplete(poll.command);
    }
    return Math.min(Math.max(poll.pollAfterMillis, 100), 5_000);
  }

  private async executeAndComplete(command: NativeCommand): Promise<void> {
    let result: unknown;
    let ok = false;
    let errorMessage: string | undefined;
    let pageState: PageState;
    const actionStartedAt = measuresActionVerification(command.action) ? this.performanceRecorder.start() : undefined;
    const stopStartedAt = command.action === 'abort' ? this.performanceRecorder.start() : undefined;
    let actionOutcome: SafariPerformanceOutcome = 'success';
    try {
      if (command.sessionId !== this.bridge.sessionId) {
        throw new SafariExtensionError(
          'safari_session_mismatch',
          'The daemon command belongs to another Safari session.'
        );
      }
      if (command.action !== 'abort' && this.isSessionLocallyHalted(command.sessionId)) {
        throw new SafariExtensionError(
          'safari_session_halted',
          'This Safari session was stopped locally. Start a new Agentic run or reconnect the extension before executing another command.'
        );
      }
      if (Date.parse(command.expiresAt) <= Date.now()) {
        throw new SafariExtensionError('safari_command_expired', 'The daemon command expired before execution.');
      }
      result = await this.executeCommand(command);
      ok = true;
      pageState = (await this.activeNativePage()) ?? this.fallbackPageState(command.targetTabId);
    } catch (error) {
      actionOutcome = performanceOutcome(error);
      errorMessage = serializeError(error, 'safari_command_failed').message;
      pageState = (await this.activeNativePage()) ?? this.fallbackPageState(command.targetTabId);
    }
    if (actionStartedAt !== undefined) {
      this.performanceRecorder.recordElapsed('action_verification', actionStartedAt, actionOutcome, {
        action: command.action
      });
    }
    if (stopStartedAt !== undefined) {
      this.performanceRecorder.recordElapsed('stop_panic', stopStartedAt, actionOutcome, {
        trigger: 'daemon_abort'
      });
    }
    await this.measurePerformance('command_completion', { action: command.action }, async () => {
      await this.bridge.complete({
        commandId: command.commandId,
        ok,
        ...(ok ? { result } : {}),
        ...(errorMessage === undefined ? {} : { error: errorMessage }),
        pageState,
        tabs: await this.knownTabs()
      });
    });
  }

  private async executeCommand(command: NativeCommand): Promise<unknown> {
    switch (command.action) {
      case 'list_tabs':
        return this.knownTabs();
      case 'open_tab':
        return this.openTab(command);
      case 'abort': {
        const reason = 'The daemon halted this Safari session.';
        this.activateLocalHalt(command.sessionId, 'The daemon stopped this Safari session.');
        await this.abortOwnedTabs(reason, command.sessionId);
        return { aborted: true };
      }
      default:
        break;
    }

    const tab = await this.targetTab(command);
    this.ownership.assertOwned(tab, command.sessionId, command.action !== 'close_tab');
    const knownEpoch = typeof tab.id === 'number' ? (this.navigationEpochs.get(tab.id) ?? 0) : 0;
    if (command.expectedNavigationEpoch !== undefined && command.expectedNavigationEpoch !== knownEpoch) {
      throw new SafariExtensionError(
        'navigation_epoch_mismatch',
        'The page navigated after the daemon planned this action; OpenBurnBar refused stale coordinates.'
      );
    }

    switch (command.action) {
      case 'page_context': {
        const context = await this.pageAdapter.pageContext(tab);
        this.recordEpoch(context.pageState);
        return context;
      }
      case 'screenshot':
        return this.captureService.viewport(tab);
      case 'full_page_screenshot':
        return this.captureService.fullPage(tab, command.arguments.optIn === true);
      case 'navigate':
        return this.navigate(tab, command.arguments);
      case 'close_tab':
        return this.closeTab(tab, command.sessionId);
      case 'click':
      case 'type':
      case 'press_key':
      case 'scroll':
      case 'hover':
      case 'focus':
      case 'select_option':
      case 'wait_for':
      case 'run_javascript':
      case 'extract': {
        const action = contentAction(command.action, command.arguments);
        const execution = await this.pageAdapter.execute(tab, action);
        this.recordEpoch(execution.pageState);
        if (!execution.ok) {
          throw new SafariExtensionError(
            execution.error?.code ?? 'content_action_failed',
            execution.error?.message ?? 'The Safari page action failed.',
            { retryable: execution.error?.retryable ?? false }
          );
        }
        return execution;
      }
    }
  }

  private async targetTab(command: NativeCommand): Promise<BrowserTab> {
    const requested = command.targetTabId;
    if (typeof requested === 'number') {
      return this.browserAPI.tabs.get(requested);
    }
    const tab = await activeTab(this.browserAPI);
    if (!tab) {
      throw new SafariExtensionError('active_tab_missing', 'Safari does not have an active tab.');
    }
    return tab;
  }

  private async navigate(tab: BrowserTab, argumentsValue: Record<string, unknown>): Promise<PageState> {
    if (typeof tab.id !== 'number') {
      throw new SafariExtensionError('tab_id_missing', 'Safari did not provide a target tab identifier.');
    }
    const operation = stringField(argumentsValue, 'operation') ?? 'url';
    switch (operation) {
      case 'url':
        await this.browserAPI.tabs.update(tab.id, { url: safeWebURL(argumentsValue.url), active: true });
        break;
      case 'back':
        if (!this.browserAPI.tabs.goBack) {
          throw new SafariExtensionError(
            'navigation_unsupported',
            'This Safari version does not support extension back navigation.'
          );
        }
        await this.browserAPI.tabs.goBack(tab.id);
        break;
      case 'forward':
        if (!this.browserAPI.tabs.goForward) {
          throw new SafariExtensionError(
            'navigation_unsupported',
            'This Safari version does not support extension forward navigation.'
          );
        }
        await this.browserAPI.tabs.goForward(tab.id);
        break;
      case 'reload':
        await this.browserAPI.tabs.reload(tab.id);
        break;
      default:
        throw new SafariExtensionError(
          'navigation_operation_invalid',
          `Unsupported navigation operation "${operation}".`
        );
    }
    this.navigationEpochs.set(tab.id, (this.navigationEpochs.get(tab.id) ?? 0) + 1);
    await sleep(150);
    return this.pageStateFromTab(await this.browserAPI.tabs.get(tab.id));
  }

  private async openTab(command: NativeCommand): Promise<SafariTabSnapshot> {
    if (this.snapshot.trust.onlyCurrentTab) {
      throw new SafariExtensionError(
        'tab_scope_blocked',
        'This session is restricted to the current tab. Change the trust control before opening another tab.'
      );
    }
    const url = safeWebURL(command.arguments.url);
    const tab = await this.browserAPI.tabs.create({ url, active: true });
    const ownership = this.ownership.registerAgentOpened(tab, command.sessionId);
    this.navigationEpochs.set(ownership.tabId, 0);
    return this.tabSnapshot(tab);
  }

  private async closeTab(tab: BrowserTab, sessionId: string): Promise<{ closedTabId: number }> {
    const owned = this.ownership.assertOwned(tab, sessionId, false);
    await this.browserAPI.tabs.remove(owned.tabId);
    this.ownership.release(owned.tabId);
    this.navigationEpochs.delete(owned.tabId);
    return { closedTabId: owned.tabId };
  }

  private async abortRun(): Promise<void> {
    const sessionId = this.bridge.sessionId;
    const activeRunId = this.snapshot.bridge.activeRunId;
    this.activateLocalHalt(sessionId, 'Stopped. No further Safari actions will run in this session.');
    await this.abortOwnedTabs('The user stopped this Safari session.', sessionId);
    const response = await this.bridge.popupAction('abort', {
      ...(activeRunId ? { runId: activeRunId } : {}),
      reason: 'user_stop'
    });
    if (!response.accepted) {
      throw new SafariExtensionError(
        'abort_rejected',
        'Safari stopped locally, but OpenBurnBar did not confirm daemon cancellation.'
      );
    }
  }

  private async abortOwnedTabs(reason: string, sessionId = this.bridge.sessionId): Promise<void> {
    if (!sessionId) {
      return;
    }
    const owned = this.ownership.list().filter((entry) => entry.sessionId === sessionId);
    await Promise.allSettled(
      owned.map(async (entry) => {
        let tab: BrowserTab;
        try {
          tab = await this.browserAPI.tabs.get(entry.tabId);
        } catch {
          this.ownership.release(entry.tabId);
          this.navigationEpochs.delete(entry.tabId);
          return;
        }
        await this.pageAdapter.abort(tab, reason);
      })
    );
  }

  private activateLocalHalt(sessionId: string | undefined, activity: string): void {
    this.locallyHaltedSession = { sessionId };
    this.localWorkGeneration += 1;
    this.gatewayClient.abortActiveRequest();
    this.mutate((state) => {
      state.running = false;
      state.busy = false;
      state.approvals = [];
      this.appendActivityTo(state, activity, 'warning');
    });
  }

  private isSessionLocallyHalted(sessionId: string | undefined): boolean {
    return Boolean(
      this.locallyHaltedSession &&
      this.locallyHaltedSession.sessionId !== undefined &&
      this.locallyHaltedSession.sessionId === sessionId
    );
  }

  private assertLocalWorkCurrent(workGeneration: number): void {
    if (workGeneration !== this.localWorkGeneration) {
      throw new SafariExtensionError('gateway_aborted', 'Stopped.');
    }
  }

  private localWorkWasStopped(workGeneration: number, error: unknown): boolean {
    return (
      workGeneration !== this.localWorkGeneration ||
      (error instanceof SafariExtensionError && error.code === 'gateway_aborted')
    );
  }

  private async submitTurn(mode: 'ask' | 'agentic' | 'handoff', prompt: string): Promise<void> {
    if (this.snapshot.busy) {
      throw new SafariExtensionError('request_in_progress', 'OpenBurnBar is already handling another request.');
    }
    const workGeneration = this.localWorkGeneration;
    const turnStartedAt = this.performanceRecorder.start();
    const normalizedPrompt = prompt.trim();
    if (!normalizedPrompt) {
      throw new SafariExtensionError('prompt_empty', 'Tell OpenBurnBar what you want to know or do.');
    }
    const selectedAgent = this.requireSelectedAgent(mode);
    this.localTurnActive = true;
    const askTiming: AskTiming | undefined =
      mode === 'ask'
        ? {
            startedAt: turnStartedAt,
            recorded: false,
            route: selectedAgent.cloud ? 'cloud' : 'local'
          }
        : undefined;
    let turnOutcome: SafariPerformanceOutcome = 'success';
    this.mutate((state) => {
      state.busy = true;
      state.mode = mode;
      this.appendTranscriptTo(state, 'user', normalizedPrompt);
    });
    try {
      await this.nativeProjectionInFlight;
      this.assertLocalWorkCurrent(workGeneration);
      const prepared = await this.prepareTurn(mode, workGeneration);
      this.assertLocalWorkCurrent(workGeneration);
      if (mode === 'ask') {
        await this.submitAsk(
          normalizedPrompt,
          prepared.agent,
          prepared.context,
          prepared.screenshot,
          workGeneration,
          askTiming
        );
        return;
      }
      const response =
        mode === 'agentic'
          ? await this.popupAction('agentic', {
              prompt: normalizedPrompt,
              agentId: prepared.agent.id,
              pageContext: prepared.context,
              screenshot: prepared.screenshot,
              tabId: prepared.context.pageState.tabId,
              url: prepared.context.pageState.url,
              learningOptedIn: this.snapshot.learning.optedIn
            })
          : await this.popupAction('handoff', {
              prompt: normalizedPrompt,
              agentId: prepared.agent.id,
              pageContext: prepared.context,
              screenshot: prepared.screenshot,
              tabId: prepared.context.pageState.tabId
            });
      this.assertLocalWorkCurrent(workGeneration);
      if (mode === 'agentic' && response.accepted) {
        this.locallyHaltedSession = undefined;
      }
      this.applyPopupActionOutput(response.output);
      const reportedRunning = isRecord(response.output) ? booleanField(response.output, 'running') : undefined;
      this.mutate((state) => {
        state.busy = false;
        state.running = reportedRunning ?? (mode === 'agentic' && response.accepted);
        this.appendActivityTo(
          state,
          response.accepted
            ? mode === 'handoff'
              ? 'The private page briefing was handed to the selected local agent.'
              : 'The run is attached to this tab and waiting on verified actions.'
            : 'OpenBurnBar did not accept the request.',
          response.accepted ? 'active' : 'warning'
        );
      });
    } catch (error) {
      turnOutcome = performanceOutcome(error);
      if (this.localWorkWasStopped(workGeneration, error)) {
        this.mutate((state) => {
          state.busy = false;
          state.running = false;
          if (mode === 'ask') {
            this.appendTranscriptTo(state, 'assistant', 'Stopped.');
          }
        });
        return;
      }
      throw error;
    } finally {
      this.localTurnActive = false;
      if (askTiming && !askTiming.recorded) {
        const outcome =
          workGeneration !== this.localWorkGeneration ? 'aborted' : turnOutcome === 'success' ? 'error' : turnOutcome;
        this.performanceRecorder.recordElapsed('ask_first_token', askTiming.startedAt, outcome, {
          route: askTiming.route
        });
        askTiming.recorded = true;
      }
    }
  }

  private async submitAsk(
    prompt: string,
    agent: BridgeAgentOption,
    context: PageContext,
    screenshot: ScreenshotResult,
    workGeneration: number,
    timing: AskTiming | undefined
  ): Promise<void> {
    const transcriptId = crypto.randomUUID();
    this.mutate((state) => {
      state.transcript.push({
        id: transcriptId,
        role: 'assistant',
        text: '',
        createdAt: nowISO(),
        streaming: true
      });
      state.transcript = state.transcript.slice(-MAX_TRANSCRIPT_ENTRIES);
    });

    let answer = '';
    let renderedAnswer = '';
    // This runs in the MV3 background service worker: there is no `window`
    // here, so timers must go through the global scope. `tsconfig.background.json`
    // typechecks this file against the WebWorker lib to keep it that way.
    let flushTimer: ReturnType<typeof setTimeout> | undefined;
    const flush = (): void => {
      if (flushTimer !== undefined) {
        clearTimeout(flushTimer);
        flushTimer = undefined;
      }
      if (answer === renderedAnswer) {
        return;
      }
      renderedAnswer = answer;
      this.mutate((state) => {
        const entry = state.transcript.find((candidate) => candidate.id === transcriptId);
        if (entry) {
          entry.text = renderedAnswer;
        }
      });
    };
    const scheduleFlush = (): void => {
      if (flushTimer === undefined) {
        flushTimer = setTimeout(flush, ASK_STREAM_FLUSH_INTERVAL_MS);
      }
    };

    try {
      const learnedContext = await this.recallLearningContext(prompt);
      this.assertLocalWorkCurrent(workGeneration);
      const completedAnswer = await this.gatewayClient.ask(
        {
          agentId: agent.id,
          prompt,
          pageContext: context,
          screenshot,
          ...(learnedContext === undefined ? {} : { learnedContext })
        },
        (delta) => {
          if (workGeneration !== this.localWorkGeneration) {
            return;
          }
          if (timing && !timing.recorded) {
            this.performanceRecorder.recordElapsed('ask_first_token', timing.startedAt, 'success', {
              route: timing.route
            });
            timing.recorded = true;
          }
          answer += delta;
          scheduleFlush();
        }
      );
      this.assertLocalWorkCurrent(workGeneration);
      answer = completedAnswer.answer;
      flush();
      const cutShort = completedAnswer.finishReason === 'length';
      this.mutate((state) => {
        const entry = state.transcript.find((candidate) => candidate.id === transcriptId);
        if (entry) {
          entry.text = completedAnswer.answer;
          entry.streaming = false;
          if (cutShort) {
            entry.note = ASK_LENGTH_LIMIT_NOTE;
          }
        }
        state.busy = false;
        state.running = false;
        this.appendActivityTo(state, 'Answered with page structure and the visible Safari viewport.', 'success');
        if (cutShort) {
          this.appendActivityTo(state, ASK_LENGTH_LIMIT_NOTE, 'warning');
        }
      });
    } catch (error) {
      flush();
      if (this.localWorkWasStopped(workGeneration, error)) {
        this.mutate((state) => {
          const entry = state.transcript.find((candidate) => candidate.id === transcriptId);
          if (entry) {
            entry.streaming = false;
            delete entry.error;
            if (!entry.text) {
              entry.text = 'Stopped.';
            }
          }
          state.busy = false;
          state.running = false;
        });
        return;
      }
      const reason = serializeError(error, 'ask_failed').message || 'OpenBurnBar could not complete this page answer.';
      this.mutate((state) => {
        const entry = state.transcript.find((candidate) => candidate.id === transcriptId);
        if (entry) {
          entry.streaming = false;
          entry.error = true;
          if (entry.text) {
            // Partial text stays visible, but it must never pass for the whole
            // answer: say why it stopped, right under the message.
            entry.note = `Answer interrupted: ${reason}`;
          } else {
            entry.text = 'OpenBurnBar could not complete this page answer.';
            entry.note = reason;
          }
        }
      });
      throw error;
    } finally {
      if (flushTimer !== undefined) {
        clearTimeout(flushTimer);
      }
    }
  }

  private async recallLearningContext(query: string): Promise<string | undefined> {
    if (!this.snapshot.learning.optedIn) {
      return undefined;
    }
    const boundedQuery = boundedUTF8Prefix(query.trim(), MAX_LEARNING_RECALL_QUERY_BYTES);
    if (!boundedQuery) {
      return undefined;
    }
    try {
      const response = await this.popupAction('learning.recall', {
        query: boundedQuery,
        limit: LEARNING_RECALL_LIMIT
      });
      if (!response.accepted || !isRecord(response.output)) {
        return undefined;
      }
      const context = stringField(response.output, 'untrustedContext')?.trim();
      if (!context || utf8ByteLength(context) > MAX_LEARNED_CONTEXT_BYTES) {
        return undefined;
      }
      return context;
    } catch {
      // Personalization must never make Ask unavailable. The native bridge and
      // daemon still enforce entitlement, session, redaction, and size bounds.
      return undefined;
    }
  }

  private async prepareTurn(
    mode: 'ask' | 'agentic' | 'handoff',
    workGeneration: number
  ): Promise<{
    agent: BridgeAgentOption;
    context: PageContext;
    screenshot: ScreenshotResult;
  }> {
    const tab = await activeTab(this.browserAPI);
    if (!tab || typeof tab.id !== 'number' || !tab.url) {
      throw new SafariExtensionError('active_tab_missing', 'Open a regular webpage in Safari first.');
    }
    const origin = originForURL(tab.url);
    if (!origin || !this.preferences.sites[origin]?.allowed) {
      throw new SafariExtensionError('site_not_allowed', 'Allow OpenBurnBar on this site before sharing page context.');
    }
    if (mode !== 'ask' && (this.snapshot.trust.globalKillSwitch || this.snapshot.bridge.killSwitchEnabled)) {
      throw new SafariExtensionError('kill_switch_enabled', 'Computer Use is stopped by the global kill switch.');
    }
    if (this.snapshot.page?.sensitive && mode !== 'ask' && !this.snapshot.trust.sensitiveSiteOverride) {
      throw new SafariExtensionError(
        'sensitive_site_blocked',
        'Agentic actions on credential, banking, billing, or payment pages require an explicit site override.'
      );
    }
    const agent = this.requireSelectedAgent(mode);
    if (mode === 'ask') {
      await this.gatewayClient.ensureProviderConfiguration();
      this.assertLocalWorkCurrent(workGeneration);
      this.mutate((state) => {
        state.bridge.gatewayReady = this.gatewayClient.isConfigured;
      });
    }
    if (agent.cloud && !this.snapshot.trust.cloudScreenshotAcknowledged) {
      throw new SafariExtensionError(
        'cloud_screenshot_notice_required',
        'Acknowledge that this screenshot will be sent to the selected cloud model for this session.'
      );
    }
    this.ownership.claimUserHanded(tab, this.bridge.sessionId ?? 'detached');
    this.assertLocalWorkCurrent(workGeneration);
    const context = await this.pageAdapter.pageContext(tab);
    this.assertLocalWorkCurrent(workGeneration);
    const screenshot = await this.captureService.viewport(tab);
    this.assertLocalWorkCurrent(workGeneration);
    this.recordEpoch(context.pageState);
    this.mutate((state) => {
      if (state.page) {
        state.page.sensitive = context.sensitive;
        Object.assign(state.page, context.pageState);
      }
    });
    return { agent, context, screenshot };
  }

  private async popupAction<TName extends PopupActionName>(
    action: TName,
    payload: PopupActionPayloads[TName]
  ): ReturnType<NativeBridge['popupAction']> {
    return this.bridge.popupAction(action, payload);
  }

  private async respondToApproval(
    approvalId: string,
    decision: 'allow_once' | 'allow_session' | 'block'
  ): Promise<void> {
    const response = await this.popupAction('approval', { approvalId, decision });
    if (!response.accepted) {
      throw new SafariExtensionError('approval_rejected', 'OpenBurnBar did not accept the approval decision.');
    }
    this.mutate((state) => {
      state.approvals = state.approvals.filter((approval) => approval.id !== approvalId);
      this.appendActivityTo(
        state,
        decision === 'block'
          ? 'Action blocked.'
          : decision === 'allow_session'
            ? 'Allowed for this session.'
            : 'Allowed once.',
        decision === 'block' ? 'warning' : 'success'
      );
    });
  }

  private async setMode(mode: SafariMode): Promise<void> {
    const selectedAgent = selectedAgentForMode(this.snapshot.bridge.agents, mode, this.snapshot.selectedAgentId);
    this.preferences.mode = mode;
    if (selectedAgent) {
      this.preferences.selectedAgentId = selectedAgent.id;
    } else {
      delete this.preferences.selectedAgentId;
    }
    await this.store.save(this.preferences);
    this.mutate((state) => {
      state.mode = mode;
      if (selectedAgent) {
        state.selectedAgentId = selectedAgent.id;
      } else {
        delete state.selectedAgentId;
      }
      if (mode === 'watch') {
        this.appendActivityTo(state, 'Watching active OpenBurnBar runs and approvals.', 'active');
      }
    });
  }

  private async selectAgent(agentId: string): Promise<void> {
    const knownAgent = this.snapshot.bridge.agents.find((agent) => agent.id === agentId);
    if (!knownAgent) {
      throw new SafariExtensionError('agent_unknown', 'The selected agent is no longer available.');
    }
    if (!agentsForMode(this.snapshot.bridge.agents, this.snapshot.mode).some((agent) => agent.id === agentId)) {
      throw new SafariExtensionError(
        'agent_incompatible',
        `${knownAgent.displayName} is not compatible with ${this.snapshot.mode} mode.`
      );
    }
    this.preferences.selectedAgentId = agentId;
    await this.store.save(this.preferences);
    this.mutate((state) => {
      state.selectedAgentId = agentId;
    });
  }

  private requireSelectedAgent(mode: 'ask' | 'agentic' | 'handoff'): BridgeAgentOption {
    const selectedAgent = agentsForMode(this.snapshot.bridge.agents, mode).find(
      (candidate) => candidate.id === this.snapshot.selectedAgentId
    );
    if (!selectedAgent) {
      throw incompatibleAgentError(mode);
    }
    return selectedAgent;
  }

  private async setTrust(patch: Partial<TrustSettings>): Promise<void> {
    const tab = await activeTab(this.browserAPI);
    const origin = originForURL(tab?.url);
    const nextPreferences: SafariPreferences = {
      ...this.preferences,
      sites: { ...this.preferences.sites }
    };

    if (patch.globalKillSwitch !== undefined) {
      const response = await this.bridge.popupAction('trust.update', {
        killSwitchEnabled: patch.globalKillSwitch
      });
      if (!response.accepted) {
        throw new SafariExtensionError('kill_switch_rejected', 'OpenBurnBar did not accept the kill-switch change.');
      }
    }
    if (patch.onlyCurrentTab !== undefined) {
      nextPreferences.onlyCurrentTab = patch.onlyCurrentTab;
    }
    if (patch.cloudScreenshotAcknowledged !== undefined) {
      nextPreferences.cloudScreenshotDisclosureAcknowledged = patch.cloudScreenshotAcknowledged;
    }
    if (patch.siteAllowed !== undefined || patch.sensitiveSiteOverride !== undefined) {
      if (!origin) {
        throw new SafariExtensionError(
          'site_trust_origin_missing',
          'Open a regular HTTP or HTTPS page before changing site trust.'
        );
      }
      const existing = nextPreferences.sites[origin] ?? { allowed: false, sensitiveOverride: false };
      const proposedSite = {
        allowed: patch.siteAllowed ?? existing.allowed,
        sensitiveOverride: patch.sensitiveSiteOverride ?? existing.sensitiveOverride
      };
      const response = await this.bridge.popupAction('trust.update', {
        origin,
        decision: proposedSite.allowed ? 'allow' : 'deny',
        trustMode: proposedSite.allowed ? 'step' : 'manual'
      });
      if (!response.accepted) {
        throw new SafariExtensionError('trust_update_rejected', 'OpenBurnBar did not accept the site trust change.');
      }
      if (proposedSite.allowed) {
        this.nativeTrustedOrigins.add(origin);
      } else {
        this.nativeTrustedOrigins.delete(origin);
      }
      nextPreferences.sites[origin] = proposedSite;
    }
    await this.store.save(nextPreferences);
    this.preferences = nextPreferences;
    this.mutate((state) => {
      state.trust = {
        ...state.trust,
        ...patch
      };
    });
  }

  private async requestSitePermission(): Promise<void> {
    const tab = await activeTab(this.browserAPI);
    if (!tab?.url) {
      throw new SafariExtensionError('active_tab_missing', 'Open a regular webpage in Safari first.');
    }
    const status = await this.permissionController.request(tab.url);
    if (status !== 'granted') {
      throw new SafariExtensionError(
        'site_permission_denied',
        'Safari did not grant access. Use Safari Settings → Extensions → OpenBurnBar to allow this website.'
      );
    }
    const origin = originForURL(tab.url);
    if (origin) {
      await this.setTrust({ siteAllowed: true });
      this.preferences.automaticallyTrustInvokedWebsites = true;
      await this.store.save(this.preferences);
    }
    await this.initialize(true);
  }

  private async authorizePage(request: Extract<PopupRequest, { type: 'popup.authorizePage' }>): Promise<void> {
    const authorizationKey = [
      request.expectedStateVersion,
      request.expectedTabId,
      request.expectedOrigin,
      request.acknowledgeCloudScreenshots,
      request.websiteAccessGranted
    ].join(':');
    if (this.pageAuthorizationInFlight) {
      if (this.pageAuthorizationInFlight.key !== authorizationKey) {
        throw new SafariExtensionError(
          'authorization_in_progress',
          'A different Safari permission request is already finishing. Wait for it to complete, then try again.'
        );
      }
      return this.pageAuthorizationInFlight.promise;
    }
    const operation = this.performPageAuthorization(request);
    const tracked = operation.finally(() => {
      if (this.pageAuthorizationInFlight?.promise === tracked) {
        this.pageAuthorizationInFlight = undefined;
      }
    });
    this.pageAuthorizationInFlight = {
      key: authorizationKey,
      promise: tracked
    };
    return tracked;
  }

  private daemonCode(error: unknown): number | undefined {
    if (!(error instanceof SafariExtensionError)) {
      return undefined;
    }
    const details = error.details;
    if (isRecord(details) && typeof details.daemonCode === 'number' && Number.isSafeInteger(details.daemonCode)) {
      return details.daemonCode;
    }
    return this.daemonCode(details);
  }

  private isDetachedAuthorizationSession(error: unknown): boolean {
    if (!(error instanceof SafariExtensionError)) {
      return false;
    }
    return (
      error.code === 'safari_session_detached' ||
      error.code === 'safari_session_mismatch' ||
      (error.code === 'daemon_rejected' && this.daemonCode(error) === -32001)
    );
  }

  private async reattachAuthorizationSession(tab: BrowserTab): Promise<void> {
    const activePage = this.pageStateFromTab(tab);
    const permission = tab.url ? await this.permissionController.status(tab.url) : 'unsupported';
    const previousSessionId = this.bridge.sessionId;
    const attached = await this.bridge.hello(activePage, this.capabilities(permission));
    if (attached.protocolVersion !== 1) {
      throw new SafariExtensionError(
        'protocol_mismatch',
        `OpenBurnBar negotiated unsupported Safari protocol ${attached.protocolVersion}.`
      );
    }
    if (previousSessionId && previousSessionId !== attached.sessionId) {
      this.ownership.releaseSession(previousSessionId);
      this.locallyHaltedSession = undefined;
      this.nativeTrustedOrigins.clear();
      this.localWorkGeneration += 1;
    }
    this.ownership.claimUserHanded(tab, attached.sessionId);
    this.mutate((state) => {
      state.bridge.connection = 'connected';
    });
  }

  private async requestAuthorizationTrust(
    origin: string,
    tab: BrowserTab,
    decision: 'allow' | 'remove'
  ): Promise<Awaited<ReturnType<NativeBridge['popupAction']>>> {
    const updateTrust = () =>
      this.bridge.popupAction('trust.update', {
        origin,
        decision,
        trustMode: decision === 'allow' ? 'step' : 'manual'
      });
    let trustResponse: Awaited<ReturnType<typeof updateTrust>>;
    try {
      trustResponse = await updateTrust();
    } catch (error) {
      if (!this.isDetachedAuthorizationSession(error)) {
        throw error;
      }
      trustResponse = await this.withAttachmentLock(async () => {
        await this.reattachAuthorizationSession(tab);
        return updateTrust();
      });
    }
    return trustResponse;
  }

  private async updateAuthorizationTrust(origin: string, tab: BrowserTab): Promise<void> {
    const trustResponse = await this.requestAuthorizationTrust(origin, tab, 'allow');
    if (!trustResponse.accepted) {
      throw new SafariExtensionError(
        'trust_update_rejected',
        'Safari access was granted, but OpenBurnBar could not establish trusted access. Reconnect and try again.'
      );
    }
  }

  private async performPageAuthorization(
    request: Extract<PopupRequest, { type: 'popup.authorizePage' }>
  ): Promise<void> {
    const initialTab = await activeTab(this.browserAPI);
    const initialOrigin = originForURL(initialTab?.url);
    if (
      !initialTab?.url ||
      typeof initialTab.id !== 'number' ||
      initialTab.id !== request.expectedTabId ||
      initialOrigin !== request.expectedOrigin ||
      request.expectedStateVersion !== this.snapshot.stateVersion
    ) {
      throw new SafariExtensionError(
        'authorization_page_changed',
        'The Safari page changed while access was being prepared. Open OpenBurnBar again on the page you want to use.'
      );
    }

    if (!request.websiteAccessGranted) {
      throw new SafariExtensionError(
        'site_permission_denied',
        'Safari did not grant website access. Choose Allow in Safari, then try again.'
      );
    }
    const selectedAgent = this.snapshot.bridge.agents.find((agent) => agent.id === this.snapshot.selectedAgentId);
    const cloudDisclosureRequired =
      Boolean(selectedAgent?.cloud) && !this.preferences.cloudScreenshotDisclosureAcknowledged;
    if (cloudDisclosureRequired && !request.acknowledgeCloudScreenshots) {
      throw new SafariExtensionError(
        'cloud_disclosure_not_acknowledged',
        'Review the cloud screenshot disclosure and choose Allow & continue to acknowledge it.'
      );
    }
    const status = await this.permissionController.status(initialTab.url);
    if (status !== 'granted') {
      throw new SafariExtensionError(
        'authorization_verification_failed',
        'Safari reported website access, but OpenBurnBar could not verify it. Try again.'
      );
    }

    const currentTab = await activeTab(this.browserAPI);
    const currentOrigin = originForURL(currentTab?.url);
    if (
      !currentTab?.url ||
      currentTab.id !== initialTab.id ||
      currentOrigin !== initialOrigin ||
      currentTab.url !== initialTab.url
    ) {
      throw new SafariExtensionError(
        'authorization_page_changed',
        'The Safari page changed while its permission sheet was open. Return to the page and try again.'
      );
    }

    const previousPreferences = this.preferences;
    const existing = previousPreferences.sites[currentOrigin] ?? {
      allowed: false,
      sensitiveOverride: false
    };
    await this.updateAuthorizationTrust(currentOrigin, currentTab);
    this.nativeTrustedOrigins.add(currentOrigin);

    const nextPreferences: SafariPreferences = {
      ...previousPreferences,
      automaticallyTrustInvokedWebsites: true,
      cloudScreenshotDisclosureAcknowledged:
        previousPreferences.cloudScreenshotDisclosureAcknowledged ||
        (cloudDisclosureRequired && request.acknowledgeCloudScreenshots),
      sites: {
        ...previousPreferences.sites,
        [currentOrigin]: {
          ...existing,
          allowed: true
        }
      }
    };
    try {
      await this.store.save(nextPreferences);
    } catch (error) {
      let rollbackFailure: unknown;
      try {
        const rollback = await this.requestAuthorizationTrust(currentOrigin, currentTab, 'remove');
        if (!rollback.accepted) {
          rollbackFailure = new SafariExtensionError(
            'trust_rollback_rejected',
            'OpenBurnBar rejected the trusted-site rollback.'
          );
        }
      } catch (rollbackError) {
        rollbackFailure = rollbackError;
      }
      // Local projection must fail closed even when native rollback cannot be
      // confirmed. A later retry re-reads native authority before claiming
      // success; this origin is never treated as locally authorized.
      this.nativeTrustedOrigins.delete(currentOrigin);
      if (rollbackFailure) {
        const serializedRollback = serializeError(rollbackFailure, 'trust_rollback_failed');
        const rollbackDaemonCode = this.daemonCode(rollbackFailure);
        throw new SafariExtensionError(
          'authorization_partial_failure',
          'OpenBurnBar granted native trust but could not save it locally or confirm rollback. Keep OpenBurnBar open and retry permission setup.',
          {
            retryable: true,
            details: {
              rollback: serializedRollback,
              ...(rollbackDaemonCode === undefined ? {} : { daemonCode: rollbackDaemonCode })
            }
          }
        );
      }
      throw error;
    }
    this.preferences = nextPreferences;
    await this.refreshCurrentPage(false);
    if (
      this.snapshot.page?.permission !== 'granted' ||
      !this.snapshot.trust.siteAllowed ||
      (request.acknowledgeCloudScreenshots && !this.snapshot.trust.cloudScreenshotAcknowledged)
    ) {
      throw new SafariExtensionError(
        'authorization_verification_failed',
        'OpenBurnBar could not verify the completed Safari permission. Try again.'
      );
    }
  }

  private async setLearning(optedIn: boolean): Promise<void> {
    if (optedIn && !this.snapshot.learning.eligible) {
      throw new SafariExtensionError(
        'learning_requires_pro',
        'Continuous learning is available on Pro, Pro Max, and Ultra.'
      );
    }
    const response = await this.bridge.popupAction(
      optedIn ? 'learning.optIn' : 'learning.optOut',
      optedIn ? { consentVersion: 1 } : { deleteLearnedProfile: true }
    );
    if (!response.accepted) {
      throw new SafariExtensionError('learning_change_rejected', 'OpenBurnBar did not accept the learning change.');
    }
    this.preferences.learningOptedIn = optedIn;
    this.preferences.learningConsentSeen = true;
    await this.store.save(this.preferences);
    this.mutate((state) => {
      state.learning.optedIn = optedIn;
      state.learning.consentSeen = true;
      if (!optedIn) {
        state.learning.items = [];
      }
    });
  }

  private async teachCorrection(correction: string): Promise<void> {
    if (!this.snapshot.learning.eligible || !this.snapshot.learning.optedIn) {
      throw new SafariExtensionError(
        'learning_not_enabled',
        'Turn on Pro+ learning before teaching OpenBurnBar a correction.'
      );
    }
    const normalized = correction.trim();
    const correctionBytes = utf8ByteLength(normalized);
    if (correctionBytes < MIN_LEARNING_CORRECTION_BYTES || correctionBytes > MAX_LEARNING_CORRECTION_BYTES) {
      throw new SafariExtensionError(
        'invalid_learning_correction',
        'Corrections must be between 8 bytes and 4 KiB after trimming.'
      );
    }
    const tab = await activeTab(this.browserAPI);
    const page = this.snapshot.page;
    if (
      !this.bridge.sessionId ||
      !tab ||
      typeof tab.id !== 'number' ||
      !tab.url ||
      tab.active !== true ||
      !originForURL(tab.url) ||
      !page ||
      page.tabId !== tab.id ||
      page.url !== tab.url ||
      !page.isActive ||
      !page.isTopFrame ||
      page.permission !== 'granted' ||
      !this.snapshot.trust.siteAllowed
    ) {
      throw new SafariExtensionError(
        'learning_page_stale',
        'Refresh the popup on the page you want to teach, then submit the correction again.'
      );
    }

    this.mutate((state) => {
      state.busy = true;
    });
    const response = await this.popupAction('learning.propose', {
      correctionId: crypto.randomUUID(),
      correction: normalized,
      tabId: tab.id,
      url: tab.url
    });
    if (!response.accepted) {
      throw new SafariExtensionError(
        'learning_proposal_rejected',
        'OpenBurnBar did not accept this correction for review.'
      );
    }
    const proposal = normalizeLearningItem(isRecord(response.output) ? response.output.proposal : undefined);
    if (!proposal || proposal.status !== 'proposed') {
      throw new SafariExtensionError(
        'learning_proposal_invalid',
        'OpenBurnBar returned an invalid correction proposal.'
      );
    }
    this.mutate((state) => {
      state.learning.items = [proposal, ...state.learning.items.filter((item) => item.id !== proposal.id)];
      this.appendActivityTo(state, 'Correction staged for review. Nothing was activated automatically.', 'success');
    });
  }

  private async reviewLearning(itemId: string, decision: 'approve' | 'reject' | 'forget'): Promise<void> {
    const item = this.snapshot.learning.items.find((candidate) => candidate.id === itemId);
    if (!item) {
      throw new SafariExtensionError('learning_item_stale', 'That learning proposal is no longer available.');
    }
    const response = await this.bridge.popupAction(`learning.${decision}`, {
      proposalId: item.id,
      expectedVersion: item.version
    });
    if (!response.accepted) {
      throw new SafariExtensionError('learning_review_rejected', 'OpenBurnBar did not accept the learning decision.');
    }
    const updatedProposal = normalizeLearningItem(isRecord(response.output) ? response.output.proposal : undefined);
    this.mutate((state) => {
      if (decision === 'approve') {
        state.learning.items = state.learning.items.map((item) =>
          item.id === itemId ? (updatedProposal ?? { ...item, version: item.version + 1, status: 'accepted' }) : item
        );
      } else {
        state.learning.items = state.learning.items.filter((item) => item.id !== itemId);
      }
    });
  }

  private async refreshCurrentPage(extract: boolean): Promise<void> {
    const tab = await activeTab(this.browserAPI);
    if (!tab?.url || typeof tab.id !== 'number') {
      this.publishCurrentPage(undefined, 'unsupported');
      return;
    }
    if (this.bridge.sessionId) {
      this.ownership.claimUserHanded(tab, this.bridge.sessionId);
    }
    const permission = await this.permissionController.status(tab.url);
    const origin = originForURL(tab.url);
    let siteTrust = origin ? this.preferences.sites[origin] : undefined;
    if (
      origin &&
      permission === 'granted' &&
      this.preferences.automaticallyTrustInvokedWebsites &&
      !this.nativeTrustedOrigins.has(origin)
    ) {
      try {
        const response = await this.bridge.popupAction('trust.update', {
          origin,
          decision: 'allow',
          trustMode: 'step'
        });
        if (response.accepted) {
          this.nativeTrustedOrigins.add(origin);
          const nextPreferences: SafariPreferences = {
            ...this.preferences,
            sites: {
              ...this.preferences.sites,
              [origin]: {
                allowed: true,
                sensitiveOverride: siteTrust?.sensitiveOverride ?? false
              }
            }
          };
          await this.store.save(nextPreferences);
          this.preferences = nextPreferences;
          siteTrust = nextPreferences.sites[origin];
        } else {
          siteTrust = undefined;
        }
      } catch {
        siteTrust = undefined;
      }
    }
    const base = this.pageStateFromTab(tab);
    let sensitive = pageURLLooksSensitive(tab.url);
    if (extract && siteTrust?.allowed) {
      try {
        const context = await this.pageAdapter.pageContext(tab);
        sensitive = context.sensitive;
        Object.assign(base, context.pageState);
        this.recordEpoch(context.pageState);
      } catch {
        // Page metadata remains useful even before Safari grants script access.
      }
    }
    this.publishCurrentPage(tab, permission, siteTrust, base, sensitive);
  }

  private publishCurrentPage(
    tab: BrowserTab | undefined,
    permission: SitePermissionStatus,
    siteTrust?: SafariPreferences['sites'][string],
    pageState?: PageState,
    sensitive?: boolean
  ): void {
    if (!tab?.url || typeof tab.id !== 'number') {
      this.mutate((state) => {
        delete state.page;
        state.trust.siteAllowed = false;
        state.trust.sensitiveSiteOverride = false;
      });
      return;
    }
    const origin = originForURL(tab.url);
    const resolvedTrust = siteTrust ?? (origin ? this.preferences.sites[origin] : undefined);
    this.mutate((state) => {
      state.page = {
        ...(pageState ?? this.pageStateFromTab(tab)),
        sensitive: sensitive ?? pageURLLooksSensitive(tab.url ?? ''),
        permission
      };
      state.trust.siteAllowed = this.preferences.automaticallyTrustInvokedWebsites && (resolvedTrust?.allowed ?? false);
      state.trust.sensitiveSiteOverride = resolvedTrust?.sensitiveOverride ?? false;
      state.trust.onlyCurrentTab = this.preferences.onlyCurrentTab;
      state.trust.cloudScreenshotAcknowledged = this.preferences.cloudScreenshotDisclosureAcknowledged;
      state.trust.globalKillSwitch = state.bridge.killSwitchEnabled;
    });
  }

  private async refreshNativeProjection(): Promise<void> {
    if (this.localTurnActive) {
      return;
    }
    if (!this.nativeProjectionInFlight) {
      const projection = this.performNativeProjectionRefresh();
      const trackedProjection = projection.finally(() => {
        if (this.nativeProjectionInFlight === trackedProjection) {
          this.nativeProjectionInFlight = undefined;
        }
      });
      this.nativeProjectionInFlight = trackedProjection;
    }
    await this.nativeProjectionInFlight;
  }

  private async refreshPopupProjection(): Promise<void> {
    if (this.localTurnActive) {
      await this.refreshCurrentPage(false);
      return;
    }
    if (!this.nativeProjectionInFlight) {
      const projection = (async () => {
        await this.refreshCurrentPage(false);
        await this.performNativeProjectionRefresh();
      })();
      const trackedProjection = projection.finally(() => {
        if (this.nativeProjectionInFlight === trackedProjection) {
          this.nativeProjectionInFlight = undefined;
        }
      });
      this.nativeProjectionInFlight = trackedProjection;
    }
    await this.nativeProjectionInFlight;
  }

  private async performNativeProjectionRefresh(): Promise<void> {
    const startedAt = this.performanceRecorder.start();
    try {
      const activeRunId = this.snapshot.bridge.activeRunId;
      const response = await this.bridge.popupAction('ui.snapshot', activeRunId ? { runId: activeRunId } : {});
      const learningProjectionApplied = response.accepted && this.applyPopupActionOutput(response.output);
      this.performanceRecorder.recordElapsed(
        'learning_load',
        startedAt,
        learningProjectionApplied ? 'success' : 'error',
        {
          learningOperation: 'load'
        }
      );
    } catch (error) {
      this.performanceRecorder.recordElapsed('learning_load', startedAt, performanceOutcome(error), {
        learningOperation: 'load'
      });
      // Older native handlers may only expose bootstrap/catalog. Core bridge state remains valid.
    }
  }

  private applyPopupActionOutput(output: unknown): boolean {
    if (!isRecord(output)) {
      if (typeof output === 'string' && output.trim()) {
        this.appendTranscript('assistant', output.trim());
      }
      return false;
    }
    const hasEmbeddedBootstrap = Object.hasOwn(output, 'bootstrap');
    let embeddedBootstrap: ReturnType<typeof parseSafariBootstrapResponse> | undefined;
    let embeddedBootstrapError: ReturnType<typeof serializeError> | undefined;
    if (hasEmbeddedBootstrap) {
      try {
        embeddedBootstrap = parseSafariBootstrapResponse(output.bootstrap);
        this.gatewayClient.configure(embeddedBootstrap);
      } catch (error) {
        this.gatewayClient.clear();
        embeddedBootstrapError = serializeError(error, 'gateway_configuration_invalid');
      }
    }
    const catalogAgents = 'catalog' in output ? normalizeAgents(output) : undefined;
    const run = isRecord(output.run) ? output.run : undefined;
    const phase = run ? stringField(run, 'phase') : undefined;
    const terminalPhase = phase === 'completed' || phase === 'failed' || phase === 'cancelled' ? phase : undefined;
    const runErrorMessage = run ? stringField(run, 'errorMessage') : undefined;
    const terminalRunLabel =
      run && stringField(run, 'modelID')?.startsWith('cli:') ? 'installed agent hand-off' : 'run';
    const exactApprovals =
      isRecord(output.approvals) && Array.isArray(output.approvals.requests) ? output.approvals.requests : undefined;
    const exactLearning =
      isRecord(output.learning) && Array.isArray(output.learning.proposals) ? output.learning.proposals : undefined;
    const membershipSnapshot =
      isRecord(output.membership) && isRecord(output.membership.membership) ? output.membership.membership : undefined;
    const answer = stringField(output, 'answer') ?? stringField(output, 'text');
    const activeRunId =
      stringField(output, 'activeRunId') ??
      stringField(output, 'runId') ??
      (run ? (stringField(run, 'runID') ?? stringField(run, 'runId')) : undefined);
    const running = terminalPhase ? false : (booleanField(output, 'running') ?? (phase ? true : undefined));
    const killSwitchEnabled = booleanField(output, 'killSwitchEnabled');
    const gatewayReady = hasEmbeddedBootstrap ? undefined : booleanField(output, 'gatewayReady');
    const agents = 'agents' in output ? normalizeAgents(output.agents) : catalogAgents;
    const transcript = Array.isArray(output.transcript)
      ? output.transcript.map(normalizeTranscriptEntry).filter((entry): entry is TranscriptEntry => Boolean(entry))
      : undefined;
    const approvalsSource = Array.isArray(output.approvals) ? output.approvals : exactApprovals;
    const approvals = approvalsSource
      ? approvalsSource.map(normalizeApproval).filter((approval): approval is ApprovalPreview => Boolean(approval))
      : undefined;
    const activity = Array.isArray(output.activity)
      ? output.activity.map(normalizeActivity).filter((event): event is ActivityEvent => Boolean(event))
      : undefined;
    const learningSource = Array.isArray(output.learningItems) ? output.learningItems : exactLearning;
    const learningItems = learningSource
      ? learningSource.map(normalizeLearningItem).filter((item): item is LearningItem => Boolean(item))
      : undefined;
    const locallyHalted = this.isSessionLocallyHalted(this.bridge.sessionId);
    this.mutate((state) => {
      if (hasEmbeddedBootstrap) {
        state.bridge.gatewayReady = this.gatewayClient.isConfigured;
      }
      if (embeddedBootstrap) {
        const membership = normalizeMembership(embeddedBootstrap.tier);
        state.bridge.daemonVersion = embeddedBootstrap.daemonVersion;
        state.learning.eligible = embeddedBootstrap.learningAvailable && membership !== 'free';
        state.learning.optedIn = state.learning.eligible && embeddedBootstrap.learningOptedIn;
        state.bridge.membership = membership;
      }
      if (embeddedBootstrapError) {
        state.lastError = embeddedBootstrapError;
        this.appendActivityTo(
          state,
          'The local Ask gateway was rejected because its refreshed loopback connection details were unsafe or incomplete.',
          'error'
        );
      }
      const exactMembershipTier = membershipSnapshot ? stringField(membershipSnapshot, 'tier') : undefined;
      if (exactMembershipTier) {
        state.bridge.membership = normalizeMembership(exactMembershipTier);
      }
      if (answer) {
        this.appendTranscriptTo(state, 'assistant', answer);
      }
      if (activeRunId) {
        state.bridge.activeRunId = activeRunId;
      }
      if (running !== undefined) {
        state.running = locallyHalted ? false : running;
      }
      if (killSwitchEnabled !== undefined) {
        state.bridge.killSwitchEnabled = killSwitchEnabled;
        state.trust.globalKillSwitch = killSwitchEnabled;
      }
      if (gatewayReady !== undefined) {
        state.bridge.gatewayReady = gatewayReady;
      }
      if (agents && agents.length > 0) {
        state.bridge.agents = agents;
      }
      if (transcript && transcript.length > 0) {
        state.transcript = transcript.slice(-MAX_TRANSCRIPT_ENTRIES);
      }
      if (terminalPhase) {
        state.approvals = [];
      } else if (approvals) {
        state.approvals = locallyHalted ? [] : approvals.slice(-MAX_APPROVALS);
      }
      if (activity) {
        state.activity = activity.slice(-MAX_ACTIVITY_ENTRIES);
      }
      if (terminalPhase && activeRunId) {
        const terminalActivityId = `run-terminal:${activeRunId}:${terminalPhase}`;
        if (!state.activity.some((event) => event.id === terminalActivityId)) {
          const failedDetail = terminalPhase === 'failed' && runErrorMessage ? ` ${runErrorMessage}` : '';
          state.activity.push({
            id: terminalActivityId,
            runId: activeRunId,
            text:
              terminalPhase === 'completed'
                ? `The ${terminalRunLabel} completed.`
                : terminalPhase === 'cancelled'
                  ? `The ${terminalRunLabel} was cancelled.`
                  : `The ${terminalRunLabel} failed.${failedDetail}`,
            tone: terminalPhase === 'completed' ? 'success' : terminalPhase === 'cancelled' ? 'warning' : 'error',
            createdAt: nowISO()
          });
          state.activity = state.activity.slice(-MAX_ACTIVITY_ENTRIES);
        }
      }
      if (learningItems) {
        state.learning.items = learningItems;
      }
    });
    return learningItems !== undefined;
  }

  private async knownTabs(): Promise<SafariTabSnapshot[]> {
    const sessionId = this.bridge.sessionId;
    if (!sessionId) {
      return [];
    }
    const snapshots = await Promise.all(
      this.ownership
        .list()
        .filter((entry) => entry.sessionId === sessionId)
        .map(async (entry): Promise<SafariTabSnapshot | undefined> => {
          try {
            return this.tabSnapshot(await this.browserAPI.tabs.get(entry.tabId));
          } catch {
            this.ownership.release(entry.tabId);
            this.navigationEpochs.delete(entry.tabId);
            return undefined;
          }
        })
    );
    return snapshots.filter((snapshot): snapshot is SafariTabSnapshot => snapshot !== undefined);
  }

  private tabSnapshot(tab: BrowserTab): SafariTabSnapshot {
    const id = typeof tab.id === 'number' ? tab.id : 0;
    return {
      tabId: id,
      ...(typeof tab.windowId === 'number' ? { windowId: tab.windowId } : {}),
      url: tab.url || 'about:blank',
      title: pageTitleForTab(tab),
      isActive: tab.active === true,
      isOwned: this.ownership.isOwned(id, this.bridge.sessionId),
      navigationEpoch: this.navigationEpochs.get(id) ?? 0
    };
  }

  private async activeNativePage(): Promise<PageState | undefined> {
    const tab = await activeTab(this.browserAPI);
    return tab &&
      typeof tab.id === 'number' &&
      this.isSessionLocallyHalted(this.bridge.sessionId) === false &&
      this.ownership.isOwned(tab.id, this.bridge.sessionId)
      ? this.pageStateFromTab(tab)
      : undefined;
  }

  private pageStateFromTab(tab: BrowserTab): PageState {
    const id = typeof tab.id === 'number' ? tab.id : 0;
    return {
      tabId: id,
      ...(typeof tab.windowId === 'number' ? { windowId: tab.windowId } : {}),
      url: tab.url || 'about:blank',
      title: pageTitleForTab(tab),
      navigationEpoch: this.navigationEpochs.get(id) ?? 0,
      isActive: tab.active === true,
      isTopFrame: true,
      capturedAt: nowISO()
    };
  }

  private fallbackPageState(tabIdValue?: number): PageState {
    return {
      tabId: tabIdValue ?? 0,
      url: 'about:blank',
      title: 'No active Safari page',
      navigationEpoch: tabIdValue === undefined ? 0 : (this.navigationEpochs.get(tabIdValue) ?? 0),
      isActive: false,
      isTopFrame: true,
      capturedAt: nowISO()
    };
  }

  private recordEpoch(pageState: PageState): void {
    this.navigationEpochs.set(pageState.tabId, pageState.navigationEpoch);
  }

  private appendTranscript(role: TranscriptEntry['role'], text: string): void {
    this.mutate((state) => this.appendTranscriptTo(state, role, text));
  }

  private appendTranscriptTo(state: PopupSnapshot, role: TranscriptEntry['role'], text: string): void {
    state.transcript.push({
      id: crypto.randomUUID(),
      role,
      text,
      createdAt: nowISO()
    });
    state.transcript = state.transcript.slice(-MAX_TRANSCRIPT_ENTRIES);
  }

  private appendActivity(text: string, tone: ActivityEvent['tone']): void {
    this.mutate((state) => this.appendActivityTo(state, text, tone));
  }

  private appendActivityTo(state: PopupSnapshot, text: string, tone: ActivityEvent['tone']): void {
    state.activity.push({
      id: crypto.randomUUID(),
      text,
      tone,
      createdAt: nowISO()
    });
    state.activity = state.activity.slice(-MAX_ACTIVITY_ENTRIES);
  }

  private clearError(errorAtStart: PopupSnapshot['lastError']): void {
    this.mutate((state) => {
      if (state.bridge.connection !== 'disconnected' && state.lastError === errorAtStart) {
        delete state.lastError;
      }
      state.busy = false;
    });
  }

  private async measurePerformance<TResult>(
    metric: SafariPerformanceMetricName,
    context: SafariPerformanceContext | undefined,
    operation: () => Promise<TResult>
  ): Promise<TResult> {
    const startedAt = this.performanceRecorder.start();
    try {
      const result = await operation();
      this.performanceRecorder.recordElapsed(metric, startedAt, 'success', context);
      return result;
    } catch (error) {
      this.performanceRecorder.recordElapsed(metric, startedAt, performanceOutcome(error), context);
      throw error;
    }
  }

  private mutate(update: (state: PopupSnapshot) => void): void {
    update(this.snapshot);
    this.snapshot.stateVersion += 1;
    void this.pushSnapshot();
  }

  private async pushSnapshot(): Promise<void> {
    const message: BackgroundPush = {
      type: 'background.snapshot',
      snapshot: this.copySnapshot()
    };
    await this.browserAPI.runtime.sendMessage(message).catch(() => {
      // No popup is open. State remains available for the next bootstrap.
    });
  }

  private copySnapshot(): PopupSnapshot {
    this.snapshot.performance = this.performanceRecorder.snapshot();
    return structuredClone(this.snapshot);
  }
}

function normalizeMembership(value: string): NonNullable<BridgeRuntimeState['membership']> {
  const normalized = value.toLowerCase().replaceAll('-', '_');
  if (normalized.includes('ultra')) {
    return 'ultra';
  }
  if (normalized.includes('pro_max') || normalized.includes('promax')) {
    return 'pro_max';
  }
  if (normalized.includes('pro')) {
    return 'pro';
  }
  return 'free';
}

function normalizeAgents(value: unknown): BridgeAgentOption[] {
  const result: BridgeAgentOption[] = [];
  const append = (candidate: unknown, defaults: Partial<BridgeAgentOption> = {}): void => {
    if (!isRecord(candidate)) {
      return;
    }
    const id =
      stringField(candidate, 'id') ?? stringField(candidate, 'modelId') ?? stringField(candidate, 'identifier');
    if (!id) {
      return;
    }
    const kindValue = stringField(candidate, 'kind') ?? defaults.kind ?? 'model';
    const kind: BridgeAgentOption['kind'] = kindValue === 'cli' ? 'cli' : 'model';
    if (kind === 'cli' && SAFARI_HANDOFF_BLOCKED_AGENT_IDS.has(id)) {
      return;
    }
    const providerName =
      stringField(candidate, 'providerName') ??
      stringField(candidate, 'provider') ??
      defaults.providerName ??
      (kind === 'cli' ? 'Local agent' : 'OpenBurnBar');
    const lowerProvider = providerName.toLowerCase();
    result.push({
      id,
      displayName:
        stringField(candidate, 'displayName') ?? stringField(candidate, 'name') ?? defaults.displayName ?? id,
      providerName,
      kind,
      installed: booleanField(candidate, 'installed') ?? defaults.installed ?? kind === 'model',
      cloud:
        booleanField(candidate, 'cloud') ??
        defaults.cloud ??
        !/(?:local|ollama|mlx|lm studio|on-device)/u.test(lowerProvider),
      supportsVision:
        booleanField(candidate, 'supportsVision') ??
        booleanField(candidate, 'vision') ??
        defaults.supportsVision ??
        kind === 'model'
    });
  };

  const catalogEnvelope = isRecord(value) && isRecord(value.catalog) ? value.catalog : value;
  const catalogValue =
    isRecord(catalogEnvelope) && isRecord(catalogEnvelope.catalog) ? catalogEnvelope.catalog : catalogEnvelope;
  const source =
    isRecord(catalogValue) && Array.isArray(catalogValue.agents)
      ? catalogValue.agents
      : Array.isArray(catalogValue)
        ? catalogValue
        : [];
  const isSnapshotCatalog = isRecord(value) && 'catalog' in value;
  for (const candidate of source) {
    if (isSnapshotCatalog && isRecord(candidate) && stringField(candidate, 'kind') === 'cli') {
      continue;
    }
    append(candidate);
  }
  if (isRecord(catalogValue) && Array.isArray(catalogValue.providers)) {
    for (const provider of catalogValue.providers) {
      if (!isRecord(provider) || !Array.isArray(provider.models)) {
        continue;
      }
      const providerName = stringField(provider, 'displayName') ?? stringField(provider, 'name') ?? 'OpenBurnBar';
      for (const model of provider.models) {
        append(model, { providerName, kind: 'model', installed: true });
      }
    }
  }
  if (isRecord(value) && Array.isArray(value.installedAgents)) {
    for (const agent of value.installedAgents) {
      if (!isRecord(agent)) {
        continue;
      }
      const id = stringField(agent, 'id') ?? stringField(agent, 'modelId') ?? stringField(agent, 'identifier');
      if (!id || SAFARI_HANDOFF_BLOCKED_AGENT_IDS.has(id)) {
        continue;
      }
      append(agent, { kind: 'cli', installed: true, cloud: false, supportsVision: false });
    }
  }
  return sortUniqueAgents(result);
}

function sortUniqueAgents(agents: BridgeAgentOption[]): BridgeAgentOption[] {
  return [...new Map(agents.map((agent) => [agent.id, agent])).values()].sort((left, right) =>
    `${left.kind}:${left.providerName}:${left.displayName}`.localeCompare(
      `${right.kind}:${right.providerName}:${right.displayName}`
    )
  );
}

function contentAction(action: SafariActionKind, argumentsValue: Record<string, unknown>): ContentAction {
  switch (action) {
    case 'click': {
      const button = stringField(argumentsValue, 'button');
      const clickCount = numberField(argumentsValue, 'clickCount');
      return {
        kind: 'click',
        target: targetFromArguments(argumentsValue),
        ...(button === 'left' || button === 'middle' || button === 'right' ? { button } : {}),
        ...(clickCount === 1 || clickCount === 2 ? { clickCount } : {})
      };
    }
    case 'type': {
      const target = hasTargetArguments(argumentsValue) ? targetFromArguments(argumentsValue) : undefined;
      return {
        kind: 'type',
        ...(target ? { target } : {}),
        text: stringField(argumentsValue, 'text') ?? '',
        clear: booleanField(argumentsValue, 'clear') ?? true,
        submit: booleanField(argumentsValue, 'submit') ?? false,
        allowSensitive: booleanField(argumentsValue, 'allowSensitive') ?? false
      };
    }
    case 'press_key': {
      const modifiers = Array.isArray(argumentsValue.modifiers)
        ? argumentsValue.modifiers.filter(
            (modifier): modifier is 'Alt' | 'Control' | 'Meta' | 'Shift' =>
              modifier === 'Alt' || modifier === 'Control' || modifier === 'Meta' || modifier === 'Shift'
          )
        : [];
      return {
        kind: 'press_key',
        key: stringField(argumentsValue, 'key') ?? '',
        ...(hasTargetArguments(argumentsValue) ? { target: targetFromArguments(argumentsValue) } : {}),
        ...(modifiers.length > 0 ? { modifiers } : {})
      };
    }
    case 'scroll':
      return {
        kind: 'scroll',
        deltaX: numberField(argumentsValue, 'deltaX') ?? 0,
        deltaY: numberField(argumentsValue, 'deltaY') ?? 0,
        ...(hasTargetArguments(argumentsValue) ? { target: targetFromArguments(argumentsValue) } : {}),
        behavior: stringField(argumentsValue, 'behavior') === 'smooth' ? 'smooth' : 'auto'
      };
    case 'hover':
      return { kind: 'hover', target: targetFromArguments(argumentsValue) };
    case 'focus':
      return { kind: 'focus', target: targetFromArguments(argumentsValue) };
    case 'select_option': {
      const values = Array.isArray(argumentsValue.values)
        ? argumentsValue.values.filter((value): value is string => typeof value === 'string')
        : [];
      const value = stringField(argumentsValue, 'value');
      return {
        kind: 'select_option',
        target: targetFromArguments(argumentsValue),
        values: values.length > 0 ? values : value === undefined ? [] : [value]
      };
    }
    case 'wait_for': {
      const state = stringField(argumentsValue, 'state');
      const selector = stringField(argumentsValue, 'selector');
      const text = stringField(argumentsValue, 'text');
      const timeoutMs = numberField(argumentsValue, 'timeoutMs');
      return {
        kind: 'wait_for',
        ...(selector === undefined ? {} : { selector }),
        ...(text === undefined ? {} : { text }),
        ...(state === 'attached' || state === 'detached' || state === 'visible' || state === 'hidden' ? { state } : {}),
        ...(timeoutMs === undefined ? {} : { timeoutMs })
      };
    }
    case 'run_javascript': {
      const world = stringField(argumentsValue, 'world');
      const timeoutMs = numberField(argumentsValue, 'timeoutMs');
      return {
        kind: 'run_javascript',
        source: stringField(argumentsValue, 'script') ?? stringField(argumentsValue, 'source') ?? '',
        approved: booleanField(argumentsValue, 'approved') ?? false,
        ...(world === 'page' || world === 'isolated' ? { world } : {}),
        ...(timeoutMs === undefined ? {} : { timeoutMs })
      };
    }
    case 'extract': {
      const limit = numberField(argumentsValue, 'limit');
      return {
        kind: 'extract',
        selector: stringField(argumentsValue, 'selector') ?? 'body',
        ...(Array.isArray(argumentsValue.attributes)
          ? {
              attributes: argumentsValue.attributes.filter(
                (attribute): attribute is string => typeof attribute === 'string'
              )
            }
          : {}),
        ...(limit === undefined ? {} : { limit })
      };
    }
    default:
      throw new SafariExtensionError('unsupported_content_action', `Action "${action}" is not a content action.`);
  }
}

function normalizeTranscriptEntry(value: unknown): TranscriptEntry | undefined {
  if (!isRecord(value)) {
    return undefined;
  }
  const text = stringField(value, 'text');
  const role = stringField(value, 'role');
  if (!text || (role !== 'user' && role !== 'assistant' && role !== 'system' && role !== 'activity')) {
    return undefined;
  }
  const streaming = booleanField(value, 'streaming');
  const error = booleanField(value, 'error');
  return {
    id: stringField(value, 'id') ?? crypto.randomUUID(),
    role,
    text,
    createdAt: stringField(value, 'createdAt') ?? nowISO(),
    ...(streaming === undefined ? {} : { streaming }),
    ...(error === undefined ? {} : { error })
  };
}

function normalizeApproval(value: unknown): ApprovalPreview | undefined {
  if (!isRecord(value)) {
    return undefined;
  }
  const id = stringField(value, 'id') ?? stringField(value, 'approvalId');
  const summary = stringField(value, 'summary') ?? stringField(value, 'actionSummary') ?? stringField(value, 'message');
  if (!id || !summary) {
    return undefined;
  }
  const riskValue = stringField(value, 'risk');
  const risk: ApprovalPreview['risk'] =
    riskValue === 'read' || riskValue === 'sensitive' || riskValue === 'destructive' ? riskValue : 'write';
  return {
    id,
    runId: stringField(value, 'runId') ?? '',
    title: stringField(value, 'title') ?? 'Safari action',
    summary,
    url: stringField(value, 'url') ?? '',
    risk,
    requestedAt: stringField(value, 'requestedAt') ?? nowISO()
  };
}

function normalizeActivity(value: unknown): ActivityEvent | undefined {
  if (!isRecord(value)) {
    return undefined;
  }
  const text = stringField(value, 'text');
  if (!text) {
    return undefined;
  }
  const toneValue = stringField(value, 'tone');
  const tone: ActivityEvent['tone'] =
    toneValue === 'active' || toneValue === 'success' || toneValue === 'warning' || toneValue === 'error'
      ? toneValue
      : 'muted';
  const runId = stringField(value, 'runId');
  return {
    id: stringField(value, 'id') ?? crypto.randomUUID(),
    text,
    tone,
    createdAt: stringField(value, 'createdAt') ?? nowISO(),
    ...(runId === undefined ? {} : { runId })
  };
}

function normalizeLearningItem(value: unknown): LearningItem | undefined {
  if (!isRecord(value)) {
    return undefined;
  }
  const id = stringField(value, 'id') ?? stringField(value, 'proposalId');
  const title = stringField(value, 'title');
  if (!id || !title) {
    return undefined;
  }
  const versionValue = numberField(value, 'version');
  const kindValue = stringField(value, 'kind');
  const statusValue = stringField(value, 'status') ?? stringField(value, 'reviewStatus');
  return {
    id,
    version: versionValue !== undefined && Number.isSafeInteger(versionValue) && versionValue > 0 ? versionValue : 1,
    title,
    kind:
      kindValue === 'skill' ? 'skill' : kindValue === 'site-rule' || kindValue === 'site_rule' ? 'site-rule' : 'memory',
    status:
      statusValue === 'accepted' || statusValue === 'approved'
        ? 'accepted'
        : statusValue === 'stale'
          ? 'stale'
          : statusValue === 'archived' || statusValue === 'rejected'
            ? 'archived'
            : 'proposed',
    summary: stringField(value, 'summary') ?? stringField(value, 'content') ?? stringField(value, 'reason') ?? '',
    createdAt: stringField(value, 'createdAt') ?? nowISO()
  };
}

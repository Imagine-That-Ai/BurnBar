/**
 * Live VS Code binding for the extension's opt-in analytics. This is the single
 * object the rest of the extension talks to — it owns the consent prompt, the
 * triple gate (opt-in setting AND VS Code telemetry AND a key), and the typed
 * instrumentation surface. It NEVER touches the Amplitude SDK directly; every
 * call routes through the recorder (`./index` → `./recorder`), which routes
 * through the transport seam. Pre-consent darkness is guaranteed by the
 * recorder's gate, not by anything here.
 *
 * Gate (all three required for any event):
 *   1. `openburnbar.analytics.enabled` — the extension's own global opt-in
 *      setting (default false). Surfaced as the consent grant. Workspace/folder
 *      settings are ignored for consent so a repository cannot opt a user in.
 *   2. `vscode.env.isTelemetryEnabled` — VS Code's global telemetry switch.
 *   3. A non-empty injected/env API key.
 *
 * Identity is anonymous: a random per-install UUID in `globalState` (NOT a
 * machine id). No `user_id` is ever set — the extension has no sign-in.
 */
import { randomUUID } from 'node:crypto';

import * as vscode from 'vscode';

import { logger } from '../logger';
import { CONSENT_STORAGE_KEY } from './consent';
import {
  createAnalytics,
  bootAnalytics,
  grantAnalyticsConsent,
  declineAnalyticsConsent,
  revokeAnalyticsConsent,
  telemetrySignalDidChange,
  EVENT,
  SURFACE,
  type AnalyticsGraph,
  type CommandId,
  type Surface,
  type Outcome,
  type RunActionName,
  type PanelActionName,
  type ErrorCategory,
  type ScreenViewContext
} from './index';

const DEVICE_ID_KEY = 'openburnbar.analytics.deviceId';
const PROMPT_SETTING = 'openburnbar.analytics.enabled';
const PROMPT_SEEN_KEY = 'openburnbar.analytics.promptSeen';
export const INSTALL_MARKER_KEY = 'openburnbar.analytics.hasActivatedBefore';

const CONSENT_PROMPT_MESSAGE =
  'Help improve OpenBurnBar with privacy-preserving, opt-in analytics (Amplitude)? ' +
  'No personal data, prompts, code, file paths, or message content — only feature usage, ' +
  'outcomes, and bucketed counts. Requires VS Code telemetry to be enabled. You can change ' +
  'this anytime in Settings (OpenBurnBar: Analytics Enabled).';
const ENABLE_LABEL = 'Enable analytics';
const DECLINE_LABEL = 'Not now';

/** The minimal host context the service needs — `ExtensionContext` satisfies it. */
export interface AnalyticsServiceHostContext {
  globalState: Pick<vscode.Memento, 'get' | 'update'>;
  subscriptions: Array<{ dispose(): void }>;
  extension: { packageJSON: { version?: string } };
}

/** Adapter so VS Code's `env.isTelemetryEnabled` becomes a `ConsentSignal`. */
class TelemetrySignal {
  get isEnabled(): boolean {
    // Default to true if the host doesn't expose the flag (older API): consent +
    // key still gate, and the user explicitly opted in via the setting.
    return vscode.env.isTelemetryEnabled ?? true;
  }
}

export class OpenBurnBarAnalyticsService {
  private readonly graph: AnalyticsGraph;
  private readonly hostKind: string;
  private readonly isFirstActivation: boolean;

  private constructor(graph: AnalyticsGraph, hostKind: string, isFirstActivation: boolean) {
    this.graph = graph;
    this.hostKind = hostKind;
    this.isFirstActivation = isFirstActivation;
  }

  /**
   * Build the service, sync the opt-in setting into consent, wire the live
   * telemetry + setting listeners, and resume a consented session. Returns a
   * service whose `track*` methods are all no-ops until the user opts in.
   */
  static initialize(context: AnalyticsServiceHostContext): OpenBurnBarAnalyticsService {
    // Resolve first-activation BEFORE minting a device id. `resolveDeviceId`
    // writes a UUID when the key is absent; that write must not look like
    // prior-install evidence for this process.
    const isFirstActivation = resolveFirstActivation(context);
    const deviceId = OpenBurnBarAnalyticsService.resolveDeviceId(context);
    const appVersion = context.extension.packageJSON.version ?? '0.0.0';
    const hostKind = vscode.env.appName ?? 'vscode';

    const graph = createAnalytics({
      storage: {
        get: (key) => context.globalState.get<string>(key),
        update: (key, value) => context.globalState.update(key, value)
      },
      deviceId,
      appVersion,
      telemetrySignal: new TelemetrySignal()
    });

    const service = new OpenBurnBarAnalyticsService(graph, hostKind, isFirstActivation);

    // Reconcile the persisted opt-in SETTING with the consent store. The setting
    // is the user-facing source of truth; consent mirrors it. This also handles
    // the user toggling the setting in the Settings UI between sessions.
    service.syncSettingToConsent(context);

    // React to the user flipping the opt-in setting at runtime.
    if (typeof vscode.workspace.onDidChangeConfiguration === 'function') {
      context.subscriptions.push(
        vscode.workspace.onDidChangeConfiguration((event) => {
          if (event.affectsConfiguration(PROMPT_SETTING)) {
            service.syncSettingToConsent(context);
          }
        })
      );
    }

    // React to VS Code's global telemetry switch flipping — go dark immediately
    // or resume, without re-announcing grant.
    if (typeof vscode.env.onDidChangeTelemetryEnabled === 'function') {
      context.subscriptions.push(
        vscode.env.onDidChangeTelemetryEnabled(() => {
          telemetrySignalDidChange(graph, {
            isFirstActivation,
            hostKind,
            surface: SURFACE.app
          });
        })
      );
    }

    // Resume a previously-consented session (no grant re-emit) + emit the spine.
    bootAnalytics(graph, {
      isFirstActivation,
      hostKind,
      surface: SURFACE.app
    });

    void context.globalState.update(INSTALL_MARKER_KEY, true);
    return service;
  }

  /** Show the first-run opt-in prompt at most once. Records the choice in the
   *  opt-in SETTING (which drives consent). No-op once the user has been asked. */
  async maybePromptForConsent(context: AnalyticsServiceHostContext): Promise<void> {
    if (context.globalState.get<boolean>(PROMPT_SEEN_KEY) === true) return;
    if (this.graph.consent.hasDecided) {
      await context.globalState.update(PROMPT_SEEN_KEY, true);
      return;
    }
    await context.globalState.update(PROMPT_SEEN_KEY, true);

    const choice = await vscode.window.showInformationMessage(CONSENT_PROMPT_MESSAGE, ENABLE_LABEL, DECLINE_LABEL);

    if (choice === ENABLE_LABEL) {
      // Persist the user-facing setting; the config listener mirrors it into
      // consent and announces the grant.
      try {
        await vscode.workspace.getConfiguration().update(PROMPT_SETTING, true, vscode.ConfigurationTarget.Global);
      } catch {
        // If the setting can't be written, fall back to direct consent so the
        // user's explicit choice still takes effect this session.
        grantAnalyticsConsent(this.graph, {
          isFirstActivation: this.isFirstActivation,
          hostKind: this.hostKind
        });
      }
      this.syncSettingToConsent(context);
    } else {
      declineAnalyticsConsent(this.graph);
    }
  }

  // ── Instrumentation surface — every call is dark until opt-in ───────────────

  /** A registered command fired. `id` is a bounded enum value; never args. */
  trackCommand(id: CommandId): void {
    this.graph.analytics.track(EVENT.vscodeCommandInvoked, { command_id: id });
  }

  /** A bounded panel/webview action (e.g. switch section, open app). */
  trackPanelAction(action: PanelActionName, surface: Surface = SURFACE.panel): void {
    this.graph.analytics.track(EVENT.vscodePanelAction, { action, surface });
  }

  /** A daemon run action with a bounded outcome. `action` is a closed union, so
   *  a run id / prompt / diff cannot be passed here even by mistake. */
  trackRunAction(action: RunActionName, outcome: Outcome): void {
    this.graph.analytics.track(EVENT.vscodeRunAction, { action, outcome });
  }

  /** A panel/surface became visible. `surface` is a bounded enum; `context` is a
   *  CLOSED interface of optional bounded flags (no index signature), so a caller
   *  can never pass an arbitrary string onto `screen.viewed` the way an open
   *  props record would have allowed. */
  trackScreenView(surface: Surface, context: ScreenViewContext = {}): void {
    this.graph.analytics.track(EVENT.screenViewed, { surface, ...context });
  }

  /** The local daemon connection state changed. */
  trackDaemonConnection(outcome: Outcome): void {
    this.graph.analytics.track(EVENT.vscodeDaemonConnection, { outcome });
  }

  /** A handled error. `category`/`surface` are bounded closed unions; the caught
   *  error's message, stack, file path, or any value can NEVER reach the wire —
   *  passing one is a compile error. */
  trackHandledError(category: ErrorCategory, surface: Surface): void {
    this.graph.analytics.track(EVENT.errorHandled, { error_category: category, surface });
  }

  /** Public revoke for a "manage analytics" affordance. Goes dark immediately. */
  revoke(): void {
    revokeAnalyticsConsent(this.graph);
  }

  // ── Internals ───────────────────────────────────────────────────────────────

  /** Mirror the opt-in SETTING into the consent store and (de)activate. */
  private syncSettingToConsent(context: AnalyticsServiceHostContext): void {
    const enabled = readGlobalAnalyticsOptIn();

    if (enabled && !this.graph.consent.isGranted) {
      grantAnalyticsConsent(this.graph, {
        isFirstActivation: this.isFirstActivation,
        hostKind: this.hostKind
      });
    } else if (!enabled && this.graph.consent.isGranted) {
      revokeAnalyticsConsent(this.graph);
    }
    // Record that we've reconciled, so the prompt doesn't fight the setting.
    if (enabled) void context.globalState.update(PROMPT_SEEN_KEY, true);
  }

  /** A random per-install UUID persisted in globalState. NOT a machine id. */
  private static resolveDeviceId(context: AnalyticsServiceHostContext): string {
    const existing = context.globalState.get<string>(DEVICE_ID_KEY);
    if (existing && existing.length > 0) return existing;
    const next = randomUUID();
    void context.globalState.update(DEVICE_ID_KEY, next);
    logger.debug('analytics: minted a new anonymous device id');
    return next;
  }
}

function readGlobalAnalyticsOptIn(): boolean {
  if (typeof vscode.workspace.getConfiguration !== 'function') return false;
  const config = vscode.workspace.getConfiguration();
  const inspected = typeof config.inspect === 'function' ? config.inspect<boolean>(PROMPT_SETTING) : undefined;
  if (inspected) return inspected.globalValue === true;
  return false;
}

/**
 * First activation is a dedicated install marker, not "analytics prompt handled."
 * Any durable prior-install evidence means this is an upgrade (or a re-activation)
 * and must not emit `install.started`.
 */
export function resolveFirstActivation(context: AnalyticsServiceHostContext): boolean {
  if (context.globalState.get<boolean>(INSTALL_MARKER_KEY) === true) return false;
  if (context.globalState.get<boolean>(PROMPT_SEEN_KEY) === true) return false;
  const deviceId = context.globalState.get<string>(DEVICE_ID_KEY);
  if (typeof deviceId === 'string' && deviceId.length > 0) return false;
  const consent = context.globalState.get<string>(CONSENT_STORAGE_KEY);
  if (consent === 'granted' || consent === 'declined') return false;
  if (readGlobalAnalyticsOptIn()) return false;
  return true;
}

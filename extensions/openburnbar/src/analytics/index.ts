/**
 * Host-agnostic entry point for the VS Code extension's analytics. Wires the
 * consent store, the recorder, and the transport seam together — mirroring
 * website/src/lib/analytics/index.ts — but takes its host dependencies
 * (storage, telemetry signal, device id, versions) as parameters so the whole
 * graph is unit-testable with fakes. The live VS Code binding lives in
 * `./service.ts`.
 *
 * With no `__AMPLITUDE_API_KEY__` injected (and no env override) the resolved key
 * is `''`, so the recorder stays DARK: the transport's `start()` is never called
 * and the Amplitude SDK is never even imported.
 */
import { randomUUID } from 'node:crypto';

import { ConsentStore, type ConsentStorage } from './consent';
import { Analytics, type AnalyticsProps, type ConsentSignal, type AnalyticsTransport } from './recorder';
import { AmplitudeTransport } from './amplitudeTransport';
import { resolveAmplitudeApiKey, resolveServerZone, type AmplitudeServerZone } from './config';
import { EVENT, SURFACE, type Surface } from './events';

export { EVENT, SURFACE, COMMAND_ID, OUTCOME } from './events';
export type {
  CommandId,
  Outcome,
  Surface,
  RunActionName,
  PanelActionName,
  ErrorCategory,
  ScreenViewContext
} from './events';
export type { AnalyticsProps } from './recorder';
export type { ConsentState } from './consent';
// NOTE: `./buckets` is the canonical anti-fingerprinting helper (parity-tested
// in test/analytics/buckets.test.ts). These helpers are re-exported here as the
// platform's public bucketing API for future instrumentation that needs to send
// a bucketed numeric. No current extension event carries a raw numeric — every
// property is a bounded enum or boolean — so nothing imports them yet; that is
// intentional.
export {
  bucketAmountUSD,
  bucketCount,
  bucketDurationMs,
  bucketDurationSeconds,
  bucketPercent,
  bucketSizeBytes
} from './buckets';

export interface AnalyticsHost {
  /** Cross-session persistence for the tri-state consent (VS Code globalState). */
  storage: ConsentStorage;
  /** Random per-install anonymous device id (NOT a hardware id). */
  deviceId: string;
  /** Extension marketing version (package.json `version`). */
  appVersion: string;
  /** The VS Code telemetry switch, as an AND-gate: analytics is dark unless this
   *  is enabled (in addition to opt-in consent + a key). */
  telemetrySignal: ConsentSignal;
  /** App build / VS Code app name, optional context. */
  appBuild?: string;
  /** Override the transport (tests inject a fake). Defaults to the real SDK. */
  transport?: AnalyticsTransport;
  /** Override the resolved API key (tests). Defaults to config resolution. */
  apiKey?: string;
  /** Override the server zone (tests). Defaults to config resolution. */
  serverZone?: AmplitudeServerZone;
}

export interface AnalyticsGraph {
  consent: ConsentStore;
  analytics: Analytics;
  apiKey: string;
  /** Guards the session spine so `app.session.started` fires at most once per
   *  process, however many times boot/grant run (mirrors the website's
   *  sessionStorage dedupe). Mutable holder, internal. */
  _booted: { value: boolean };
}

/** Build the consent store + recorder + transport for a given host. */
export function createAnalytics(host: AnalyticsHost): AnalyticsGraph {
  const apiKey = host.apiKey ?? resolveAmplitudeApiKey();
  const serverZone = host.serverZone ?? resolveServerZone();
  const consent = new ConsentStore(host.storage);
  const transport = host.transport ?? new AmplitudeTransport(host.deviceId, serverZone);

  /** One RFC 4122 UUID per host activation. Mint only when an event actually
   *  sends so a dark activation never creates a session id. */
  let sessionId = '';
  const superProperties = (): AnalyticsProps => {
    if (!sessionId) sessionId = randomUUID();
    const props: AnalyticsProps = {
      product: 'burnbar',
      platform: 'vscode',
      app_version: host.appVersion,
      surface: SURFACE.app,
      session_id: sessionId
    };
    if (host.appBuild) props.app_build = host.appBuild;
    return props;
  };

  const analytics = new Analytics({
    consent,
    transport,
    apiKey,
    superProperties,
    extraSignals: [host.telemetrySignal]
  });

  return { consent, analytics, apiKey, _booted: { value: false } };
}

/**
 * Resume a consented session on activation: start (without re-announcing the
 * grant) and emit the lifecycle spine — `app.session.started` once per host
 * launch, the extension-activated marker, and the initial `screen.viewed`.
 * Safe to call repeatedly; dark until opt-in (every track drops pre-consent),
 * and the spine emits AT MOST ONCE per process (guarded by `graph._booted`), so
 * a pre-enabled setting that boots during sync + an explicit boot don't double
 * up.
 */
export function bootAnalytics(
  graph: AnalyticsGraph,
  ctx: { isFirstActivation: boolean; hostKind: string; surface?: Surface }
): void {
  graph.analytics.startIfConsented();
  if (!graph.consent.isGranted) return;
  if (!graph.analytics.canSend) return;
  if (graph._booted.value) return; // session spine already emitted this process
  graph._booted.value = true;
  graph.analytics.track(EVENT.appSessionStarted, {
    is_first_launch: ctx.isFirstActivation,
    cold_start: true
  });
  graph.analytics.track(EVENT.appOpened, {
    is_first_launch: ctx.isFirstActivation,
    cold_start: true,
    surface: 'extension'
  });
  if (ctx.isFirstActivation) {
    graph.analytics.track(EVENT.installStarted, { surface: 'extension' });
  }
  graph.analytics.track(EVENT.vscodeExtensionActivated, { host_kind: ctx.hostKind });
  graph.analytics.track(EVENT.screenViewed, {
    surface: ctx.surface ?? SURFACE.app,
    is_first_view: true
  });
}

/** Persist grant, open the gate, announce once, then boot the session. */
export function grantAnalyticsConsent(
  graph: AnalyticsGraph,
  ctx: { isFirstActivation: boolean; hostKind: string }
): void {
  graph.consent.grant();
  graph.analytics.consentDidChange();
  bootAnalytics(graph, ctx);
}

/** Persist decline. Stays dark; the prompt does not reappear. */
export function declineAnalyticsConsent(graph: AnalyticsGraph): void {
  graph.consent.decline();
  graph.analytics.consentDidChange();
}

/** Revoke (= decline). Stops the transport immediately; flushes nothing. */
export function revokeAnalyticsConsent(graph: AnalyticsGraph): void {
  graph.consent.revoke();
  graph.analytics.consentDidChange();
}

/** Re-evaluate gates after the VS Code telemetry switch flips (start or stop). */
export function telemetrySignalDidChange(
  graph: AnalyticsGraph,
  ctx: { isFirstActivation: boolean; hostKind: string; surface?: Surface }
): void {
  graph.analytics.consentDidChange();
  bootAnalytics(graph, ctx);
}

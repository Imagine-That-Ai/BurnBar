import type { ConsentStore } from './consent';
import { EVENT, eventCategory, type AnalyticsEventName } from './events';

/** Property values are strings or booleans ONLY — raw numbers must be bucketed
 *  first (see ./buckets), so an un-bucketed number is a compile error here. This
 *  is the TS analogue of Swift's `AnalyticsValue` (no numeric case). */
export type AnalyticsProps = Record<string, string | boolean>;

/**
 * The transport seam. The real implementation (./amplitudeTransport) dynamically
 * imports the Amplitude Node SDK on `start`; tests inject a fake. The recorder
 * never touches the SDK directly, so the consent gate cannot be bypassed.
 * Mirrors Swift's `AnalyticsTransporting` and the website's `AnalyticsTransport`.
 */
export interface AnalyticsTransport {
  readonly isStarted: boolean;
  start(apiKey: string): void;
  track(name: string, category: string, props: AnalyticsProps): void;
  stop(): void;
}

/** A signal source the recorder ANDs into its gate (e.g. VS Code's telemetry
 *  switch). The recorder re-reads `isEnabled` on every send, so flipping the host
 *  telemetry signal off goes dark immediately — no buffering, no catch-up. */
export interface ConsentSignal {
  readonly isEnabled: boolean;
}

interface AnalyticsOptions {
  consent: ConsentStore;
  transport: AnalyticsTransport;
  apiKey: string;
  /** Properties stamped onto every event (platform, app_version, …). */
  superProperties: () => AnalyticsProps;
  /** Extra AND-gates beyond consent+key — e.g. VS Code's `isTelemetryEnabled`.
   *  ALL must be enabled for any send. Absent/empty = no extra gating. */
  extraSignals?: ConsentSignal[];
}

/**
 * The one wrapper every instrumentation call goes through. Ported from
 * AgentLens/Services/Analytics/Analytics.swift and mirrored from
 * website/src/lib/analytics/recorder.ts. Drops every call unless consent is
 * granted AND an API key is present AND every extra signal is enabled, lazily
 * starting the transport on first use and stopping it on revoke.
 */
export class Analytics {
  private announcedGrant = false;

  constructor(private readonly opts: AnalyticsOptions) {}

  /** The single invariant: granted consent AND a non-empty key AND every extra
   *  signal (VS Code telemetry) enabled. No key, declined/unset, or host
   *  telemetry off → dark. Checked on EVERY call. */
  get canSend(): boolean {
    if (!this.opts.consent.isGranted) return false;
    if (this.opts.apiKey.length === 0) return false;
    for (const signal of this.opts.extraSignals ?? []) {
      if (!signal.isEnabled) return false;
    }
    return true;
  }

  private ensureStarted(): void {
    if (!this.opts.transport.isStarted) this.opts.transport.start(this.opts.apiKey);
  }

  track(event: AnalyticsEventName, props: AnalyticsProps = {}): void {
    if (!this.canSend) return; // the gate
    this.ensureStarted();
    this.opts.transport.track(event, eventCategory(event), {
      ...this.opts.superProperties(),
      ...props
    });
  }

  /** Call after the consent state OR an extra signal changes. Grant (all gates
   *  open) → start + announce once. Revoke / signal off → stop the transport and
   *  flush nothing. */
  consentDidChange(): void {
    if (this.canSend) {
      this.ensureStarted();
      if (!this.announcedGrant) {
        this.announcedGrant = true;
        this.track(EVENT.consentAnalyticsGranted, { consent_version: '1' });
      }
    } else {
      if (this.opts.transport.isStarted) this.opts.transport.stop();
      this.announcedGrant = false;
    }
  }

  /** Resume a previously-consented session on activation WITHOUT re-announcing
   *  the grant (that fires once, at the moment of opt-in). No-op when not
   *  sendable. */
  startIfConsented(): void {
    if (!this.canSend) return;
    this.ensureStarted();
    this.announcedGrant = true;
  }
}

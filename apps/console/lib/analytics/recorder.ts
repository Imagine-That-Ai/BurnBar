import { ConsentStore } from "./consent";
import { EVENT, eventCategory, type AnalyticsEventName } from "./events";

/** Property values are strings or booleans only — raw numbers must be bucketed
 *  first (see ./buckets), so an un-bucketed number is a compile error here. This
 *  mirrors the macOS `AnalyticsValue` (no numeric case) and the website union. */
export type AnalyticsProps = Record<string, string | boolean>;

/**
 * The transport seam. The real implementation (./amplitudeTransport) dynamically
 * imports the Amplitude SDK on `start`; tests inject a fake. The recorder never
 * touches the SDK directly, so the consent gate cannot be bypassed.
 */
export interface AnalyticsTransport {
  readonly isStarted: boolean;
  start(apiKey: string): void;
  track(name: string, category: string, props: AnalyticsProps): void;
  /** Identify the signed-in member (hashed uid only) or clear it (undefined). */
  setUserId(id: string | undefined): void;
  stop(): void;
}

export interface AnalyticsOptions {
  consent: ConsentStore;
  transport: AnalyticsTransport;
  apiKey: string;
  /** Properties stamped onto every event (platform, app_version, surface, …). */
  superProperties: () => AnalyticsProps;
}

/**
 * The one wrapper every console instrumentation call goes through. Ported from
 * website/src/lib/analytics/recorder.ts and
 * AgentLens/Services/Analytics/Analytics.swift. Drops every call unless consent
 * is granted AND an API key is present, lazily starting the transport on first
 * use and stopping it on revoke. No component talks to the SDK directly.
 */
export class Analytics {
  private announcedGrant = false;
  /** Held until consent is granted, then applied to the started transport. */
  private pendingUserId: string | undefined;

  constructor(private readonly opts: AnalyticsOptions) {}

  /** The single invariant: granted consent AND a non-empty key. No key → dark. */
  private get canSend(): boolean {
    return this.opts.consent.isGranted && this.opts.apiKey.length > 0;
  }

  private ensureStarted(): void {
    if (!this.opts.transport.isStarted) this.opts.transport.start(this.opts.apiKey);
  }

  track(event: AnalyticsEventName, props: AnalyticsProps = {}): void {
    if (!this.canSend) return;
    this.ensureStarted();
    this.opts.transport.track(event, eventCategory(event), {
      ...this.opts.superProperties(),
      ...props,
    });
  }

  /**
   * Identify the authenticated member. Stored even while dark so a later grant
   * can apply it; only forwarded to the SDK once consent is granted (never set a
   * user_id before opt-in). Pass a hashed uid — never a raw uid, email, or name.
   */
  setUserId(id: string | undefined): void {
    this.pendingUserId = id;
    if (!this.canSend) return;
    this.ensureStarted();
    this.opts.transport.setUserId(id);
  }

  /** Call after the consent state changes. Grant → start + announce once.
   *  Revoke → stop the transport and flush nothing. */
  consentDidChange(): void {
    if (this.canSend) {
      this.ensureStarted();
      if (this.pendingUserId !== undefined) this.opts.transport.setUserId(this.pendingUserId);
      if (!this.announcedGrant) {
        this.announcedGrant = true;
        this.track(EVENT.consentAnalyticsGranted, { consent_version: "1" });
      }
    } else {
      if (this.opts.transport.isStarted) this.opts.transport.stop();
      this.announcedGrant = false;
    }
  }

  /** Resume a previously-consented session on load WITHOUT re-announcing the
   *  grant (that fires once, at the moment of opt-in). */
  startIfConsented(): void {
    if (!this.canSend) return;
    this.ensureStarted();
    if (this.pendingUserId !== undefined) this.opts.transport.setUserId(this.pendingUserId);
    this.announcedGrant = true;
  }
}

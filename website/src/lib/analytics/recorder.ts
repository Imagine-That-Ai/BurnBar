import { ANALYTICS_CONSENT_VERSION, ConsentStore } from "./consent";
import { EVENT, eventCategory, type AnalyticsEventName } from "./events";

/** Property values are strings or booleans only — raw numbers must be bucketed
 *  first (see ./buckets), so an un-bucketed number is a compile error here. */
export type AnalyticsProps = Record<string, string | boolean>;

/**
 * The transport seam. Production uses the first-party collector
 * (`./collectorTransport`). Tests inject a fake. The recorder never talks to
 * Amplitude directly, so the consent gate cannot be bypassed and the browser
 * never holds an Amplitude API key.
 */
export interface AnalyticsTransport {
  readonly isStarted: boolean;
  start(collectorUrl: string): void;
  track(name: string, category: string, props: AnalyticsProps): void;
  stop(): void;
}

export interface AnalyticsOptions {
  consent: ConsentStore;
  transport: AnalyticsTransport;
  /**
   * First-party collector URL. Empty → the recorder stays dark even after
   * consent. This is never an Amplitude API key — the browser must not hold one.
   */
  collectorUrl: string;
  /** Properties stamped onto every event (platform, app_version, …). */
  superProperties: () => AnalyticsProps;
}

/**
 * The one wrapper every instrumentation call goes through. Ported from
 * AgentLens/Services/Analytics/Analytics.swift. Drops every call unless consent
 * is granted AND a collector URL is present, lazily starting the transport on first
 * use and stopping it on revoke.
 */
export class Analytics {
  private announcedGrant = false;

  constructor(private readonly opts: AnalyticsOptions) {}

  /** The single invariant: granted consent AND a collector URL. No URL → dark. */
  get canSend(): boolean {
    return this.opts.consent.isGranted && this.opts.collectorUrl.length > 0;
  }

  private ensureStarted(): void {
    if (!this.opts.transport.isStarted) this.opts.transport.start(this.opts.collectorUrl);
  }

  track(event: AnalyticsEventName, props: AnalyticsProps = {}): void {
    if (!this.canSend) return;
    this.ensureStarted();
    this.opts.transport.track(event, eventCategory(event), {
      ...this.opts.superProperties(),
      ...props
    });
  }

  /** Call after the consent state changes. Grant → start + announce once.
   *  Revoke → stop the transport and flush nothing. */
  consentDidChange(): void {
    if (this.canSend) {
      this.ensureStarted();
      if (!this.announcedGrant) {
        this.announcedGrant = true;
        this.track(EVENT.consentAnalyticsGranted, {
          consent_version: ANALYTICS_CONSENT_VERSION
        });
      }
    } else {
      if (this.opts.transport.isStarted) this.opts.transport.stop();
      this.announcedGrant = false;
    }
  }

  /** Resume a previously-consented session on page load WITHOUT re-announcing
   *  the grant (that fires once, at the moment of opt-in). */
  startIfConsented(): void {
    if (!this.canSend) return;
    this.ensureStarted();
    this.announcedGrant = true;
  }
}

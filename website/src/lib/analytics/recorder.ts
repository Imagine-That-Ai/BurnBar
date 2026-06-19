import { ConsentStore } from "./consent";
import { EVENT, eventCategory, type AnalyticsEventName } from "./events";

/** Property values are strings or booleans only — raw numbers must be bucketed
 *  first (see ./buckets), so an un-bucketed number is a compile error here. */
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
  stop(): void;
}

export interface AnalyticsOptions {
  consent: ConsentStore;
  transport: AnalyticsTransport;
  apiKey: string;
  /** Properties stamped onto every event (platform, app_version, …). */
  superProperties: () => AnalyticsProps;
}

/**
 * The one wrapper every instrumentation call goes through. Ported from
 * AgentLens/Services/Analytics/Analytics.swift. Drops every call unless consent
 * is granted AND an API key is present, lazily starting the transport on first
 * use and stopping it on revoke.
 */
export class Analytics {
  private announcedGrant = false;

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
        this.track(EVENT.consentAnalyticsGranted);
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

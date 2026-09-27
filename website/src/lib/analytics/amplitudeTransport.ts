import type { AnalyticsTransport, AnalyticsProps } from "./recorder";

type AmplitudeModule = typeof import("@amplitude/analytics-browser");

/**
 * Legacy Amplitude Browser SDK transport. The marketing site no longer uses
 * this path: `index.ts` posts to a first-party collector so the browser never
 * holds `AMPLITUDE_API_KEY`. Kept for reference / emergency fallback only.
 *
 * Production transport backed by the Amplitude Browser SDK, mirroring
 * AgentLens/Services/Analytics/AmplitudeTransport.swift. The SDK is **dynamically
 * imported on start()** — which the recorder calls only after consent — so a
 * pre-consent page ships zero Amplitude bytes and makes zero network calls.
 *
 * Hardened to macOS parity: autocapture fully off, no default tracking, no
 * remote-config fetch, IP/geo stripped, anonymous device id in localStorage
 * (no cookies), no user id (marketing site). With no key it never loads.
 */
export class AmplitudeTransport implements AnalyticsTransport {
  private amp: AmplitudeModule | null = null;
  private started = false;
  private optedOut = false;
  private queue: { name: string; category: string; props: AnalyticsProps }[] = [];

  constructor(private readonly serverZone: "US" | "EU" = "US") {}

  get isStarted(): boolean {
    return this.started;
  }

  start(apiKey: string): void {
    if (this.started || apiKey.length === 0) return;
    this.started = true;
    this.optedOut = false;

    // Re-grant after a prior revoke: the module is already loaded — just
    // re-enable and flush, never re-init.
    if (this.amp) {
      this.amp.setOptOut(false);
      this.flush(this.amp);
      return;
    }

    import("@amplitude/analytics-browser")
      .then((amp) => {
        amp.init(apiKey, {
          defaultTracking: false, // no auto sessions / page views / forms / file downloads
          autocapture: false, // disable the autocapture plugin entirely
          trackingOptions: { ipAddress: false }, // server-side IP/geo off (macOS parity)
          fetchRemoteConfig: false, // no remote-config network call on init
          serverZone: this.serverZone,
          instanceName: "openburnbar",
          identityStorage: "localStorage", // anonymous device id, no cookies
          optOut: false
        });
        this.amp = amp;
        if (!this.optedOut) this.flush(amp);
      })
      .catch(() => {
        // SDK failed to load — stay dark, drop the queue, never throw into the page.
        this.started = false;
        this.queue = [];
      });
  }

  track(name: string, category: string, props: AnalyticsProps): void {
    if (!this.started || this.optedOut) return;
    if (this.amp) this.send(this.amp, name, category, props);
    else this.queue.push({ name, category, props });
  }

  stop(): void {
    this.optedOut = true;
    this.started = false;
    this.queue = [];
    if (this.amp) {
      this.amp.setOptOut(true); // belt-and-suspenders: drop anything in flight
      this.amp.reset(); // clear the anonymous device id so a future grant starts fresh
    }
  }

  private flush(amp: AmplitudeModule): void {
    const pending = this.queue;
    this.queue = [];
    for (const e of pending) this.send(amp, e.name, e.category, e.props);
  }

  private send(amp: AmplitudeModule, name: string, category: string, props: AnalyticsProps): void {
    amp.track(name, { ...props, event_category: category });
  }
}

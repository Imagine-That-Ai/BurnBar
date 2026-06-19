import type { AnalyticsEnvelope, ServerAnalyticsTransport } from "./recorder.js";
import { resilientFetch } from "../resilienceHelpers.js";
import { logError } from "../logging.js";

/** Amplitude HTTP V2 batch endpoints (US / EU data residency). */
const AMPLITUDE_HTTP_V2_US = "https://api2.amplitude.com/2/httpapi";
const AMPLITUDE_HTTP_V2_EU = "https://api.eu.amplitude.com/2/httpapi";

export type ServerZone = "US" | "EU";

/** The minimal fetch surface the transport needs — injectable for tests. */
type FetchLike = (url: string, init: RequestInit) => Promise<Response>;

/**
 * Production transport backed by a tiny DIRECT Amplitude HTTP V2 client, the
 * server analogue of `AmplitudeTransport.swift` / `amplitudeTransport.ts`.
 *
 * Why a direct HTTP client instead of `@amplitude/analytics-node`?
 *  - A Cloud Function is stateless and may be FROZEN between invocations. The
 *    Node SDK owns an internal queue + a background flush timer; buffered events
 *    would be dropped or fire late from a frozen instance. The reference
 *    client/web transports lazily build a long-lived SDK client precisely
 *    because those hosts are long-lived — a Function is not.
 *  - The V2 API is a single authenticated POST; `insert_id` per event gives the
 *    required 7-day dedup. No autocapture / default-tracking / remote-config
 *    exists on the raw path, so there is nothing that could bypass the gate or
 *    go off-taxonomy — it is dark unless we explicitly POST.
 *  - It adds ZERO require-time cost on cold start (the codebase deliberately
 *    avoids heavy module loads on the shared bundle; see stripe.test.ts).
 *
 * Hardened to platform parity: NO ip is sent (server-side IP/geo resolution
 * off), anonymous `device_id` only (propagated from the client), `user_id` only
 * for authenticated actions, `min_id_length` relaxed so short ids are accepted.
 * With no key it never starts (the recorder's key gate makes this true).
 */
export class AmplitudeHttpTransport implements ServerAnalyticsTransport {
  private apiKey = "";
  private started = false;
  private readonly endpoint: string;

  constructor(
    serverZone: ServerZone = "US",
    private readonly fetchImpl: FetchLike = (url, init) => resilientFetch("amplitude.httpapi", url, init),
  ) {
    this.endpoint = serverZone === "EU" ? AMPLITUDE_HTTP_V2_EU : AMPLITUDE_HTTP_V2_US;
  }

  get isStarted(): boolean {
    return this.started;
  }

  start(apiKey: string): void {
    if (this.started || apiKey.length === 0) return;
    this.apiKey = apiKey;
    this.started = true;
  }

  async track(event: AnalyticsEnvelope): Promise<void> {
    if (!this.started || this.apiKey.length === 0) return;

    const eventProperties: Record<string, string | boolean> = {
      ...event.props,
      event_category: event.category,
    };

    const body = {
      api_key: this.apiKey,
      // `min_id_length` lets us use short device ids without Amplitude's default
      // 5-char floor rejecting them; we still never send a hardware id.
      options: { min_id_length: 1 },
      events: [
        {
          event_type: event.name,
          device_id: event.deviceId,
          ...(event.userId ? { user_id: event.userId } : {}),
          time: event.timeMs,
          insert_id: event.insertId, // 7-day dedup window
          event_properties: eventProperties,
          // platform/version live in event_properties (super-properties); we do
          // NOT populate Amplitude's geo fields. No `ip` → no server-side
          // IP/geo lookup. No `location_lat/lng`, no `dma`, no `city`.
        },
      ],
    };

    try {
      const res = await this.fetchImpl(this.endpoint, {
        method: "POST",
        headers: { "content-type": "application/json", accept: "application/json" },
        body: JSON.stringify(body),
      });
      if (!res.ok) {
        // Analytics is best-effort: never throw into the conversion path. Log a
        // status only (no body — the request carried our api_key; we keep it out
        // of logs), so a failing Amplitude can't fail a purchase/grant.
        logError({ event: "analytics.amplitude_http_error", status: res.status, event_type: event.name });
      }
    } catch (err) {
      logError({
        event: "analytics.amplitude_http_exception",
        event_type: event.name,
        detail: err instanceof Error ? err.message : "send failed",
      });
    }
  }

  stop(): void {
    this.started = false;
    this.apiKey = "";
  }
}

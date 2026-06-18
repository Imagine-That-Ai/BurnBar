import { randomUUID } from 'node:crypto';

import type { AnalyticsTransport, AnalyticsProps } from './recorder';
import type { AmplitudeServerZone } from './config';

/** Amplitude HTTP V2 endpoints (US / EU data residency). */
const AMPLITUDE_HTTP_V2_US = 'https://api2.amplitude.com/2/httpapi';
const AMPLITUDE_HTTP_V2_EU = 'https://api.eu.amplitude.com/2/httpapi';

/** The minimal request/response shapes the transport needs — structural, so the
 *  module pulls in neither the DOM lib nor a fetch polyfill, and tests inject a
 *  fake without mocking a global. */
export interface AmplitudeFetchInit {
  method: string;
  headers: Record<string, string>;
  body: string;
}
export interface AmplitudeFetchResponse {
  readonly ok: boolean;
  readonly status: number;
}
export type FetchLike = (url: string, init: AmplitudeFetchInit) => Promise<AmplitudeFetchResponse>;

/** Default transport: the Node 20+ global `fetch` (VS Code 1.95 ships Node 20).
 *  Reached through `globalThis` so no DOM lib types leak into this Node module. */
const globalFetch: FetchLike = (url, init) => {
  const candidate = Reflect.get(globalThis, 'fetch');
  if (typeof candidate !== 'function') {
    return Promise.reject(new Error('global fetch is unavailable'));
  }
  return Promise.resolve(candidate.call(globalThis, url, init));
};

/**
 * Production transport: a tiny DIRECT Amplitude HTTP V2 client — the same
 * dependency-free approach as the backend (`functions/src/analytics/amplitudeTransport.ts`),
 * and the analogue of AgentLens/Services/Analytics/AmplitudeTransport.swift and
 * website/src/lib/analytics/amplitudeTransport.ts.
 *
 * Why NOT `@amplitude/analytics-node`? The extension ships as a `tsc`-built VSIX
 * with `node_modules/**` excluded (.vscodeignore), so a dynamically-imported SDK
 * would not be present at runtime and analytics would silently never start. The
 * V2 API is a single authenticated POST — zero dependencies to package — and has
 * no autocapture / default-tracking / remote-config, so nothing can fire
 * off-taxonomy or bypass the gate.
 *
 * DARK by construction: it POSTs only after `start()` (which the recorder calls
 * solely once the consent + key gate passes), tracking before start is dropped,
 * `stop()` (revoke) goes silent immediately, identity is an anonymous random
 * per-install `device_id` attached to every event (never a hostname/hardware id),
 * `user_id` is never set (the extension has no sign-in), and NO `ip` is sent (no
 * server-side IP/geo). With no key it never starts (the recorder's key gate).
 */
export class AmplitudeTransport implements AnalyticsTransport {
  private apiKey = '';
  private started = false;
  private readonly endpoint: string;

  constructor(
    private readonly deviceId: string,
    serverZone: AmplitudeServerZone = 'US',
    private readonly fetchImpl: FetchLike = globalFetch
  ) {
    this.endpoint = serverZone === 'EU' ? AMPLITUDE_HTTP_V2_EU : AMPLITUDE_HTTP_V2_US;
  }

  get isStarted(): boolean {
    return this.started;
  }

  start(apiKey: string): void {
    if (this.started || apiKey.length === 0) return;
    this.apiKey = apiKey;
    this.started = true;
  }

  track(name: string, category: string, props: AnalyticsProps): void {
    // Dark until started: a stray pre-gate (or post-revoke) call sends nothing.
    // The recorder always start()s before it track()s, so no real event is lost.
    if (!this.started || this.apiKey.length === 0) return;
    this.send(name, category, props);
  }

  stop(): void {
    this.started = false;
    this.apiKey = '';
  }

  private send(name: string, category: string, props: AnalyticsProps): void {
    const body = JSON.stringify({
      api_key: this.apiKey,
      // Relax Amplitude's default 5-char id floor; our device_id is a 36-char
      // UUID anyway and we still never send a hardware id.
      options: { min_id_length: 1 },
      events: [
        {
          event_type: name,
          device_id: this.deviceId,
          // user_id intentionally omitted — the extension has no sign-in.
          time: Date.now(),
          insert_id: randomUUID(), // 7-day dedup window
          event_properties: { ...props, event_category: category }
          // No `ip` → no server-side IP/geo lookup; no geo fields.
        }
      ]
    });
    // Fire-and-forget + best-effort: never throw into the extension host, never
    // block a command. A failing Amplitude must not surface to the user.
    void this.post(body);
  }

  private async post(body: string): Promise<void> {
    try {
      await this.fetchImpl(this.endpoint, {
        method: 'POST',
        headers: { 'content-type': 'application/json', accept: 'application/json' },
        body
      });
    } catch {
      /* network/host error — analytics is best-effort; stay silent. */
    }
  }
}

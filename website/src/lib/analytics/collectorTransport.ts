import type { AnalyticsTransport, AnalyticsProps } from "./recorder";

type FetchLike = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;

/**
 * First-party collector transport. The browser POSTs consented events to
 * `PUBLIC_ANALYTICS_COLLECTOR_URL`. The Amplitude API key never enters this
 * bundle — the collector stamps it server-side.
 *
 * No collector URL → start() is a no-op and track() drops. That is the
 * default-off promise when the site is built without a collector.
 */
export const DEVICE_ID_KEY = "burnbar-analytics-device-id";

export function persistentAnonymousId(
  storage: { getItem(key: string): string | null; setItem(key: string, value: string): void },
  createId: () => string = newAnonymousId
): string {
  const existing = storage.getItem(DEVICE_ID_KEY)?.trim();
  if (existing) return existing;
  const id = createId();
  try {
    storage.setItem(DEVICE_ID_KEY, id);
  } catch {
    /* private mode / quota */
  }
  return id;
}

type IdStorage = { getItem(key: string): string | null; setItem(key: string, value: string): void };

function memoryStorage(): IdStorage {
  const m = new Map<string, string>();
  return { getItem: (k) => m.get(k) ?? null, setItem: (k, v) => void m.set(k, v) };
}

function consentTimeStorage(): IdStorage {
  try {
    if (typeof localStorage !== "undefined") return localStorage;
  } catch {
    /* private mode / SSR */
  }
  return memoryStorage();
}

export class FirstPartyCollectorTransport implements AnalyticsTransport {
  private started = false;
  private optedOut = false;
  private collectorUrl = "";
  private deviceId = "";
  private readonly explicitDeviceId: string | undefined;
  private readonly fetchImpl: FetchLike;
  private readonly storage: IdStorage;

  constructor(
    deviceId?: string,
    fetchImpl: FetchLike = (input, init) => fetch(input, init),
    storage: IdStorage = consentTimeStorage()
  ) {
    this.explicitDeviceId = deviceId;
    this.fetchImpl = fetchImpl;
    this.storage = storage;
  }

  get isStarted(): boolean {
    return this.started;
  }

  start(collectorUrl: string): void {
    if (this.started || collectorUrl.length === 0) return;
    this.collectorUrl = collectorUrl;
    this.started = true;
    this.optedOut = false;
    this.deviceId = this.explicitDeviceId ?? persistentAnonymousId(this.storage);
  }

  track(name: string, category: string, props: AnalyticsProps): void {
    if (!this.started || this.optedOut || this.collectorUrl.length === 0) return;
    const now = Date.now();
    void this.fetchImpl(this.collectorUrl, {
      method: "POST",
      headers: { "content-type": "application/json", accept: "application/json" },
      body: JSON.stringify({
        consent: true,
        events: [
          {
            name,
            category,
            props,
            device_id: this.deviceId,
            time_ms: now,
            insert_id: `${this.deviceId}:${name}:${now}`
          }
        ]
      }),
      keepalive: true
    }).catch(() => {
      /* analytics is best-effort — never throw into the page */
    });
  }

  stop(): void {
    this.optedOut = true;
    this.started = false;
    this.collectorUrl = "";
  }
}

function newAnonymousId(): string {
  try {
    if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
      return crypto.randomUUID();
    }
  } catch {
    /* private mode / SSR */
  }
  return `anon-${Math.random().toString(36).slice(2)}-${Date.now().toString(36)}`;
}

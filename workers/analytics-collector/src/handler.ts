/**
 * First-party Amplitude HTTP V2 collector.
 *
 * The browser never sees AMPLITUDE_API_KEY. It POSTs consented events here;
 * this handler stamps the server-side key and forwards to Amplitude.
 *
 * Dark by construction:
 *   - no consent flag → no network to Amplitude
 *   - no API key → no network to Amplitude
 *   - unknown / forbidden project id → no network to Amplitude
 *   - event name not on the allow-list → dropped
 *
 * Do not deploy secrets from this tree. Set AMPLITUDE_API_KEY via
 * `wrangler secret put`. Default project is OpenBurnBar Dev (830581).
 *
 * Amplitude routes by API key, not by AMPLITUDE_PROJECT_ID. The numeric id is a
 * local allowlist + event stamp (OpenBurnBar 830583 / Dev 830581 only). Bind
 * each deploy's secret to that project's key. A CubeLove/Hormiga key would
 * still land in those projects even if PROJECT_ID is 830583.
 */

import {
  AMPLITUDE_PROJECT,
  FUNNEL_ATTRIBUTION_KEYS,
  FUNNEL_EVENT_NAMES,
  isBoundedAttributionValue,
  isFunnelEventName,
  resolveAmplitudeProjectId,
  type FunnelEventName,
} from "../../../analytics/funnel-contract";

export const AMPLITUDE_HTTP_V2_US = "https://api2.amplitude.com/2/httpapi";
export const AMPLITUDE_HTTP_V2_EU = "https://api.eu.amplitude.com/2/httpapi";

export const MAX_COLLECTOR_EVENTS = 20;
export const MAX_COLLECTOR_BODY_BYTES = 16_384;
/** Client clocks may drift; outside this window we stamp the Worker receipt. */
export const MAX_EVENT_TIME_SKEW_MS = 24 * 60 * 60 * 1000;
export const COLLECTOR_RATE_LIMIT_MAX = 60;
export const COLLECTOR_RATE_LIMIT_PERIOD_SECONDS = 60;

const PRODUCT_EVENT_ALLOWLIST = new Set<string>([
  ...FUNNEL_EVENT_NAMES,
  "consent.analytics.granted",
  "app.session.started",
  "screen.viewed",
  "nav.route.changed",
  "download.cta.clicked",
  "pricing.plan.viewed",
  "pricing.cta.clicked",
  "nav.external.clicked",
  "auth.sign_in.completed",
  "auth.sign_up.completed",
  "error.handled",
  "arena.variant.exposed",
  "arena.artifact.played",
  "arena.vote.recorded",
  "arena.auth.gate_shown",
  "arena.sign_in.completed",
]);

const EMAILISH = /[^\s@]+@[^\s@]+\.[^\s@]+/;
const PROP_KEY = /^[a-z][a-z0-9_]*$/;
const ANONYMOUS_ID = /^[A-Za-z0-9._:-]{1,64}$/;
const ATTRIBUTION_KEY_SET = new Set<string>(FUNNEL_ATTRIBUTION_KEYS);

const ENUM_PROP_VALUES: Record<string, ReadonlySet<string>> = {
  product: new Set(["burnbar"]),
  platform: new Set(["web"]),
  surface: new Set([
    "home",
    "download",
    "pricing",
    "trust",
    "privacy",
    "security",
    "support",
    "mcp",
    "router",
    "control",
    "floo",
    "link",
    "other",
    "web",
  ]),
  target_platform: new Set(["macos", "ios", "android", "linux", "windows"]),
  event_category: new Set([
    "lifecycle",
    "screen_view",
    "primary_action",
    "conversion_auth",
    "error",
  ]),
  placement: new Set(["hero", "header", "mobile_nav", "pricing", "footer"]),
  destination: new Set(["github", "discord", "docs"]),
  plan: new Set(["free", "cloud", "cloud_pro", "ultra"]),
  variant: new Set(["neural", "unknown"]),
  choice: new Set(["a", "b", "A", "B", "tie"]),
  rubric: new Set(["none", "partial", "full"]),
  side: new Set(["A", "B"]),
  provider: new Set(["google", "apple", "github", "facebook"]),
  method: new Set(["google", "apple", "github", "email", "facebook"]),
  outcome: new Set(["success", "failure"]),
  consent_version: new Set(["1"]),
};

const BOOLEAN_PROP_KEYS = new Set([
  "captured",
  "cold_start",
  "is_first_launch",
  "is_first_view",
]);

/** Direct POSTs may only carry taxonomy-known keys. A missing enum is not "unrestricted." */
const ALLOWED_PROP_KEYS = new Set<string>([
  ...Object.keys(ENUM_PROP_VALUES),
  ...BOOLEAN_PROP_KEYS,
  ...FUNNEL_ATTRIBUTION_KEYS,
  "app_version",
  "source",
]);

export type RateLimitBinding = {
  limit(options: { key: string }): Promise<{ success: boolean }>;
};

export type CollectorEnv = {
  AMPLITUDE_API_KEY?: string;
  AMPLITUDE_PROJECT_ID?: string;
  AMPLITUDE_SERVER_ZONE?: string;
  COLLECTOR_RATE_LIMIT?: RateLimitBinding;
};

export type CollectorEvent = {
  name: string;
  category?: string;
  props?: Record<string, string | boolean>;
  device_id?: string;
  time_ms?: number;
  insert_id?: string;
};

export type CollectorRequestBody = {
  consent?: boolean;
  events?: CollectorEvent[];
};

export type FetchLike = (url: string, init: RequestInit) => Promise<Response>;

export type HandlerResult = {
  status: number;
  body: Record<string, unknown>;
  forwarded: number;
  amplitudeUrl: string | null;
};

function json(status: number, body: Record<string, unknown>, extra: Partial<HandlerResult> = {}): HandlerResult {
  return { status, body, forwarded: 0, amplitudeUrl: null, ...extra };
}

function amplitudeEndpoint(zone: string | undefined): string {
  return (zone ?? "").trim().toUpperCase() === "EU" ? AMPLITUDE_HTTP_V2_EU : AMPLITUDE_HTTP_V2_US;
}

function isAllowedEventName(name: string): name is FunnelEventName | string {
  return PRODUCT_EVENT_ALLOWLIST.has(name) || isFunnelEventName(name);
}

function sanitizeProps(props: Record<string, string | boolean> | undefined): Record<string, string | boolean> {
  const out: Record<string, string | boolean> = {};
  if (!props || typeof props !== "object" || Array.isArray(props)) return out;
  for (const [key, value] of Object.entries(props)) {
    if (!PROP_KEY.test(key)) continue;
    if (!ALLOWED_PROP_KEYS.has(key)) continue;
    if (key === "email" || key === "raw_email" || key.endsWith("_email")) continue;
    if (key.startsWith("utm_") && !ATTRIBUTION_KEY_SET.has(key)) continue;
    if (typeof value === "boolean") {
      if (BOOLEAN_PROP_KEYS.has(key)) out[key] = value;
      continue;
    }
    if (typeof value !== "string") continue;
    const trimmed = value.trim();
    if (trimmed.length === 0) continue;
    if (EMAILISH.test(trimmed)) continue;
    if (!isBoundedAttributionValue(trimmed)) continue;
    const allowed = ENUM_PROP_VALUES[key];
    if (allowed && !allowed.has(trimmed)) continue;
    out[key] = trimmed;
  }
  if (out.product !== "burnbar") out.product = "burnbar";
  return out;
}

const PRODUCTION_COLLECTOR_ORIGINS = new Set([
  "https://burnbar.ai",
  "https://www.burnbar.ai",
  "https://burnbar.web.app",
  "https://burnbar.firebaseapp.com",
]);

const DEVELOPMENT_COLLECTOR_ORIGINS = new Set([
  "https://burnbar-staging.web.app",
  "https://burnbar-staging.firebaseapp.com",
]);

function isLocalDevOrigin(origin: string | null): boolean {
  return origin !== null && /^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/.test(origin);
}

export function isKnownCollectorOrigin(origin: string | null): boolean {
  return (
    origin !== null &&
    (PRODUCTION_COLLECTOR_ORIGINS.has(origin) ||
      DEVELOPMENT_COLLECTOR_ORIGINS.has(origin) ||
      isLocalDevOrigin(origin))
  );
}

/** Known origins for CORS. When `projectId` is set, staging is Dev-only and production is prod-only. */
export function isAllowedCollectorOrigin(origin: string | null, projectId?: number | null): boolean {
  if (!isKnownCollectorOrigin(origin) || origin === null) return false;
  if (projectId === undefined) return true;
  if (projectId === null) return false;
  if (projectId === AMPLITUDE_PROJECT.production) {
    return PRODUCTION_COLLECTOR_ORIGINS.has(origin);
  }
  if (projectId === AMPLITUDE_PROJECT.development) {
    return DEVELOPMENT_COLLECTOR_ORIGINS.has(origin) || isLocalDevOrigin(origin);
  }
  return false;
}

function asTrimmedString(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function isPhoneShapedIdentifier(value: string): boolean {
  return /^\d{7,}$/.test(value.replace(/[._:-]/g, ""));
}

/** Bounded anonymous-ID token. Emails, phones, spaces, and oversize values fall back. */
function sanitizeAnonymousId(value: unknown, fallback: string): string {
  const trimmed = asTrimmedString(value);
  if (!trimmed) return fallback;
  if (EMAILISH.test(trimmed)) return fallback;
  if (!ANONYMOUS_ID.test(trimmed)) return fallback;
  if (isPhoneShapedIdentifier(trimmed)) return fallback;
  return trimmed;
}

function mintedAnonymousId(prefix: "anon" | "obb", now: number, index: number): string {
  return `${prefix}-${now.toString(36)}-${index}-${Math.random().toString(36).slice(2, 10)}`;
}

export function sanitizeCollectorEventTime(timeMs: unknown, now: number): number {
  if (typeof timeMs !== "number" || !Number.isFinite(timeMs)) return now;
  if (timeMs < 0) return now;
  if (Math.abs(timeMs - now) > MAX_EVENT_TIME_SKEW_MS) return now;
  return Math.trunc(timeMs);
}

export function collectorClientKey(headers: { get(name: string): string | null }): string {
  return headers.get("cf-connecting-ip")?.trim() || "unknown";
}

/** Isolate-local fallback when the Wrangler rate-limit binding is absent (tests / wrangler dev). */
export function createMemoryRateLimiter(
  limit = COLLECTOR_RATE_LIMIT_MAX,
  periodMs = COLLECTOR_RATE_LIMIT_PERIOD_SECONDS * 1000,
): RateLimitBinding {
  const hits = new Map<string, number[]>();
  return {
    async limit({ key }) {
      const now = Date.now();
      const window = (hits.get(key) ?? []).filter((t) => now - t < periodMs);
      if (window.length >= limit) {
        hits.set(key, window);
        return { success: false };
      }
      window.push(now);
      hits.set(key, window);
      return { success: true };
    },
  };
}

export function rejectOversizedCollectorBody(raw: string): HandlerResult | null {
  if (raw.length > MAX_COLLECTOR_BODY_BYTES) {
    return json(413, { accepted: false, reason: "body_too_large" });
  }
  return null;
}

export function applyCollectorRateLimit(
  env: CollectorEnv,
  clientKey: string,
): Promise<{ success: boolean }> {
  const limiter = env.COLLECTOR_RATE_LIMIT;
  if (!limiter) {
    return Promise.resolve({ success: true });
  }
  return limiter.limit({ key: (clientKey ?? "").trim() || "unknown" });
}

export function declaredCollectorBodyTooLarge(contentLength: string | null): boolean {
  if (!contentLength) return false;
  const declared = Number.parseInt(contentLength, 10);
  return Number.isFinite(declared) && declared > MAX_COLLECTOR_BODY_BYTES;
}

export async function readBoundedCollectorBody(request: Request): Promise<string | null> {
  const reader = request.body?.getReader();
  if (!reader) return "";
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    if (!value) continue;
    total += value.byteLength;
    if (total > MAX_COLLECTOR_BODY_BYTES) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  return new TextDecoder().decode(concatBytes(chunks));
}

function concatBytes(chunks: Uint8Array[]): Uint8Array {
  const total = chunks.reduce((sum, chunk) => sum + chunk.byteLength, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return out;
}

const WEBSITE_SURFACE = ENUM_PROP_VALUES.surface;

/** Required keys that survive sanitizeProps. Missing map entry → fail closed. */
const REQUIRED_EVENT_PROPS: Record<string, readonly string[]> = {
  "consent.analytics.granted": ["consent_version"],
  "app.session.started": ["surface"],
  "screen.viewed": ["surface"],
  "nav.route.changed": [],
  "download.cta.clicked": ["placement"],
  "pricing.plan.viewed": [],
  "pricing.cta.clicked": ["plan"],
  "nav.external.clicked": ["destination"],
  "auth.sign_in.completed": ["method", "outcome"],
  "auth.sign_up.completed": ["method", "outcome"],
  "error.handled": [],
  "arena.variant.exposed": ["variant"],
  "arena.artifact.played": ["variant", "side"],
  "arena.vote.recorded": ["variant", "choice", "rubric"],
  "arena.auth.gate_shown": ["variant"],
  "arena.sign_in.completed": ["variant", "provider"],
};

function hasRequiredProps(
  props: Record<string, string | boolean>,
  keys: readonly string[],
): boolean {
  return keys.every((key) => {
    const value = props[key];
    if (typeof value === "boolean") return true;
    return typeof value === "string" && value.length > 0;
  });
}

function eventMeetsSchema(name: string, props: Record<string, string | boolean>): boolean {
  if (name === "email.captured") {
    return props.captured === true;
  }
  if (name === "install.started") {
    return false;
  }
  if (isFunnelEventName(name)) {
    return typeof props.surface === "string" && WEBSITE_SURFACE.has(props.surface);
  }
  const required = REQUIRED_EVENT_PROPS[name];
  if (!required) return false;
  return hasRequiredProps(props, required);
}

export async function handleCollectorPost(
  body: CollectorRequestBody | null | undefined,
  env: CollectorEnv,
  fetchImpl: FetchLike,
  origin?: string | null,
  clientKey?: string,
  options: { applyRateLimit?: boolean } = {},
): Promise<HandlerResult> {
  if (origin !== undefined && !isKnownCollectorOrigin(origin)) {
    return json(403, { accepted: false, reason: "origin_rejected" });
  }

  if (options.applyRateLimit !== false) {
    const { success } = await applyCollectorRateLimit(env, clientKey ?? "");
    if (!success) {
      return json(429, { accepted: false, reason: "rate_limited" });
    }
  }

  if (body == null || typeof body !== "object" || Array.isArray(body)) {
    return json(400, { accepted: false, reason: "invalid_body" });
  }

  if (body.consent !== true) {
    return json(204, { accepted: false, reason: "consent_required" });
  }

  const apiKey = (env.AMPLITUDE_API_KEY ?? "").trim();
  if (apiKey.length === 0) {
    return json(204, { accepted: false, reason: "collector_dark" });
  }

  const projectId = resolveAmplitudeProjectId(env.AMPLITUDE_PROJECT_ID ?? AMPLITUDE_PROJECT.development);
  if (projectId === null) {
    return json(409, { accepted: false, reason: "project_rejected" });
  }

  if (origin !== undefined && !isAllowedCollectorOrigin(origin, projectId)) {
    return json(403, { accepted: false, reason: "origin_rejected" });
  }

  const incoming = Array.isArray(body.events) ? body.events : [];
  if (incoming.length > MAX_COLLECTOR_EVENTS) {
    return json(413, { accepted: false, reason: "batch_too_large" });
  }
  const allowed = incoming.filter((event) => event && typeof event.name === "string" && isAllowedEventName(event.name));
  const prepared = allowed.flatMap((event) => {
    const props = sanitizeProps({
      ...event.props,
      ...(asTrimmedString(event.category) ? { event_category: asTrimmedString(event.category) } : {}),
    });
    if (!eventMeetsSchema(event.name, props)) return [];
    return [{ event, props }];
  });
  if (prepared.length === 0) {
    return json(204, { accepted: false, reason: "no_allowed_events" });
  }

  const endpoint = amplitudeEndpoint(env.AMPLITUDE_SERVER_ZONE);
  const now = Date.now();
  const payload = {
    api_key: apiKey,
    options: { min_id_length: 1 },
    events: prepared.map(({ event, props }, index) => ({
      event_type: event.name,
      device_id: sanitizeAnonymousId(event.device_id, mintedAnonymousId("anon", now, index)),
      time: sanitizeCollectorEventTime(event.time_ms, now),
      insert_id: sanitizeAnonymousId(event.insert_id, mintedAnonymousId("obb", now, index)),
      event_properties: {
        ...props,
        amplitude_project_id: String(projectId),
      },
    })),
  };

  let res: Response;
  try {
    res = await fetchImpl(endpoint, {
      method: "POST",
      headers: { "content-type": "application/json", accept: "application/json" },
      body: JSON.stringify(payload),
    });
  } catch {
    return json(502, { accepted: false, reason: "amplitude_http_error" }, { forwarded: 0, amplitudeUrl: endpoint });
  }

  if (!res.ok) {
    return json(502, { accepted: false, reason: "amplitude_http_error" }, { forwarded: 0, amplitudeUrl: endpoint });
  }

  return json(
    200,
    { accepted: true, events_forwarded: prepared.length, project_id: projectId },
    { forwarded: prepared.length, amplitudeUrl: endpoint },
  );
}

export function collectorCorsHeaders(
  origin: string | null,
  projectId?: number | null,
): Record<string, string> {
  const allowed = isAllowedCollectorOrigin(origin, projectId);
  return {
    "access-control-allow-origin": allowed && origin ? origin : "https://burnbar.ai",
    "access-control-allow-methods": "POST, OPTIONS",
    "access-control-allow-headers": "content-type",
    "access-control-max-age": "86400",
    vary: "Origin",
  };
}

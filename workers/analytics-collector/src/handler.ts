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
  FUNNEL_EVENT_NAMES,
  isFunnelEventName,
  resolveAmplitudeProjectId,
  type FunnelEventName,
} from "../../../analytics/funnel-contract";

export const AMPLITUDE_HTTP_V2_US = "https://api2.amplitude.com/2/httpapi";
export const AMPLITUDE_HTTP_V2_EU = "https://api.eu.amplitude.com/2/httpapi";

export const MAX_COLLECTOR_EVENTS = 20;

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

export type CollectorEnv = {
  AMPLITUDE_API_KEY?: string;
  AMPLITUDE_PROJECT_ID?: string;
  AMPLITUDE_SERVER_ZONE?: string;
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
    if (key === "email" || key === "raw_email" || key.endsWith("_email")) continue;
    if (typeof value === "string") {
      const trimmed = value.trim();
      if (trimmed.length === 0) continue;
      if (EMAILISH.test(trimmed)) continue;
      out[key] = trimmed.slice(0, 200);
    } else if (typeof value === "boolean") {
      out[key] = value;
    }
  }
  if (out.product !== "burnbar") out.product = "burnbar";
  return out;
}

export function isAllowedCollectorOrigin(origin: string | null): boolean {
  return (
    origin === "https://burnbar.ai" ||
    origin === "https://www.burnbar.ai" ||
    origin === "https://burnbar.web.app" ||
    origin === "https://burnbar.firebaseapp.com" ||
    origin === "https://burnbar-staging.web.app" ||
    origin === "https://burnbar-staging.firebaseapp.com" ||
    (origin !== null && /^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/.test(origin))
  );
}

function asTrimmedString(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

export async function handleCollectorPost(
  body: CollectorRequestBody | null | undefined,
  env: CollectorEnv,
  fetchImpl: FetchLike,
  origin?: string | null,
): Promise<HandlerResult> {
  if (origin !== undefined && !isAllowedCollectorOrigin(origin)) {
    return json(403, { accepted: false, reason: "origin_rejected" });
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

  const incoming = Array.isArray(body.events) ? body.events : [];
  if (incoming.length > MAX_COLLECTOR_EVENTS) {
    return json(413, { accepted: false, reason: "batch_too_large" });
  }
  const allowed = incoming.filter((event) => event && typeof event.name === "string" && isAllowedEventName(event.name));
  if (allowed.length === 0) {
    return json(204, { accepted: false, reason: "no_allowed_events" });
  }

  const endpoint = amplitudeEndpoint(env.AMPLITUDE_SERVER_ZONE);
  const now = Date.now();
  const payload = {
    api_key: apiKey,
    options: { min_id_length: 1 },
    events: allowed.map((event, index) => ({
      event_type: event.name,
      device_id: asTrimmedString(event.device_id) || "anonymous",
      time: typeof event.time_ms === "number" ? event.time_ms : now,
      insert_id: asTrimmedString(event.insert_id) || `obb-${now}-${index}`,
      event_properties: {
        ...sanitizeProps(event.props),
        ...(asTrimmedString(event.category) ? { event_category: asTrimmedString(event.category) } : {}),
        amplitude_project_id: String(projectId),
      },
    })),
  };

  const res = await fetchImpl(endpoint, {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json" },
    body: JSON.stringify(payload),
  });

  if (!res.ok) {
    return json(502, { accepted: false, reason: "amplitude_http_error" }, { forwarded: 0, amplitudeUrl: endpoint });
  }

  return json(
    200,
    { accepted: true, events_forwarded: allowed.length, project_id: projectId },
    { forwarded: allowed.length, amplitudeUrl: endpoint },
  );
}

export function collectorCorsHeaders(origin: string | null): Record<string, string> {
  const allowed = isAllowedCollectorOrigin(origin);
  return {
    "access-control-allow-origin": allowed && origin ? origin : "https://burnbar.ai",
    "access-control-allow-methods": "POST, OPTIONS",
    "access-control-allow-headers": "content-type",
    "access-control-max-age": "86400",
    vary: "Origin",
  };
}

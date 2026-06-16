/**
 * Rate limits for unauthenticated public HTTP endpoints and high-risk approval callables.
 */

import { createHash } from "node:crypto";

import { HttpsError } from "firebase-functions/v2/https";
import { Timestamp } from "firebase-admin/firestore";

import { db } from "../adminRuntime.js";

type PublicHttpRateLimitAction = "cli_link_start" | "hermes_gateway_device_start";

/**
 * Public HTTPS endpoints that need a product-layer rate limit. Each maps to a
 * declared bound so the endpoint catalog can be statically verified.
 * Names must match the auto-generated `exportedName` in
 * `endpointAuthorizationCatalog.generated.ts` (camelCase).
 * Closes codex-gpt-5 FINDING-005 / kimi FINDING-012.
 */
type PublicHttpEndpointName =
  | "burnBarHermesGateway"
  | "healthCheck"
  | "healthLive"
  | "healthReady"
  | "latestRouterRundown"
  | "pollCliLink"
  | "startCliLink";

type CallableApprovalRateLimitAction = "cli_link_approve_fail" | "hermes_gateway_approve_fail";

type HermesGatewayBearerRateLimitAction =
  | "hermes_gateway_message_send"
  | "hermes_gateway_attachment_init"
  // L3: owner-authenticated event enqueue (phone -> paired agent). Scoped per
  // (uid, clientId); prevents an account from flooding its own paired agent with
  // dispatched events / model switches (self-inflicted LLM spend amplification).
  | "hermes_gateway_event_enqueue";

const PUBLIC_HTTP_LIMITS: Record<PublicHttpRateLimitAction, { windowSeconds: number; maxAttempts: number }> = {
  cli_link_start: { windowSeconds: 3600, maxAttempts: 20 },
  hermes_gateway_device_start: { windowSeconds: 3600, maxAttempts: 20 },
};

/**
 * Per-endpoint product-layer rate limits for public HTTPS functions.
 * Health probes allow generous monitoring traffic; heavier/compute endpoints are
 * tighter. Limits are keyed by client IP (or `unknown`) to keep state bounded.
 */
const PUBLIC_HTTP_ENDPOINT_LIMITS: Record<PublicHttpEndpointName, { windowSeconds: number; maxAttempts: number }> = {
  // Authenticated bearer gateway: per-IP limit is defense-in-depth before token
  // resolution. 120/min keeps legitimate paired-agent traffic unthrottled while
  // capping abuse of the public HTTP surface.
  burnBarHermesGateway: { windowSeconds: 60, maxAttempts: 120 },
  healthCheck: { windowSeconds: 60, maxAttempts: 30 },
  healthLive: { windowSeconds: 60, maxAttempts: 60 },
  healthReady: { windowSeconds: 60, maxAttempts: 30 },
  latestRouterRundown: { windowSeconds: 60, maxAttempts: 60 },
  pollCliLink: { windowSeconds: 60, maxAttempts: 60 },
  // Device-enrollment bootstrap: keep the historical 20/hour ceiling from the
  // shared `cli_link_start` action; it is tighter than poll (60/min) because
  // this endpoint mints a fresh session and writes to Firestore.
  startCliLink: { windowSeconds: 3600, maxAttempts: 20 },
};

const APPROVAL_LIMITS: Record<CallableApprovalRateLimitAction, { windowSeconds: number; maxAttempts: number }> = {
  cli_link_approve_fail: { windowSeconds: 900, maxAttempts: 10 },
  hermes_gateway_approve_fail: { windowSeconds: 900, maxAttempts: 10 },
};

const HERMES_GATEWAY_BEARER_LIMITS: Record<
  HermesGatewayBearerRateLimitAction,
  { windowSeconds: number; maxAttempts: number }
> = {
  hermes_gateway_message_send: { windowSeconds: 60, maxAttempts: 120 },
  hermes_gateway_attachment_init: { windowSeconds: 600, maxAttempts: 20 },
  hermes_gateway_event_enqueue: { windowSeconds: 60, maxAttempts: 120 },
};

function rateLimitDocId(keyMaterial: string, action: string): string {
  const hash = createHash("sha256").update(`${keyMaterial}:${action}`).digest("hex");
  return `${action}_${hash.slice(0, 40)}`;
}

export function clientIpFromHttpRequest(req: {
  headers?: Record<string, unknown>;
  ip?: string;
  socket?: { remoteAddress?: string };
}): string {
  if (typeof req.ip === "string" && req.ip.length > 0) return req.ip;
  const remote = req.socket?.remoteAddress;
  if (typeof remote === "string" && remote.length > 0) return remote;
  if (process.env.OPENBURNBAR_TRUST_X_FORWARDED_FOR !== "1") return "unknown";
  const forwarded = req.headers?.["x-forwarded-for"];
  if (typeof forwarded === "string") {
    const first = forwarded.split(",")[0]?.trim();
    if (first) return first;
  }
  return "unknown";
}

async function incrementRateLimit(
  docId: string,
  action: string,
  limit: { windowSeconds: number; maxAttempts: number },
): Promise<void> {
  const ref = db.doc(`public_rate_limits/${docId}`);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const now = Date.now();
    const data = snap.data();
    let count = typeof data?.count === "number" ? data.count : 0;
    let windowStartMillis = typeof data?.windowStartMillis === "number" ? data.windowStartMillis : 0;
    if (now - windowStartMillis > limit.windowSeconds * 1000) {
      count = 0;
      windowStartMillis = now;
    }
    if (count >= limit.maxAttempts) {
      throw new HttpsError("resource-exhausted", "Too many requests. Try again later.");
    }
    tx.set(
      ref,
      {
        action,
        count: count + 1,
        windowStartMillis,
        updatedAt: Timestamp.now(),
        schemaVersion: 1,
      },
      { merge: true },
    );
  });
}

export async function checkPublicHttpRateLimit(keyMaterial: string, action: PublicHttpRateLimitAction): Promise<void> {
  const limit = PUBLIC_HTTP_LIMITS[action];
  await incrementRateLimit(rateLimitDocId(keyMaterial, action), action, limit);
}

export async function checkHermesGatewayBearerRateLimit(
  uid: string,
  clientId: string,
  action: HermesGatewayBearerRateLimitAction,
): Promise<void> {
  const limit = HERMES_GATEWAY_BEARER_LIMITS[action];
  await incrementRateLimit(rateLimitDocId(`${uid}:${clientId}`, action), action, limit);
}

export async function recordCallableApprovalFailure(
  uid: string,
  action: CallableApprovalRateLimitAction,
): Promise<void> {
  const limit = APPROVAL_LIMITS[action];
  await incrementRateLimit(rateLimitDocId(uid, action), action, limit);
}

export async function assertCallableApprovalNotLocked(
  uid: string,
  action: CallableApprovalRateLimitAction,
): Promise<void> {
  const limit = APPROVAL_LIMITS[action];
  const ref = db.doc(`public_rate_limits/${rateLimitDocId(uid, action)}`);
  const snap = await ref.get();
  if (!snap.exists) return;
  const data = snap.data();
  const count = typeof data?.count === "number" ? data.count : 0;
  const windowStartMillis = typeof data?.windowStartMillis === "number" ? data.windowStartMillis : 0;
  const elapsed = Date.now() - windowStartMillis;
  if (elapsed <= limit.windowSeconds * 1000 && count >= limit.maxAttempts) {
    throw new HttpsError("resource-exhausted", "Too many failed approval attempts. Try again later.");
  }
}

/**
 * Rate-limit a public HTTPS endpoint by endpoint name + client IP.
 * Throws HttpsError resource-exhausted when the limit is exceeded.
 */
export async function checkPublicHttpEndpointRateLimit(
  endpoint: PublicHttpEndpointName,
  keyMaterial: string,
): Promise<void> {
  const limit = PUBLIC_HTTP_ENDPOINT_LIMITS[endpoint];
  await incrementRateLimit(rateLimitDocId(`${endpoint}:${keyMaterial}`, endpoint), endpoint, limit);
}

/**
 * Returns true when the thrown error is a product-layer rate-limit rejection.
 * Callers use this to map `resource-exhausted` to HTTP 429 while letting
 * genuine Firestore / transaction errors surface as 500.
 */
export function isPublicRateLimitExceeded(err: unknown): boolean {
  return err instanceof HttpsError && err.code === "resource-exhausted";
}

/**
 * Declared set of public HTTPS endpoints with product-layer rate limits.
 * Used by the static inventory test to ensure every public endpoint is bounded.
 */
export const RATE_LIMITED_PUBLIC_HTTP_ENDPOINTS: ReadonlyArray<PublicHttpEndpointName> = Object.freeze(
  Object.keys(PUBLIC_HTTP_ENDPOINT_LIMITS) as Array<PublicHttpEndpointName>,
);

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
  | "issueWindowsAppCheckChallenge"
  | "mintLinuxAppCheckToken"
  | "mintWindowsAppCheckToken"
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
  issueWindowsAppCheckChallenge: { windowSeconds: 3600, maxAttempts: 40 },
  // Device-attestation token mint: Linux/Windows AppCheck bootstrap. 20/hour
  // per IP — same posture as startCliLink since each mints a session-scoped token.
  mintLinuxAppCheckToken: { windowSeconds: 3600, maxAttempts: 20 },
  mintWindowsAppCheckToken: { windowSeconds: 3600, maxAttempts: 20 },
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

// Per-uid burst + daily limiters for authenticated onCall endpoints that
// perform owner-funded work or hit Firestore with a non-trivial cost per call.
// Each mirrors the hosted-Insights pattern (burst + daily) so a single account
// cannot loop calls to exhaust shared resources, while leaving normal
// interactive usage unthrottled. Keyed per uid so the limit follows the
// account, not a device/IP.
type CallableRateLimitAction =
  | "voip_call_burst"
  | "voip_call_daily"
  | "knowledge_search_burst"
  | "knowledge_search_daily"
  | "agent_notification_reply_burst"
  | "agent_notification_reply_daily";

const CALLABLE_RATE_LIMITS: Record<CallableRateLimitAction, { windowSeconds: number; maxAttempts: number }> = {
  // VoIP call trigger: each call fans out APNs + FCM pushes. 20 burst/min,
  // 100/day — generous for legitimate call initiation but caps push-spam.
  voip_call_burst: { windowSeconds: 60, maxAttempts: 20 },
  voip_call_daily: { windowSeconds: 86_400, maxAttempts: 100 },
  // Knowledge search: server-side vector ANN over cloaked embeddings. 30
  // burst/min, 300/day — interactive Q&A is well under this, but a looped
  // caller cannot pin Firestore vector compute.
  knowledge_search_burst: { windowSeconds: 60, maxAttempts: 30 },
  knowledge_search_daily: { windowSeconds: 86_400, maxAttempts: 300 },
  // Agent notification reply: writes a queued reply doc. 30 burst/min, 200/day
  // — a burst of replies from a notification thread is normal, but a loop
  // cannot flood the reply queue.
  agent_notification_reply_burst: { windowSeconds: 60, maxAttempts: 30 },
  agent_notification_reply_daily: { windowSeconds: 86_400, maxAttempts: 200 },
};

// Owner-funded hosted Intelligence Brief (OpenRouter). The Pro paywall gates
// access but does not bound per-account request volume, and each call bills
// input tokens to the owner's OpenRouter budget. A short burst window plus a
// daily ceiling keeps a single Pro account from draining that budget with
// looped calls, while leaving normal interactive Q&A unthrottled. Keyed per
// uid so the limit follows the account, not a device/IP.
type HostedInsightsRateLimitAction = "insights_hosted_answer_burst" | "insights_hosted_answer_daily";

const HOSTED_INSIGHTS_LIMITS: Record<HostedInsightsRateLimitAction, { windowSeconds: number; maxAttempts: number }> = {
  insights_hosted_answer_burst: { windowSeconds: 60, maxAttempts: 10 },
  insights_hosted_answer_daily: { windowSeconds: 86_400, maxAttempts: 200 },
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

type RateLimitIncrement = {
  docId: string;
  action: string;
  limit: { windowSeconds: number; maxAttempts: number };
};

async function incrementRateLimitsAtomically(increments: readonly RateLimitIncrement[]): Promise<void> {
  const targets = increments.map((increment) => ({
    ...increment,
    ref: db.doc(`public_rate_limits/${increment.docId}`),
  }));
  await db.runTransaction(async (tx) => {
    const snapshots = await Promise.all(targets.map(({ ref }) => tx.get(ref)));
    const now = Date.now();
    const writes = targets.map((target, index) => {
      const data = snapshots[index]?.data();
      let count = typeof data?.count === "number" ? data.count : 0;
      let windowStartMillis = typeof data?.windowStartMillis === "number" ? data.windowStartMillis : 0;
      if (now - windowStartMillis > target.limit.windowSeconds * 1000) {
        count = 0;
        windowStartMillis = now;
      }
      if (count >= target.limit.maxAttempts) {
        throw new HttpsError("resource-exhausted", "Too many requests. Try again later.");
      }
      return {
        ref: target.ref,
        data: {
          action: target.action,
          count: count + 1,
          windowStartMillis,
          updatedAt: Timestamp.now(),
          schemaVersion: 1,
        },
      };
    });
    for (const { ref, data } of writes) tx.set(ref, data, { merge: true });
  });
}

async function incrementRateLimit(
  docId: string,
  action: string,
  limit: { windowSeconds: number; maxAttempts: number },
): Promise<void> {
  await incrementRateLimitsAtomically([{ docId, action, limit }]);
}

async function incrementCallableRateLimitsAtomically(
  uid: string,
  actions: readonly [CallableRateLimitAction, CallableRateLimitAction],
): Promise<void> {
  await incrementRateLimitsAtomically(
    actions.map((action) => ({
      docId: rateLimitDocId(uid, action),
      action,
      limit: CALLABLE_RATE_LIMITS[action],
    })),
  );
}

export async function checkPublicHttpRateLimit(keyMaterial: string, action: PublicHttpRateLimitAction): Promise<void> {
  const limit = PUBLIC_HTTP_LIMITS[action];
  await incrementRateLimit(rateLimitDocId(keyMaterial, action), action, limit);
}

/**
 * Per-user rate limit for the owner-funded hosted Intelligence Brief callable
 * (`insightsHostedAnswer`). Enforces both a short burst window and a daily
 * ceiling so a single Pro account cannot loop calls to drain the owner's
 * OpenRouter budget. Throws `resource-exhausted` when either bound is hit.
 */
export async function checkHostedInsightsAnswerRateLimit(uid: string): Promise<void> {
  await incrementRateLimit(
    rateLimitDocId(uid, "insights_hosted_answer_burst"),
    "insights_hosted_answer_burst",
    HOSTED_INSIGHTS_LIMITS.insights_hosted_answer_burst,
  );
  await incrementRateLimit(
    rateLimitDocId(uid, "insights_hosted_answer_daily"),
    "insights_hosted_answer_daily",
    HOSTED_INSIGHTS_LIMITS.insights_hosted_answer_daily,
  );
}

/**
 * Per-user rate limit for the VoIP call trigger callable (`triggerVoIPCall`).
 * Enforces both a short burst window and a daily ceiling so a single account
 * cannot loop call triggers to spam push notifications. Throws
 * `resource-exhausted` when either bound is hit.
 */
export async function checkVoIPCallRateLimit(uid: string): Promise<void> {
  await incrementCallableRateLimitsAtomically(uid, ["voip_call_burst", "voip_call_daily"]);
}

/**
 * Per-user rate limit for the knowledge search callable (`searchKnowledge`).
 * Enforces both a short burst window and a daily ceiling so a single account
 * cannot loop vector ANN queries to pin Firestore compute. Throws
 * `resource-exhausted` when either bound is hit.
 */
export async function checkKnowledgeSearchRateLimit(uid: string): Promise<void> {
  await incrementCallableRateLimitsAtomically(uid, ["knowledge_search_burst", "knowledge_search_daily"]);
}

/**
 * Per-user rate limit for the agent notification reply callable
 * (`submitAgentNotificationReply`). Enforces both a short burst window and a
 * daily ceiling so a single account cannot flood the reply queue. Throws
 * `resource-exhausted` when either bound is hit.
 */
export async function checkAgentNotificationReplyRateLimit(uid: string): Promise<void> {
  await incrementCallableRateLimitsAtomically(uid, [
    "agent_notification_reply_burst",
    "agent_notification_reply_daily",
  ]);
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
export const RATE_LIMITED_PUBLIC_HTTP_ENDPOINTS: ReadonlyArray<PublicHttpEndpointName> = Object.freeze([
  "burnBarHermesGateway",
  "healthCheck",
  "healthLive",
  "healthReady",
  "latestRouterRundown",
  "issueWindowsAppCheckChallenge",
  "mintLinuxAppCheckToken",
  "mintWindowsAppCheckToken",
  "pollCliLink",
  "startCliLink",
]);

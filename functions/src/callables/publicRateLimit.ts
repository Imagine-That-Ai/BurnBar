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
  | "issueLinuxAppCheckChallenge"
  | "issueWindowsAppCheckChallenge"
  | "mintLinuxAppCheckToken"
  | "mintWindowsAppCheckToken"
  | "pollCliLink"
  | "registerLinuxAppCheckDevice"
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
  // Authenticated pre-App-Check bootstrap. Keep enrollment and challenge
  // issuance independently bounded so one flow cannot starve the other.
  issueLinuxAppCheckChallenge: { windowSeconds: 3600, maxAttempts: 20 },
  issueWindowsAppCheckChallenge: { windowSeconds: 3600, maxAttempts: 40 },
  // Device-attestation token mint: Linux/Windows AppCheck bootstrap. 20/hour
  // per IP — same posture as startCliLink since each mints a session-scoped token.
  mintLinuxAppCheckToken: { windowSeconds: 3600, maxAttempts: 20 },
  mintWindowsAppCheckToken: { windowSeconds: 3600, maxAttempts: 20 },
  pollCliLink: { windowSeconds: 60, maxAttempts: 60 },
  registerLinuxAppCheckDevice: { windowSeconds: 3600, maxAttempts: 20 },
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

// Public BurnBench assistant (`benchAssistant` callable): unauthenticated
// website traffic, and each answer bills input tokens to the owner's
// OpenRouter budget. There is no uid to key on, so the limit follows the
// client IP; a short burst window plus a daily ceiling keeps a single source
// from looping answers to drain that budget while leaving normal browsing
// unthrottled. Mirrors the hosted-Insights burst + daily pair shape.
type BenchAssistantRateLimitAction = "bench_assistant_burst" | "bench_assistant_daily";

const BENCH_ASSISTANT_LIMITS: Record<BenchAssistantRateLimitAction, { windowSeconds: number; maxAttempts: number }> = {
  bench_assistant_burst: { windowSeconds: 60, maxAttempts: 10 },
  bench_assistant_daily: { windowSeconds: 86_400, maxAttempts: 60 },
};

// Public BurnBench Arena vote (`arenaVote` callable): website traffic writing
// append-only human-judgment votes that feed published model ratings.
//
// KEYED ON uid, NOT IP — and that is load-bearing, not stylistic.
// `arenaVote` DOES require Firebase Auth (see the `assertAuth` /
// `unauthenticated` throw at the top of the handler in `arenaVote.ts`), so a
// uid is always available. An earlier version of this comment claimed "there
// is no uid to key on"; that was simply wrong, and it justified an IP-keyed
// limit that cannot work on this deployment in either configuration:
//   - with Express `trust proxy` ON, `req.ip` is the leftmost X-Forwarded-For
//     entry, which the caller writes — so every IP bucket is one header away
//     from being a fresh bucket, i.e. a no-op;
//   - with `trust proxy` OFF, `req.ip` is the Google front end, so ALL
//     internet traffic collapses into ONE bucket and a 120/day ceiling
//     throttles every voter on earth.
// Ballot-box stuffing is the abuse to bound: a single identity must not be
// able to dominate the pairwise-vote distribution, so the daily ceiling is a
// small multiple of what a genuine human voter plausibly casts in a day.
type ArenaVoteRateLimitAction = "arena_vote_burst" | "arena_vote_daily" | "arena_vote_ip_burst" | "arena_vote_ip_daily";

const ARENA_VOTE_LIMITS: Record<ArenaVoteRateLimitAction, { windowSeconds: number; maxAttempts: number }> = {
  // Primary, per-uid. One account, this many judgments.
  arena_vote_burst: { windowSeconds: 60, maxAttempts: 12 },
  arena_vote_daily: { windowSeconds: 86_400, maxAttempts: 120 },
  // SECONDARY ONLY, and only when a client IP can actually be attributed (see
  // `attributableClientIp`). Deliberately far looser than the per-uid bound: a
  // single NAT/VPN egress can legitimately carry many distinct voters, so this
  // must never be the bound a real person hits. It exists to blunt one host
  // driving a farm of throwaway accounts, nothing more.
  arena_vote_ip_burst: { windowSeconds: 60, maxAttempts: 120 },
  arena_vote_ip_daily: { windowSeconds: 86_400, maxAttempts: 2_000 },
};

// Public BurnBench Arena matchup serving (`arenaMatchup` callable): read-only,
// with OPTIONAL auth (browse freely, sign in only to vote) plus one small
// serve-ticket write that binds the served orientation server-side.
//
// Keyed on uid when the caller is signed in, else on an attributable client IP
// when the deployment can produce one. When neither exists the request falls
// back to a GLOBAL CAPACITY GUARD — named as such because a shared bucket is
// exactly what it is. The previous code applied the per-client ceilings
// (30/min, 600/day) to that shared bucket, which is an availability bug: it
// caps the whole internet at 600 matchup serves a day. The capacity guard is
// therefore sized against total service cost, not against one caller's
// behaviour, and `maxInstances` remains the real backstop.
type ArenaMatchupRateLimitAction =
  | "arena_matchup_burst"
  | "arena_matchup_daily"
  | "arena_matchup_global_burst"
  | "arena_matchup_global_daily";

const ARENA_MATCHUP_LIMITS: Record<ArenaMatchupRateLimitAction, { windowSeconds: number; maxAttempts: number }> = {
  arena_matchup_burst: { windowSeconds: 60, maxAttempts: 30 },
  arena_matchup_daily: { windowSeconds: 86_400, maxAttempts: 600 },
  arena_matchup_global_burst: { windowSeconds: 60, maxAttempts: 600 },
  arena_matchup_global_daily: { windowSeconds: 86_400, maxAttempts: 100_000 },
};

function rateLimitDocId(keyMaterial: string, action: string): string {
  const hash = createHash("sha256").update(`${keyMaterial}:${action}`).digest("hex");
  return `${action}_${hash.slice(0, 40)}`;
}

/** Shape of the raw HTTP request the callable runtime hands to a limiter. */
type RateLimitRequestLike = {
  headers?: Record<string, unknown>;
  ip?: string;
  socket?: { remoteAddress?: string };
};

/**
 * Best-effort client IP, for SECONDARY defence-in-depth limits only.
 *
 * Never use this as a primary key. `req.ip` is deliberately not consulted:
 * behind the Google front end it is either the caller-written leftmost
 * X-Forwarded-For entry (a one-header bypass) or the front end's own address
 * (one bucket for the whole internet). Both make an IP-keyed control useless
 * or actively harmful, so this helper reads the forwarded chain directly and
 * fails CLOSED — returning `undefined` rather than a guess — unless the
 * deployment has explicitly declared a trusted proxy chain via
 * `OPENBURNBAR_TRUST_X_FORWARDED_FOR=1`.
 *
 * When trusted, the client address is the SECOND-FROM-RIGHT hop: the Google
 * load balancer appends its own address last and preserves whatever the caller
 * sent to the left of the address it observed. Every entry left of that is
 * attacker-controlled and must never be keyed on. A chain with fewer than two
 * hops cannot be disambiguated from a forged one, so it yields `undefined`.
 */
function attributableClientIp(req: RateLimitRequestLike | undefined): string | undefined {
  if (process.env.OPENBURNBAR_TRUST_X_FORWARDED_FOR !== "1") return undefined;
  const forwarded = req?.headers?.["x-forwarded-for"];
  const raw = Array.isArray(forwarded) ? forwarded.join(",") : forwarded;
  if (typeof raw !== "string") return undefined;
  const hops = raw
    .split(",")
    .map((hop) => hop.trim())
    .filter((hop) => hop.length > 0 && hop.length <= 64);
  if (hops.length < 2) return undefined;
  return hops[hops.length - 2];
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
 * Per-IP rate limit for the public BurnBench assistant callable
 * (`benchAssistant`). Enforces both a short burst window and a daily ceiling
 * in a single transaction so a single source cannot loop calls to drain the
 * owner's OpenRouter budget. Falls back to a constant "unknown-ip" bucket
 * when the platform supplies no client IP. Throws `resource-exhausted` when
 * either bound is hit.
 */
export async function checkBenchAssistantRateLimit(req: {
  headers?: Record<string, unknown>;
  ip?: string;
  socket?: { remoteAddress?: string };
}): Promise<void> {
  const ip = clientIpFromHttpRequest(req);
  const keyMaterial = ip === "unknown" ? "unknown-ip" : ip;
  await incrementRateLimitsAtomically([
    {
      docId: rateLimitDocId(keyMaterial, "bench_assistant_burst"),
      action: "bench_assistant_burst",
      limit: BENCH_ASSISTANT_LIMITS.bench_assistant_burst,
    },
    {
      docId: rateLimitDocId(keyMaterial, "bench_assistant_daily"),
      action: "bench_assistant_daily",
      limit: BENCH_ASSISTANT_LIMITS.bench_assistant_daily,
    },
  ]);
}

/**
 * Per-uid rate limit for the Arena vote callable (`arenaVote`).
 *
 * The uid key is the whole point. Arena votes produce published model ratings,
 * so the bound that matters is "how much can ONE identity move the numbers" —
 * and only Firebase Auth gives us an identity that a caller cannot mint for
 * free with a header. `arenaVote` requires auth, so the uid is always present;
 * passing it is not optional and there is no IP-only fallback path.
 *
 * The optional `req` adds a SECONDARY per-IP bound, and only when
 * `attributableClientIp` can actually attribute one (it will not, unless the
 * deployment declares a trusted proxy chain). It is deliberately much looser
 * than the per-uid bound so it can never be the ceiling a real voter hits, and
 * it is not relied upon: if it is absent the per-uid bound still holds.
 *
 * Throws `resource-exhausted` when any bound is hit. Both uid bounds are
 * incremented in one transaction so a rejection cannot half-advance a window.
 */
export async function checkArenaVoteRateLimit(uid: string, req?: RateLimitRequestLike): Promise<void> {
  if (typeof uid !== "string" || uid.length === 0) {
    // Fail closed. A missing uid here means a caller reached the limiter
    // without authenticating, which the callable is supposed to make
    // impossible; degrading to an unkeyed bucket would silently unbound votes.
    throw new HttpsError("unauthenticated", "Request must be authenticated with Firebase Auth.");
  }
  await incrementRateLimitsAtomically([
    {
      docId: rateLimitDocId(uid, "arena_vote_burst"),
      action: "arena_vote_burst",
      limit: ARENA_VOTE_LIMITS.arena_vote_burst,
    },
    {
      docId: rateLimitDocId(uid, "arena_vote_daily"),
      action: "arena_vote_daily",
      limit: ARENA_VOTE_LIMITS.arena_vote_daily,
    },
  ]);

  const ip = attributableClientIp(req);
  if (ip === undefined) return;
  await incrementRateLimitsAtomically([
    {
      docId: rateLimitDocId(ip, "arena_vote_ip_burst"),
      action: "arena_vote_ip_burst",
      limit: ARENA_VOTE_LIMITS.arena_vote_ip_burst,
    },
    {
      docId: rateLimitDocId(ip, "arena_vote_ip_daily"),
      action: "arena_vote_ip_daily",
      limit: ARENA_VOTE_LIMITS.arena_vote_ip_daily,
    },
  ]);
}

/**
 * Rate limit for the Arena matchup-serving callable (`arenaMatchup`).
 *
 * Auth is optional here (the vote page lets anyone browse and only gates the
 * vote itself), so the key degrades in order of how much it can actually
 * attribute:
 *   1. `uid` — a real identity, when the browser is signed in;
 *   2. an attributable client IP — only when the deployment declares a trusted
 *      proxy chain, and still only a coarse signal;
 *   3. a global capacity guard — an explicitly shared bucket, sized against
 *      total service cost. It is NOT a per-client limit and must never be
 *      given per-client ceilings, because every anonymous visitor on earth
 *      shares it.
 * Throws `resource-exhausted` when a bound is hit.
 */
export async function checkArenaMatchupRateLimit(options: { uid?: string; req?: RateLimitRequestLike }): Promise<void> {
  const keyMaterial =
    typeof options.uid === "string" && options.uid.length > 0
      ? `uid:${options.uid}`
      : attributableClientIp(options.req);
  if (keyMaterial !== undefined) {
    await incrementRateLimitsAtomically([
      {
        docId: rateLimitDocId(keyMaterial, "arena_matchup_burst"),
        action: "arena_matchup_burst",
        limit: ARENA_MATCHUP_LIMITS.arena_matchup_burst,
      },
      {
        docId: rateLimitDocId(keyMaterial, "arena_matchup_daily"),
        action: "arena_matchup_daily",
        limit: ARENA_MATCHUP_LIMITS.arena_matchup_daily,
      },
    ]);
    return;
  }
  await incrementRateLimitsAtomically([
    {
      docId: rateLimitDocId("global", "arena_matchup_global_burst"),
      action: "arena_matchup_global_burst",
      limit: ARENA_MATCHUP_LIMITS.arena_matchup_global_burst,
    },
    {
      docId: rateLimitDocId("global", "arena_matchup_global_daily"),
      action: "arena_matchup_global_daily",
      limit: ARENA_MATCHUP_LIMITS.arena_matchup_global_daily,
    },
  ]);
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
  "issueLinuxAppCheckChallenge",
  "issueWindowsAppCheckChallenge",
  "mintLinuxAppCheckToken",
  "mintWindowsAppCheckToken",
  "pollCliLink",
  "registerLinuxAppCheckDevice",
  "startCliLink",
]);

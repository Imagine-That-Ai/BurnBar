/**
 * @fileoverview BurnBar-hosted Intelligence Brief fallback callable.
 *
 * Runs when the client has no user-owned LLM route reachable. Proxies
 * the user's Intelligence Brief question through OpenRouter (default
 * model: MiniMax 2.7 / `minimax/minimax-m2`) so the OpenRouter API key
 * never lands on a client device.
 *
 * Wire contract (request):
 *   data: {
 *     schemaVersion: 1,
 *     platform: "macOS" | "iOS" | "iPadOS" | "android",
 *     modelID: string,       // hint only; server picks the real slug
 *     instruction: "answerFollowUp" | "generateReport",
 *     promptPreview: string,
 *     request: InsightAnalysisRequest  // full client payload
 *   }
 *
 * Wire contract (response):
 *   {
 *     envelope: string,           // raw LLM-emitted JSON the client
 *                                 // hydrates via its model-decoder.
 *                                 // Always a valid JSON document with
 *                                 // the keys executiveSummary, findings,
 *                                 // anomalies, recommendations,
 *                                 // missionCandidates, generatedWidgets,
 *                                 // followUpQuestions, citations.
 *     providerKey: "burnbar-hosted",
 *     modelSlug: string,          // OpenRouter slug actually used
 *     modelDisplayName: string,   // user-facing label
 *     egressTier: "hosted",
 *     tokenUsage: {
 *       providerKey, modelID, inputTokens, outputTokens,
 *       estimatedCostUSD, startedAt, completedAt
 *     },
 *     ranAt: ISO8601 string
 *   }
 *
 * Why a separate `envelope` field instead of a full `InsightAnalysisResult`:
 * the client's `InsightCitation` / `InsightAnalysisModelDecoder`
 * already know how to hydrate the LLM's structured-output shape
 * (incl. id/label-only citations). Returning the LLM envelope reuses
 * that decoder verbatim across Swift and Kotlin instead of forcing
 * the server to mimic the platform-specific `InsightCitation.Kind`
 * Codable encoding (it's an enum-with-associated-values on Swift +
 * a sealed class on Kotlin — easy to get subtly wrong server-side).
 *
 * Auth contract:
 *   - App Check: REQUIRED (the OpenRouter key is owner-funded, so we
 *     refuse non-attested clients to keep abuse off the budget).
 *   - Firebase Auth: OPTIONAL — anonymous BurnBar installs may use
 *     the hosted fallback before signing in.
 *
 * Secrets:
 *   - `OPENROUTER_API_KEY` (defineSecret)
 *
 * Override knobs (env / runtime config):
 *   - `INSIGHTS_HOSTED_FALLBACK_MODEL` — OpenRouter model slug.
 *     Default `minimax/minimax-m2` (user-facing "MiniMax 2.7").
 *   - `INSIGHTS_HOSTED_FALLBACK_BASE_URL` — OpenRouter base URL.
 *     Default `https://openrouter.ai/api/v1`.
 *   - `INSIGHTS_HOSTED_FALLBACK_DISPLAY_NAME` — user-facing label
 *     shown in the brief eyebrow. Default
 *     `MiniMax 2.7 · BurnBar Hosted`.
 */

import { getFirestore } from "firebase-admin/firestore";
import { defineSecret } from "firebase-functions/params";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "./config.js";
import { assertAppCheck, assertAuth } from "./auth.js";

/**
 * Lazy Firestore handle. The module is loaded inside the deployed
 * Cloud Functions runtime where `initializeApp()` ran via
 * `index.ts`, so the default app is always available by the time
 * any request reaches this callable.
 */
let dbInstance: ReturnType<typeof getFirestore> | undefined;
function db(): ReturnType<typeof getFirestore> {
  if (!dbInstance) dbInstance = getFirestore();
  return dbInstance;
}

// ---------------------------------------------------------------------------
// Secrets / runtime config
// ---------------------------------------------------------------------------

const OPENROUTER_API_KEY = defineSecret("OPENROUTER_API_KEY");

const DEFAULT_MODEL_SLUG = "minimax/minimax-m2";
const DEFAULT_BASE_URL = "https://openrouter.ai/api/v1";
const DEFAULT_DISPLAY_NAME = "MiniMax 2.7 · BurnBar Hosted";
/**
 * Per-million-token USD pricing for the default model. Lets us
 * stamp `estimatedCostUSD` on the audit + token-usage record so the
 * client's "what did this turn cost?" reporting works without
 * round-tripping through OpenRouter's separate cost-report endpoint.
 * Sourced 2026-05-14 from
 * https://openrouter.ai/minimax/minimax-m2 — keep in sync when the
 * pricing page changes.
 */
const DEFAULT_INPUT_PRICE_PER_MTOKEN = 0.255;
const DEFAULT_OUTPUT_PRICE_PER_MTOKEN = 1.0;

// Stable error-code marker for the client. The Firebase callable
// error envelope ships `details` as a JSON-safe payload alongside
// `code` + `message`, so the Swift / Kotlin adapters can route on
// this without string-matching the human-readable message.
const SUBSCRIPTION_REQUIRED_DETAIL = {
  code: "subscription-required",
} as const;

// Allowed top-level keys in the LLM envelope. Anything extra is dropped
// before the response is sent back to the client — keeps the wire
// contract narrow and prevents accidental token leakage in nested
// fields the model may decide to emit.
const ALLOWED_ENVELOPE_KEYS = new Set<string>([
  "executiveSummary",
  "findings",
  "anomalies",
  "recommendations",
  "missionCandidates",
  "generatedWidgets",
  "followUpQuestions",
  "citations",
]);

// ---------------------------------------------------------------------------
// Wire contracts
// ---------------------------------------------------------------------------

interface HostedAnswerRequest {
  schemaVersion?: number;
  platform?: string;
  modelID?: string;
  instruction?: string;
  promptPreview?: string;
  /**
   * Full `InsightAnalysisRequest` shape (Swift / Kotlin source of
   * truth). We accept it as `unknown` here and probe the fields we
   * actually use so a forward-compatible client doesn't get rejected
   * if it adds new fields.
   */
  request?: unknown;
}

interface OpenRouterMessage {
  role: "system" | "user" | "assistant";
  content: string;
}

interface OpenRouterChoice {
  index: number;
  message?: OpenRouterMessage;
  finish_reason?: string | null;
}

interface OpenRouterResponse {
  id?: string;
  model?: string;
  choices?: OpenRouterChoice[];
  usage?: {
    prompt_tokens?: number;
    completion_tokens?: number;
    total_tokens?: number;
  };
  error?: { message?: string; code?: string | number };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function isoNow(): string {
  return new Date().toISOString();
}

function asObject(value: unknown): Record<string, unknown> | null {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }
  return value as Record<string, unknown>;
}

function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function asString(value: unknown, fallback = ""): string {
  return typeof value === "string" ? value : fallback;
}

function clip(value: string, max: number): string {
  if (value.length <= max) return value;
  return `${value.slice(0, max - 1)}…`;
}

// ---------------------------------------------------------------------------
// Prompt assembly
// ---------------------------------------------------------------------------

/**
 * Build the compact, privacy-bounded digest summary the model sees.
 *
 * The model never receives raw transcripts, raw provider keys, or
 * full session message bodies — `InsightAnalysisRequest` is built on
 * the client to honor that contract. Here we just trim the obvious
 * shapes so the OpenRouter call doesn't blow the context budget.
 */
function digestSummaryFor(request: Record<string, unknown> | null): string {
  if (!request) return "(no digest provided)";
  const context = asObject(request.context);
  if (!context) return "(no digest provided)";
  const digest = asObject(context.digest);
  if (!digest) return "(no digest provided)";
  const totals = asObject(digest.totals) ?? {};
  const providers = asArray(digest.providers).slice(0, 6);
  const models = asArray(digest.models).slice(0, 6);
  const projects = asArray(digest.projects).slice(0, 6);
  const anomalies = asArray(digest.anomalies).slice(0, 6);
  const quotas = asArray(digest.quotaSnapshots).slice(0, 6);
  const daily = asArray(digest.daily).slice(0, 14);

  return JSON.stringify(
    {
      totals,
      providers,
      models,
      projects,
      anomalies,
      quotaSnapshots: quotas,
      daily,
      contentHash: asString(digest.contentHash),
    },
    null,
    0
  );
}

function systemPromptText(): string {
  return [
    "You are the BurnBar Intelligence Brief analyst.",
    "Answer the user's question using ONLY the privacy-bounded digest the host attaches below.",
    "If a fact isn't in the digest, say what's missing and recommend the next mission instead of guessing.",
    "Tone: concise, opinionated, data-grounded. No filler. Cite numbers from the digest verbatim where possible.",
    "Return STRICT JSON matching the InsightAnalysisResult envelope described in the user message — no markdown fences, no prose preamble.",
  ].join(" ");
}

function userPromptText(args: {
  prompt: string;
  digestSummary: string;
}): string {
  return [
    `User question:\n${args.prompt}`,
    "",
    "Digest (compact JSON — do not echo verbatim):",
    args.digestSummary,
    "",
    "Return ONLY a JSON object with these keys: executiveSummary (string ≤ 800), findings (≤ 6), anomalies (≤ 4), recommendations (≤ 4), missionCandidates (≤ 4), generatedWidgets (≤ 2), followUpQuestions (≤ 4), citations (≤ 6).",
    "Each finding must include: title, whyItMatters, evidence (array of {id, label}), confidence (low|medium|high), severity (info|low|medium|high|critical), recommendedAction.",
    "Each anomaly must include: title, detail, score (number), evidence (array of {id, label}), confidence.",
    "Each recommendation must include: title, rationale, recommendedAction, evidence, confidence, severity.",
    "Each missionCandidate must include: title, summary, lens (accretion|diligence|techDebt|routing|quota|focus), priority (low|medium|high|critical), confidence, expectedImpact, effort (small|medium|large), acceptanceCriteria (1-4 strings), evidence (array of {id, label}).",
    "Each generatedWidget must include: kind (one of: kpiTile, timeSeriesLine, barRanking, donut, narrative, recommendation, quotaPulse), title, reason, citations.",
    "Each followUpQuestion: { question, rationale? }.",
    "Each citation entry: { id, label }. Use the same id strings across findings/evidence/citations so the client can de-duplicate.",
  ].join("\n");
}

// ---------------------------------------------------------------------------
// OpenRouter call
// ---------------------------------------------------------------------------

async function callOpenRouter(args: {
  apiKey: string;
  baseURL: string;
  modelSlug: string;
  systemPrompt: string;
  userPrompt: string;
  signal: AbortSignal;
}): Promise<{ content: string; raw: OpenRouterResponse }> {
  const body = {
    model: args.modelSlug,
    messages: [
      { role: "system", content: args.systemPrompt },
      { role: "user", content: args.userPrompt },
    ],
    response_format: { type: "json_object" },
    temperature: 0.2,
    max_tokens: 1400,
  };

  let response: Response;
  try {
    response = await fetch(`${args.baseURL.replace(/\/$/, "")}/chat/completions`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${args.apiKey}`,
        "Content-Type": "application/json",
        // OpenRouter recommends advertising the calling app for routing logs.
        "HTTP-Referer": "https://burnbar.ai",
        "X-Title": "BurnBar Intelligence Brief",
      },
      body: JSON.stringify(body),
      signal: args.signal,
    });
  } catch (error) {
    throw new HttpsError(
      "unavailable",
      `OpenRouter transport failed: ${(error as Error).message}`
    );
  }

  const text = await response.text();
  let parsed: OpenRouterResponse;
  try {
    parsed = JSON.parse(text) as OpenRouterResponse;
  } catch {
    throw new HttpsError(
      "internal",
      `OpenRouter returned non-JSON (${response.status}): ${clip(text, 240)}`
    );
  }

  if (!response.ok) {
    const message = parsed.error?.message ?? `HTTP ${response.status}`;
    // Map a couple of obvious upstream conditions to better error codes
    // so the client's banner can disclose recovery action precisely.
    if (response.status === 401 || response.status === 403) {
      throw new HttpsError("permission-denied", `OpenRouter rejected: ${message}`);
    }
    if (response.status === 429) {
      throw new HttpsError("resource-exhausted", `OpenRouter rate-limited: ${message}`);
    }
    if (response.status === 404) {
      // Most commonly: the configured model slug doesn't exist anymore.
      throw new HttpsError("failed-precondition", `OpenRouter rejected: ${message}`);
    }
    throw new HttpsError("unavailable", `OpenRouter rejected: ${message}`);
  }

  const content = parsed.choices?.[0]?.message?.content ?? "";
  if (!content) {
    throw new HttpsError("internal", "OpenRouter response had no message content.");
  }
  return { content, raw: parsed };
}

// ---------------------------------------------------------------------------
// Envelope sanitization
// ---------------------------------------------------------------------------

/**
 * Validate the LLM's JSON, trim it to allowed keys, and re-stringify
 * so the client sees a clean envelope. Throws an HttpsError if the
 * model produced something we can't safely forward — the client
 * orchestrator will treat that as a hosted-route failure and
 * degrade to local rules with disclosure.
 */
function sanitizeEnvelope(rawContent: string): string {
  let trimmed = rawContent.trim();
  // Some providers wrap structured-output JSON in ```json fences even
  // when asked not to. Strip them defensively.
  if (trimmed.startsWith("```")) {
    const newlineAt = trimmed.indexOf("\n");
    if (newlineAt > 0) trimmed = trimmed.slice(newlineAt + 1);
    if (trimmed.endsWith("```")) trimmed = trimmed.slice(0, -3);
    trimmed = trimmed.trim();
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(trimmed);
  } catch (error) {
    throw new HttpsError(
      "internal",
      `Model emitted invalid JSON: ${(error as Error).message}`
    );
  }
  const obj = asObject(parsed);
  if (!obj) {
    throw new HttpsError("internal", "Model emitted a non-object JSON document.");
  }
  if (typeof obj.executiveSummary !== "string" || obj.executiveSummary.trim().length === 0) {
    throw new HttpsError(
      "internal",
      "Model envelope missing executiveSummary — refusing to forward an empty brief."
    );
  }

  const clean: Record<string, unknown> = {};
  for (const key of Object.keys(obj)) {
    if (ALLOWED_ENVELOPE_KEYS.has(key)) {
      clean[key] = obj[key];
    }
  }
  // Ensure the array fields exist so the client decoders don't have to
  // null-coalesce in five places.
  for (const key of ALLOWED_ENVELOPE_KEYS) {
    if (key === "executiveSummary") continue;
    if (!(key in clean) || !Array.isArray(clean[key])) {
      clean[key] = [];
    }
  }
  return JSON.stringify(clean);
}

// ---------------------------------------------------------------------------
// Callable
// ---------------------------------------------------------------------------

export const insightsHostedAnswer = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
    timeoutSeconds: 60,
    secrets: [OPENROUTER_API_KEY],
  },
  async (
    request: CallableRequest<HostedAnswerRequest>
  ): Promise<Record<string, unknown>> => {
    assertAppCheck(request);
    // The hosted Intelligence Brief is paywalled behind the same
    // BurnBar Pro SKU as Hosted Quota Sync. Anonymous + free-tier
    // callers see `permission-denied` with `{ code: "subscription-required" }`
    // so the iOS / macOS / Android adapters can route directly to
    // the upgrade CTA without round-tripping a generic error.
    assertAuth(request);
    const uid = request.auth!.uid;
    await assertActiveBurnBarProEntitlement(uid);

    const startedAtISO = isoNow();
    const data = request.data ?? {};
    const rawRequest = asObject(data.request);
    const instruction = asString(data.instruction, "answerFollowUp");
    const promptPreview = asString(data.promptPreview);
    const promptFromBody = asString(rawRequest?.prompt);
    const prompt = (promptFromBody || promptPreview).trim();

    if (!prompt) {
      throw new HttpsError(
        "invalid-argument",
        "Hosted fallback requires a non-empty prompt in request.prompt or promptPreview."
      );
    }
    if (instruction !== "answerFollowUp" && instruction !== "generateReport") {
      // We don't gate the request, but we *do* limit hosted-budget
      // burn to actual Q&A turns. The Swift/Kotlin orchestrator
      // already gates on `.answerFollowUp` before reaching here;
      // surface the invariant explicitly so future callers can't
      // accidentally burn hosted quota on canvas refreshes.
      throw new HttpsError(
        "failed-precondition",
        `Hosted fallback only handles answerFollowUp / generateReport (got "${instruction}").`
      );
    }

    const apiKey = OPENROUTER_API_KEY.value().trim();
    if (!apiKey) {
      throw new HttpsError(
        "failed-precondition",
        "Hosted fallback is unconfigured: OPENROUTER_API_KEY secret is empty."
      );
    }

    const modelSlug =
      (process.env.INSIGHTS_HOSTED_FALLBACK_MODEL ?? "").trim() || DEFAULT_MODEL_SLUG;
    const baseURL =
      (process.env.INSIGHTS_HOSTED_FALLBACK_BASE_URL ?? "").trim() || DEFAULT_BASE_URL;
    const modelDisplayName =
      (process.env.INSIGHTS_HOSTED_FALLBACK_DISPLAY_NAME ?? "").trim() ||
      DEFAULT_DISPLAY_NAME;

    const digestSummary = digestSummaryFor(rawRequest);
    const systemPrompt = systemPromptText();
    const userPrompt = userPromptText({ prompt, digestSummary });

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 45_000);
    let openRouterContent: string;
    let openRouterRaw: OpenRouterResponse;
    try {
      const result = await callOpenRouter({
        apiKey,
        baseURL,
        modelSlug,
        systemPrompt,
        userPrompt,
        signal: controller.signal,
      });
      openRouterContent = result.content;
      openRouterRaw = result.raw;
    } finally {
      clearTimeout(timer);
    }

    const envelope = sanitizeEnvelope(openRouterContent);
    const completedAtISO = isoNow();
    const inputTokens = openRouterRaw.usage?.prompt_tokens ?? 0;
    const outputTokens = openRouterRaw.usage?.completion_tokens ?? 0;
    const inputPrice = parseNumericEnv(
      "INSIGHTS_HOSTED_FALLBACK_INPUT_PRICE_PER_MTOKEN",
      DEFAULT_INPUT_PRICE_PER_MTOKEN
    );
    const outputPrice = parseNumericEnv(
      "INSIGHTS_HOSTED_FALLBACK_OUTPUT_PRICE_PER_MTOKEN",
      DEFAULT_OUTPUT_PRICE_PER_MTOKEN
    );
    const estimatedCostUSD =
      (inputTokens / 1_000_000) * inputPrice +
      (outputTokens / 1_000_000) * outputPrice;

    return {
      envelope,
      providerKey: "burnbar-hosted",
      modelSlug,
      modelDisplayName,
      egressTier: "hosted",
      tokenUsage: {
        providerKey: "burnbar-hosted",
        modelID: modelSlug,
        inputTokens,
        outputTokens,
        estimatedCostUSD,
        startedAt: startedAtISO,
        completedAt: completedAtISO,
      },
      ranAt: completedAtISO,
    };
  }
);

/**
 * Parse an env var as a non-negative float. Returns `fallback` when
 * the env var is missing, empty, or unparseable so a typo in the
 * override doesn't quietly zero out the cost estimate.
 */
function parseNumericEnv(name: string, fallback: number): number {
  const raw = (process.env[name] ?? "").trim();
  if (!raw) return fallback;
  const parsed = Number.parseFloat(raw);
  if (!Number.isFinite(parsed) || parsed < 0) return fallback;
  return parsed;
}

/**
 * Reject callers without an active BurnBar Pro subscription.
 *
 * Mirrors `assertActiveHostedQuotaEntitlement` in `index.ts` (same
 * Firestore doc, same SKU) but ships a stable
 * `{ code: "subscription-required", productID }` detail payload so
 * the client adapter can map the rejection to the upgrade CTA
 * without string-matching the human-readable message.
 *
 * The expiry comparison rounds `expiresAt` to ms via Date.parse —
 * matches every other Pro-gated callable on the project.
 */
async function assertActiveBurnBarProEntitlement(uid: string): Promise<void> {
  const productID = getConfig().burnBarProProductID;
  const [proSnap, hostedSnap] = await Promise.all([
    db().doc(`users/${uid}/entitlements/burnbar_pro`).get(),
    db().doc(`users/${uid}/entitlements/hosted_quota_sync`).get(),
  ]);
  const failWithSubscriptionRequired = (message: string): never => {
    throw new HttpsError("permission-denied", message, {
      ...SUBSCRIPTION_REQUIRED_DETAIL,
      productID,
    });
  };
  if (!proSnap.exists && !hostedSnap.exists) {
    failWithSubscriptionRequired(
      "Active BurnBar Pro subscription required for hosted Intelligence Brief answers."
    );
  }
  if (!isActiveBurnBarProEntitlement(proSnap.data()) && !isActiveBurnBarProEntitlement(hostedSnap.data())) {
    failWithSubscriptionRequired(
      "BurnBar Pro subscription is inactive — restore your purchase or resubscribe to use hosted Intelligence Brief answers."
    );
  }
}

function isActiveBurnBarProEntitlement(raw: Record<string, unknown> | undefined): boolean {
  if (!raw || raw.active !== true) return false;
  const productID = typeof raw.productID === "string" ? raw.productID : "";
  if (
    productID !== getConfig().hostedQuotaProductID &&
    productID !== getConfig().burnBarProProductID &&
    productID !== getConfig().googlePlaySubscriptionProductID
  ) {
    return false;
  }
  const expireAt = raw.expireAt;
  if (expireAt && typeof expireAt === "object") {
    const candidate = expireAt as { toMillis?: () => number };
    if (typeof candidate.toMillis === "function") {
      return candidate.toMillis() > Date.now();
    }
  }
  const expiresAt = raw.expiresAt ? Date.parse(String(raw.expiresAt)) : 0;
  return Number.isFinite(expiresAt) && expiresAt > Date.now();
}

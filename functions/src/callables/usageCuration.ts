/**
 * @fileoverview curateUsageMemoryBatch — the metered, entitlement-gated gateway
 * for cloud usage-memory curation inference.
 *
 * BurnBar pays for this inference, so the flow is strictly:
 *   kill flag → entitlement (lane-scoped) → validate → estimate → RESERVE →
 *   OpenRouter (CoreWeave-pinned; see usageCuration/openrouterClient.ts) →
 *   SETTLE actual → respond.
 *
 * Lanes:
 *   - text        — any active Pro (pro | pro_max | ultra); deepseek-v4-flash.
 *   - multimodal  — ACTIVE Pro Max (or Ultra, which mirrors Pro Max) ONLY;
 *                   minimax-m3 with OpenAI-format image parts.
 *
 * The server kill flag `usage_curation_enabled` (Remote Config, default true)
 * is read the same way cloudProAllowance loads its config; when false the
 * callable throws failed-precondition before any entitlement read or spend.
 *
 * Candidate text is DATA, never prompt: the batch is serialized inside an
 * untrusted-data fence appended after the frozen, versioned prompt prefix
 * (usageCuration/prompt.ts).
 */

import { randomBytes } from "node:crypto";

import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "../config.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { db } from "../adminRuntime.js";
import { errorMessage, isRecord } from "../guards.js";
import { logWarn, wrapCallableHandler } from "../logging.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import {
  assertActiveBurnBarCloudProEntitlement,
  assertActiveBurnBarProEntitlement,
  boundedTrimmedString,
  isActiveBurnBarCloudProEntitlement,
  isActiveBurnBarUltraEntitlement,
  requiredIdentifier,
  requireRecordArray,
  BURNBAR_PRO_MAX_ENTITLEMENT_ID,
  BURNBAR_ULTRA_ENTITLEMENT_ID,
} from "./shared.js";
import {
  loadUsageCurationLimitsConfig,
  nextMonthlyResetISO,
  usageCurationLaneLimits,
  type UsageCurationLane,
  type UsageCurationTier,
} from "../usageCuration/limits.js";
import {
  reserveUsageCurationTokens,
  settleUsageCurationTokens,
  type UsageCurationAllowanceCounters,
} from "../usageCuration/allowance.js";
import {
  callUsageCurationModel,
  requireUsageCurationApiKey,
  USAGE_CURATION_SECRETS,
  type UsageCurationContentPart,
  type UsageCurationModelResult,
  type UsageCurationModelUsage,
} from "../usageCuration/openrouterClient.js";
import {
  buildUsageCurationUserPrompt,
  USAGE_CURATION_PROMPT_PREFIX,
  USAGE_CURATION_PROMPT_VERSION,
  type UsageCurationCandidate,
} from "../usageCuration/prompt.js";

const MAX_BATCH_CANDIDATES = 25;
const MAX_CANDIDATE_TEXT_BYTES = 4 * 1024; // 4 KiB per candidate
const MAX_BATCH_IMAGES = 4;
const MAX_IMAGE_REF_CHARS = 1_048_576; // ~0.75 MiB of base64 payload per image
const MAX_OUTPUT_TOKENS = 512;
/** Flat per-image token estimate reserved up front (settled to actual after the call). */
const IMAGE_TOKEN_ESTIMATE = 1_024;

const MEMORY_KINDS = new Set(["fact", "decision", "preference", "pattern", "entity"]);

interface CurateUsageMemoryBatchRequest {
  lane?: unknown;
  candidates?: unknown;
  requestId?: unknown;
}

function requireLane(raw: unknown): UsageCurationLane {
  const value = boundedTrimmedString(raw, "lane", 32, true);
  if (value === "text" || value === "multimodal") return value;
  throw new HttpsError("invalid-argument", "lane must be one of: text, multimodal.");
}

function requireImageRef(raw: unknown, fieldName: string): string {
  if (typeof raw !== "string" || raw.length === 0) {
    throw new HttpsError("invalid-argument", `${fieldName} must be a non-empty string.`);
  }
  if (raw.length > MAX_IMAGE_REF_CHARS) {
    throw new HttpsError("invalid-argument", `${fieldName} exceeds the ${MAX_IMAGE_REF_CHARS} character image limit.`);
  }
  if (!/^data:image\/[a-z0-9.+-]+;base64,/iu.test(raw) && !/^https:\/\//iu.test(raw)) {
    throw new HttpsError("invalid-argument", `${fieldName} must be a data:image base64 URI or an https URL.`);
  }
  return raw;
}

/** Validate the structured candidate batch. Rejects anything outside the contract. */
function requireCandidates(raw: unknown, lane: UsageCurationLane): UsageCurationCandidate[] {
  const records = requireRecordArray(raw, "candidates", MAX_BATCH_CANDIDATES);
  if (records.length === 0) {
    throw new HttpsError("invalid-argument", "candidates must contain at least one item.");
  }
  let totalImages = 0;
  const seenIds = new Set<string>();
  const candidates = records.map((record, index) => {
    const id = boundedTrimmedString(record.id, `candidates[${index}].id`, 128, true);
    if (seenIds.has(id)) {
      throw new HttpsError("invalid-argument", `candidates[${index}].id duplicates an earlier candidate id.`);
    }
    seenIds.add(id);
    const sourceKind = boundedTrimmedString(record.sourceKind, `candidates[${index}].sourceKind`, 64, true);
    const text = typeof record.text === "string" ? record.text : undefined;
    if (text === undefined || text.length === 0) {
      throw new HttpsError("invalid-argument", `candidates[${index}].text is required.`);
    }
    if (Buffer.byteLength(text, "utf8") > MAX_CANDIDATE_TEXT_BYTES) {
      throw new HttpsError(
        "invalid-argument",
        `candidates[${index}].text exceeds the ${MAX_CANDIDATE_TEXT_BYTES}-byte limit.`,
      );
    }
    let imageRefs: string[] | undefined;
    if (record.imageRefs !== undefined && record.imageRefs !== null) {
      if (lane !== "multimodal") {
        throw new HttpsError("invalid-argument", `candidates[${index}].imageRefs requires the multimodal lane.`);
      }
      if (!Array.isArray(record.imageRefs)) {
        throw new HttpsError("invalid-argument", `candidates[${index}].imageRefs must be an array.`);
      }
      imageRefs = record.imageRefs.map((ref, imageIndex) =>
        requireImageRef(ref, `candidates[${index}].imageRefs[${imageIndex}]`),
      );
      totalImages += imageRefs.length;
      if (totalImages > MAX_BATCH_IMAGES) {
        throw new HttpsError("invalid-argument", `A batch can attach at most ${MAX_BATCH_IMAGES} images in total.`);
      }
    }
    return { id, sourceKind, text, ...(imageRefs && imageRefs.length > 0 ? { imageRefs } : {}) };
  });
  return candidates;
}

/**
 * Resolve the member's limits tier. Mirrors resolvePensieveTier: the ultra /
 * pro_max docs are written solely by the entitlement reconciler (single
 * writer), so trusting active + expiry here is safe. The lane entitlement
 * assertion has already passed before this runs — the tier only scales limits.
 */
async function resolveUsageCurationTier(uid: string): Promise<UsageCurationTier> {
  const [ultraSnap, proMaxSnap] = await Promise.all([
    db.doc(`users/${uid}/entitlements/${BURNBAR_ULTRA_ENTITLEMENT_ID}`).get(),
    db.doc(`users/${uid}/entitlements/${BURNBAR_PRO_MAX_ENTITLEMENT_ID}`).get(),
  ]);
  if (isActiveBurnBarUltraEntitlement(ultraSnap.data())) return "ultra";
  if (isActiveBurnBarCloudProEntitlement(proMaxSnap.data())) return "pro_max";
  return "pro";
}

/** chars/4 heuristic + flat image estimates + the reserved output budget. */
function estimateTokens(promptChars: number, imageCount: number): number {
  return Math.ceil(promptChars / 4) + imageCount * IMAGE_TOKEN_ESTIMATE + MAX_OUTPUT_TOKENS;
}

function boundedStringArray(raw: unknown, maxItems: number, maxLength: number): string[] {
  if (!Array.isArray(raw)) return [];
  return raw
    .filter((item): item is string => typeof item === "string" && item.trim().length > 0)
    .slice(0, maxItems)
    .map((item) => item.trim().slice(0, maxLength));
}

interface CuratedMemory {
  text: string;
  kind: string;
  confidence: number;
  keywords: string[];
  tags: string[];
  context: string;
  candidateId: string;
}

/**
 * Parse + sanitize the model's JSON into the A-MEM atomic-note contract.
 * Malformed entries are dropped (the model output is untrusted); a wholly
 * unparseable document is an internal error — the spend is already settled.
 */
function sanitizeCuratedMemories(rawContent: string, candidateIds: Set<string>): CuratedMemory[] {
  let trimmed = rawContent.trim();
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
    throw new HttpsError("internal", `Curation model emitted invalid JSON: ${errorMessage(error)}`);
  }
  if (!isRecord(parsed) || !Array.isArray(parsed.memories)) {
    throw new HttpsError("internal", "Curation model output is missing the memories array.");
  }
  const memories: CuratedMemory[] = [];
  for (const raw of parsed.memories) {
    if (!isRecord(raw)) continue;
    const text = typeof raw.text === "string" ? raw.text.trim().slice(0, 500) : "";
    const candidateId = typeof raw.candidateId === "string" ? raw.candidateId : "";
    if (!text || !candidateIds.has(candidateId)) continue;
    const kind = typeof raw.kind === "string" && MEMORY_KINDS.has(raw.kind) ? raw.kind : "fact";
    const confidence =
      typeof raw.confidence === "number" && Number.isFinite(raw.confidence)
        ? Math.min(1, Math.max(0, raw.confidence))
        : 0.5;
    memories.push({
      text,
      kind,
      confidence,
      keywords: boundedStringArray(raw.keywords, 8, 64),
      tags: boundedStringArray(raw.tags, 5, 64),
      context: typeof raw.context === "string" ? raw.context.trim().slice(0, 300) : "",
      candidateId,
    });
  }
  return memories;
}

/** Build the OpenAI-format user content: fenced text part + attached image parts. */
function userContentFor(candidates: UsageCurationCandidate[]): {
  content: string | UsageCurationContentPart[];
  promptChars: number;
  imageCount: number;
} {
  const userPrompt = buildUsageCurationUserPrompt(candidates);
  const images = candidates.flatMap((candidate) => candidate.imageRefs ?? []);
  const promptChars = USAGE_CURATION_PROMPT_PREFIX.length + userPrompt.length;
  if (images.length === 0) {
    return { content: userPrompt, promptChars, imageCount: 0 };
  }
  return {
    content: [
      { type: "text", text: userPrompt },
      ...images.map((url): UsageCurationContentPart => ({ type: "image_url", image_url: { url } })),
    ],
    promptChars,
    imageCount: images.length,
  };
}

export const curateUsageMemoryBatch = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
    timeoutSeconds: 120,
    memory: "512MiB",
    secrets: USAGE_CURATION_SECRETS,
  },
  wrapCallableHandler("curateUsageMemoryBatch", async (request: CallableRequest<CurateUsageMemoryBatchRequest>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in to curate usage memories.");
    enforceAuthAndAppCheck(request, uid);

    // Server kill flag first: one Remote Config publish stops all curation
    // spend before any entitlement read or reservation.
    const config = await loadUsageCurationLimitsConfig();
    if (!config.usageCurationEnabled) {
      throw new HttpsError("failed-precondition", "Usage curation is temporarily disabled by the server.");
    }

    const lane = requireLane(request.data.lane);
    const candidates = requireCandidates(request.data.candidates, lane);
    const requestId = boundedTrimmedString(request.data.requestId, "requestId", 128, false);

    // Lane entitlement gate: multimodal requires ACTIVE Pro Max (Ultra
    // mirrors Pro Max); text accepts ANY active Pro tier.
    if (lane === "multimodal") {
      await assertActiveBurnBarCloudProEntitlement(uid);
    } else {
      await assertActiveBurnBarProEntitlement(uid);
    }
    const tier = await resolveUsageCurationTier(uid);
    const limits = usageCurationLaneLimits(lane, tier, config);
    if (!limits) {
      // Defense in depth — the entitlement assertion above already rejects
      // pro-tier multimodal callers.
      throw new HttpsError("permission-denied", "The multimodal curation lane requires BurnBar Pro Max.");
    }

    // Secret preflight before reserving so a misconfigured deploy never
    // burns allowance.
    const apiKey = requireUsageCurationApiKey();

    const { content, promptChars, imageCount } = userContentFor(candidates);
    const estimatedTokens = estimateTokens(promptChars, imageCount);
    const reservationId = requiredIdentifier(
      `curate_${lane}_${requestId ?? randomBytes(16).toString("hex")}`,
      "requestId",
    );

    const reservation = await reserveUsageCurationTokens({
      uid,
      lane,
      reservationId,
      estimatedTokens,
      limits,
    });
    if (reservation.idempotent && reservation.reservationStatus === "settled") {
      // A settled reservation already paid for exactly one cloud call.
      // Refusing the replay (rather than skipping the reserve) keeps every
      // OpenRouter call backed by a live reservation.
      throw new HttpsError("already-exists", "requestId was already completed; use a new requestId to curate again.", {
        lane,
        requestId,
      });
    }

    let modelText: string;
    let usage: UsageCurationModelUsage;
    try {
      const result: UsageCurationModelResult = await callUsageCurationModel({
        apiKey,
        lane,
        systemPrompt: USAGE_CURATION_PROMPT_PREFIX,
        userContent: content,
        maxOutputTokens: MAX_OUTPUT_TOKENS,
      });
      modelText = result.text;
      usage = result.usage;
    } catch (error) {
      // The call failed — release the estimate so an outage cannot strand
      // allowance. Best-effort: a settle failure must not mask the real error.
      try {
        await settleUsageCurationTokens({
          uid,
          lane,
          reservationId,
          monthKey: reservation.monthKey,
          actualTokens: 0,
        });
      } catch (settleError) {
        logWarn({
          event: "usage_curation.settle_release_failed",
          reservationId,
          error: errorMessage(settleError),
        });
      }
      throw error;
    }

    const settlement = await settleUsageCurationTokens({
      uid,
      lane,
      reservationId,
      monthKey: reservation.monthKey,
      actualTokens: usage.inputTokens + usage.outputTokens,
    });

    const results = sanitizeCuratedMemories(modelText, new Set(candidates.map((candidate) => candidate.id)));
    return {
      results,
      promptVersion: USAGE_CURATION_PROMPT_VERSION,
      usage: {
        promptTokens: usage.inputTokens,
        outputTokens: usage.outputTokens,
        cachedTokens: usage.cachedTokens ?? 0,
        lane,
      },
      allowance: allowanceSummary(settlement, tier, config),
    };
  }),
);

/** Remaining-monthly view for the response. A tier without multimodal access reports 0. */
function allowanceSummary(
  counters: UsageCurationAllowanceCounters,
  tier: UsageCurationTier,
  config: Awaited<ReturnType<typeof loadUsageCurationLimitsConfig>>,
): { textRemainingMonth: number; multimodalRemainingMonth: number; resetsAt: string } {
  const textLimits = usageCurationLaneLimits("text", tier, config);
  const multimodalLimits = usageCurationLaneLimits("multimodal", tier, config);
  return {
    textRemainingMonth: textLimits ? Math.max(0, textLimits.monthlyTokens - counters.textTokensUsed) : 0,
    multimodalRemainingMonth: multimodalLimits
      ? Math.max(0, multimodalLimits.monthlyTokens - counters.multimodalTokensUsed)
      : 0,
    resetsAt: nextMonthlyResetISO(new Date()),
  };
}

/** Pure helpers exposed for unit testing. */
export const __testing__ = {
  MAX_BATCH_CANDIDATES,
  MAX_CANDIDATE_TEXT_BYTES,
  MAX_BATCH_IMAGES,
  MAX_OUTPUT_TOKENS,
  IMAGE_TOKEN_ESTIMATE,
  estimateTokens,
  requireLane,
  requireCandidates,
  sanitizeCuratedMemories,
  resolveUsageCurationTier,
  userContentFor,
};

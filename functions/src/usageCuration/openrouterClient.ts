/**
 * @fileoverview The ONLY cloud LLM client for usage-memory curation.
 *
 * One gateway (OpenRouter), one provider (CoreWeave), two models:
 *   - text lane        → deepseek/deepseek-v4-flash
 *   - multimodal lane  → minimax/minimax-m3 (image content parts, OpenAI format)
 *
 * PRIVACY INVARIANT — this is a PRODUCT / PRIVACY decision, not a performance
 * choice: curation batches contain the member's own page/session text, and that
 * client data must never reach Chinese-operated inference providers. Both
 * models have Chinese-operated first-party hosts on OpenRouter, so EVERY
 * request pins `provider.order` to CoreWeave (US), forbids fallbacks
 * (`allow_fallbacks: false` — an outage means the call FAILS rather than
 * silently rerouting to another host), denies provider-side data collection
 * (`data_collection: "deny"`), and requires zero-data-retention endpoints
 * (`zdr: true`). Do not "optimize" this pin away.
 *
 * The API key lives in the `OPENROUTER_API_KEY` Functions secret (defineSecret,
 * same secret the hosted Intelligence Brief uses) and is never logged; callers
 * must list {@link USAGE_CURATION_SECRETS} in their runtime options.
 */

import { defineSecret } from "firebase-functions/params";
import { HttpsError } from "firebase-functions/v2/https";

import { errorMessage, isRecord } from "../guards.js";
import { modelInferenceFetch } from "../resilienceHelpers.js";
import type { UsageCurationLane } from "./limits.js";

const OPENROUTER_API_KEY = defineSecret("OPENROUTER_API_KEY");

/** Spread into the callable's `secrets` option so the key is mounted at runtime. */
export const USAGE_CURATION_SECRETS = [OPENROUTER_API_KEY];

export const USAGE_CURATION_TEXT_MODEL = "deepseek/deepseek-v4-flash";
export const USAGE_CURATION_MULTIMODAL_MODEL = "minimax/minimax-m3";

const OPENROUTER_CHAT_COMPLETIONS_URL = "https://openrouter.ai/api/v1/chat/completions";
/**
 * Matches modelInferencePolicy's 60 s cap (resilience.ts). The AbortController
 * below is what actually cancels the socket; the policy timeout is the
 * belt-and-suspenders race. Multimodal completions legitimately exceed the
 * generic 20 s external-API timeout, which is why this call must NOT go
 * through resilientFetch.
 */
const REQUEST_TIMEOUT_MS = 60_000;

/**
 * The CoreWeave pin (see the privacy invariant in the file header). Attached
 * verbatim to EVERY request this module sends.
 */
const OPENROUTER_PROVIDER_PIN = Object.freeze({
  order: ["CoreWeave"],
  allow_fallbacks: false,
  data_collection: "deny",
  zdr: true,
});

function usageCurationModelForLane(lane: UsageCurationLane): string {
  return lane === "text" ? USAGE_CURATION_TEXT_MODEL : USAGE_CURATION_MULTIMODAL_MODEL;
}

/** OpenAI-format user content part (text or image_url). */
export type UsageCurationContentPart =
  | { type: "text"; text: string }
  | { type: "image_url"; image_url: { url: string } };

export interface UsageCurationModelUsage {
  inputTokens: number;
  outputTokens: number;
  cachedTokens?: number;
}

export interface UsageCurationModelResult {
  text: string;
  usage: UsageCurationModelUsage;
}

function clip(value: string, max: number): string {
  return value.length <= max ? value : `${value.slice(0, max - 1)}…`;
}

function nonNegativeInteger(raw: unknown): number | undefined {
  return typeof raw === "number" && Number.isFinite(raw) && raw >= 0 ? Math.floor(raw) : undefined;
}

/**
 * Parse the usage block. Missing or malformed token counts are an upstream
 * ERROR, not a zero: settling a paid completion to zero tokens would leave the
 * spend unmetered (a provider usage-reporting regression = free inference).
 * Failure policy: the thrown error discards the completion, the callable's
 * failure path releases the reservation, and the regression is loud in logs
 * instead of silently unbilled.
 */
function usageFromResponse(raw: Record<string, unknown>): UsageCurationModelUsage {
  const usage = isRecord(raw.usage) ? raw.usage : undefined;
  const inputTokens = usage ? nonNegativeInteger(usage.prompt_tokens) : undefined;
  const outputTokens = usage ? nonNegativeInteger(usage.completion_tokens) : undefined;
  if (usage === undefined || inputTokens === undefined || outputTokens === undefined) {
    throw new HttpsError("internal", "OpenRouter response omitted usage metering; refusing an unmetered completion.");
  }
  const details = isRecord(usage.prompt_tokens_details) ? usage.prompt_tokens_details : {};
  const cachedTokens = nonNegativeInteger(details.cached_tokens);
  return {
    inputTokens,
    outputTokens,
    ...(cachedTokens !== undefined ? { cachedTokens } : {}),
  };
}

function contentFromResponse(raw: Record<string, unknown>): string | undefined {
  const choices = Array.isArray(raw.choices) ? raw.choices : [];
  const first = choices[0];
  if (!isRecord(first)) return undefined;
  const message = isRecord(first.message) ? first.message : undefined;
  return typeof message?.content === "string" ? message.content : undefined;
}

function upstreamErrorMessage(raw: Record<string, unknown>, status: number): string {
  const error = isRecord(raw.error) ? raw.error : undefined;
  return typeof error?.message === "string" ? error.message : `HTTP ${status}`;
}

/**
 * Resolve the OpenRouter API key. Kept out of every log line and error message;
 * an empty secret is a deploy-time misconfiguration surfaced as
 * failed-precondition before any allowance is reserved.
 */
export function requireUsageCurationApiKey(): string {
  const apiKey = OPENROUTER_API_KEY.value().trim();
  if (!apiKey) {
    throw new HttpsError("failed-precondition", "Usage curation is unconfigured: OPENROUTER_API_KEY secret is empty.");
  }
  return apiKey;
}

/**
 * POST one chat completion for a curation batch. Returns the normalized
 * assistant text + usage block. Throws HttpsError on transport/upstream
 * failure with codes mirroring insightsHostedAnswer's mapping.
 */
export async function callUsageCurationModel(args: {
  apiKey: string;
  lane: UsageCurationLane;
  systemPrompt: string;
  userContent: string | UsageCurationContentPart[];
  maxOutputTokens: number;
}): Promise<UsageCurationModelResult> {
  const body = {
    model: usageCurationModelForLane(args.lane),
    messages: [
      { role: "system", content: args.systemPrompt },
      { role: "user", content: args.userContent },
    ],
    // Privacy invariant: CoreWeave (US) pin on EVERY request — see file header.
    provider: OPENROUTER_PROVIDER_PIN,
    response_format: { type: "json_object" },
    temperature: 0.2,
    max_tokens: args.maxOutputTokens,
    usage: { include: true },
  };

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  let response: Response;
  try {
    response = await modelInferenceFetch(
      "openrouter",
      "usage_curation.openrouter.chat",
      OPENROUTER_CHAT_COMPLETIONS_URL,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${args.apiKey}`,
          "Content-Type": "application/json",
          // OpenRouter recommends advertising the calling app for routing logs.
          "HTTP-Referer": "https://burnbar.ai",
          "X-Title": "BurnBar Usage Curation",
        },
        body: JSON.stringify(body),
        signal: controller.signal,
      },
    );
  } catch (error) {
    throw new HttpsError("unavailable", `OpenRouter transport failed: ${errorMessage(error)}`);
  } finally {
    clearTimeout(timer);
  }

  const text = await response.text();
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new HttpsError("internal", `OpenRouter returned non-JSON (${response.status}): ${clip(text, 240)}`);
  }
  if (!isRecord(parsed)) {
    throw new HttpsError("internal", `OpenRouter returned non-JSON (${response.status}): ${clip(text, 240)}`);
  }

  if (!response.ok) {
    const message = upstreamErrorMessage(parsed, response.status);
    if (response.status === 401 || response.status === 403) {
      throw new HttpsError("permission-denied", `OpenRouter rejected: ${message}`);
    }
    if (response.status === 429) {
      throw new HttpsError("resource-exhausted", `OpenRouter rate-limited: ${message}`);
    }
    if (response.status === 404) {
      // Most commonly: the pinned model/provider pair is unavailable.
      throw new HttpsError("failed-precondition", `OpenRouter rejected: ${message}`);
    }
    throw new HttpsError("unavailable", `OpenRouter rejected: ${message}`);
  }

  const content = contentFromResponse(parsed);
  if (!content) {
    throw new HttpsError("internal", "OpenRouter response had no message content.");
  }
  return { text: content, usage: usageFromResponse(parsed) };
}

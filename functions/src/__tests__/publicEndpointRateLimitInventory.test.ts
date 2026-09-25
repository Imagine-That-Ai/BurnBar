/**
 * Public endpoint rate-limit inventory.
 *
 * Every public/unauthenticated Functions endpoint must have either:
 *   - a declared product-layer rate limit, or
 *   - a provider-signature requirement (webhooks), or
 *   - an explicit documented low-cost exemption.
 *
 * Closes codex-gpt-5 FINDING-005 / kimi FINDING-012.
 */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

import { endpointAuthorizationCatalog } from "../security/endpointAuthorizationCatalog.generated.js";
import { RATE_LIMITED_PUBLIC_HTTP_ENDPOINTS } from "../../../packages/functions-shared/src/callables/publicRateLimit.js";

// Tests run from functions/; module paths are repo-relative (3.5 codebases).
const REPO_DIR = resolve(process.cwd(), "..");

const RATE_LIMITED_NAMES = new Set(RATE_LIMITED_PUBLIC_HTTP_ENDPOINTS);

// Provider webhooks authenticate via signature, so product-layer rate limits are
// not required for abuse resistance (the provider is the only legitimate caller).
const SIGNATURE_PROTECTED_WEBHOOKS = new Set([
  "appStoreServerNotificationsV2",
  "googlePlayDeveloperNotifications", // Google Play RTDN delivered via Pub/Sub (IAM-authenticated)
  "onKnowledgeRepoPush",
  "stripeBurnBarProWebhook",
]);

// Low-cost public endpoints that are read-only / cache-backed and explicitly
// exempted from product-layer rate limits. Any addition here must be justified
// in the catalog's publicJustification field.
const DOCUMENTED_EXEMPTIONS = new Set<string>([
  // healthLive: liveness performs no I/O (static identity + timestamps) and
  // must answer 200 whenever the process is alive — the limiter is
  // Firestore-backed, so limiting liveness would 429 under monitor bursts and
  // 500 during a Firestore outage, both misread as DOWN. Contract: health.ts
  // LIVENESS CONTRACT. Catalog justification: "Read-only health endpoints
  // expose no user objects" (endpointAuthorizationCatalog.generated.ts).
  "healthLive",
]);

describe("public endpoint rate-limit inventory", () => {
  const publicEntries = endpointAuthorizationCatalog.filter(
    (e) =>
      e.publicJustification != null ||
      e.trigger === "http" ||
      e.trigger === "provider-webhook",
  );

  it("every public endpoint has a control", () => {
    const uncontrolled: string[] = [];
    for (const entry of publicEntries) {
      const name = entry.exportedName;
      const hasRateLimit = RATE_LIMITED_NAMES.has(name as (typeof RATE_LIMITED_PUBLIC_HTTP_ENDPOINTS)[number]);
      const isWebhook = SIGNATURE_PROTECTED_WEBHOOKS.has(name);
      const isExempt = DOCUMENTED_EXEMPTIONS.has(name);
      if (!hasRateLimit && !isWebhook && !isExempt) {
        uncontrolled.push(name);
      }
    }
    expect(uncontrolled).toEqual([]);
  });

  it("every declared public rate limit maps to a real catalog endpoint", () => {
    const catalogNames = new Set(endpointAuthorizationCatalog.map((e) => e.exportedName));
    for (const name of RATE_LIMITED_PUBLIC_HTTP_ENDPOINTS) {
      expect(catalogNames.has(name)).toBe(true);
    }
  });
});

describe("per-uid rate limit call-site coverage", () => {
  /**
   * onCall callables that must enforce a per-uid (or per-IP, for the public
   * benchAssistant) rate limit. Each entry asserts the callable imports its
   * checker from publicRateLimit.js AND actually calls it, so a regression
   * that drops the wiring fails the build rather than silently re-opening
   * the abuse vector.
   */
  const CALLABLES_REQUIRING_UID_RATE_LIMIT: Array<{ exportedName: string; checker: string; module: string }> = [
    { exportedName: "triggerVoIPCall", checker: "checkVoIPCallRateLimit", module: "functions-media/src/domains/push/voipPush.ts" },
    { exportedName: "searchKnowledge", checker: "checkKnowledgeSearchRateLimit", module: "functions-sync/src/domains/knowledge/knowledgeSearch.ts" },
    { exportedName: "listKnowledgeChunks", checker: "checkKnowledgeSearchRateLimit", module: "functions-sync/src/domains/knowledge/knowledgeSearch.ts" },
    { exportedName: "submitAgentNotificationReply", checker: "checkAgentNotificationReplyRateLimit", module: "functions-sync/src/domains/notify/agentNotifications.ts" },
    { exportedName: "insightsHostedAnswer", checker: "checkHostedInsightsAnswerRateLimit", module: "functions-sync/src/domains/search/insightsHostedAnswer.ts" },
    { exportedName: "benchAssistant", checker: "checkBenchAssistantRateLimit", module: "functions-sync/src/domains/telemetry/benchAssistant.ts" },
  ];

  for (const entry of CALLABLES_REQUIRING_UID_RATE_LIMIT) {
    it(`${entry.exportedName} imports and calls ${entry.checker}`, () => {
      const source = readFileSync(resolve(REPO_DIR, entry.module), "utf8");

      const importPattern = new RegExp(`import.*${entry.checker}.*from.*publicRateLimit`);
      expect(importPattern.test(source), `${entry.module} must import ${entry.checker} from publicRateLimit`).toBe(true);

      const callPattern = new RegExp(`(?:await\\s+)?${entry.checker}\\(`);
      expect(callPattern.test(source), `${entry.module} must call ${entry.checker}`).toBe(true);
    });
  }
});

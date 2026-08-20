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
import { RATE_LIMITED_PUBLIC_HTTP_ENDPOINTS } from "../callables/publicRateLimit.js";

// Tests run from functions/, so the source tree is at src/.
const SRC_DIR = resolve(process.cwd(), "src");

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
const DOCUMENTED_EXEMPTIONS = new Set<string>([]);

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
    { exportedName: "triggerVoIPCall", checker: "checkVoIPCallRateLimit", module: "callables/voipPush.ts" },
    { exportedName: "searchKnowledge", checker: "checkKnowledgeSearchRateLimit", module: "callables/knowledgeSearch.ts" },
    { exportedName: "submitAgentNotificationReply", checker: "checkAgentNotificationReplyRateLimit", module: "callables/agentNotifications.ts" },
    { exportedName: "insightsHostedAnswer", checker: "checkHostedInsightsAnswerRateLimit", module: "insightsHostedAnswer.ts" },
    { exportedName: "benchAssistant", checker: "checkBenchAssistantRateLimit", module: "benchAssistant.ts" },
  ];

  for (const entry of CALLABLES_REQUIRING_UID_RATE_LIMIT) {
    it(`${entry.exportedName} imports and calls ${entry.checker}`, () => {
      const source = readFileSync(resolve(SRC_DIR, entry.module), "utf8");

      const importPattern = new RegExp(`import.*${entry.checker}.*from.*publicRateLimit`);
      expect(importPattern.test(source), `${entry.module} must import ${entry.checker} from publicRateLimit`).toBe(true);

      const callPattern = new RegExp(`(?:await\\s+)?${entry.checker}\\(`);
      expect(callPattern.test(source), `${entry.module} must call ${entry.checker}`).toBe(true);
    });
  }
});

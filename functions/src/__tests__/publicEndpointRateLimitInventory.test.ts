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
import { describe, expect, it } from "vitest";

import { endpointAuthorizationCatalog } from "../security/endpointAuthorizationCatalog.generated.js";
import { RATE_LIMITED_PUBLIC_HTTP_ENDPOINTS } from "../../../packages/functions-shared/src/callables/publicRateLimit.js";

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

// Per-uid callable limiter call-site coverage moved to the registry-driven
// inventory in callableRatePolicyInventory.test.ts — CALLABLE_RATE_POLICIES
// handler-enforced entries are asserted to import AND call their checker.

import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import {
  DATA_DOMAIN_USAGE,
  resolveDataTierFromEntitlements,
  wandParallelMaxForDataTier,
} from "../callables/dataDomainUsage.js";

type DataTier = Parameters<typeof wandParallelMaxForDataTier>[0];
type RegistryDomain = { id: string; byteSource?: string | null; countSource?: string | null };

const registry: { domains: RegistryDomain[] } = JSON.parse(
  readFileSync(join(process.cwd(), "..", "packages", "data-domains", "registry.json"), "utf8"),
);

const FAR_FUTURE = "2999-01-01T00:00:00.000Z";

function activeEntitlement(productID: string, expiresAt: string = FAR_FUTURE): Record<string, unknown> {
  return { active: true, productID, expiresAt };
}

function expectCap(tier: DataTier, cap: number): void {
  expect(wandParallelMaxForDataTier(tier)).toBe(cap);
}

describe("data domain usage Wand tier limits", () => {
  it("maps the public Wand ladder without collapsing Cloud to Free", () => {
    expectCap("free", 1);
    expectCap("cloud", 3);
    expectCap("pro", 8);
    expectCap("ultra", 16);
  });

  it("resolves entitlements top-down into the Wand parallel cap ladder", () => {
    expect(resolveDataTierFromEntitlements({})).toBe("free");

    expect(
      resolveDataTierFromEntitlements({
        cloud: activeEntitlement("com.openburnbar.hostedQuotaSync.cloud.monthly"),
      }),
    ).toBe("cloud");

    expect(
      resolveDataTierFromEntitlements({
        legacyCloud: activeEntitlement("com.openburnbar.pro.monthly"),
      }),
    ).toBe("cloud");

    expect(
      resolveDataTierFromEntitlements({
        cloudPro: activeEntitlement("com.openburnbar.proMax.v2.monthly"),
        cloud: activeEntitlement("com.openburnbar.hostedQuotaSync.cloud.monthly"),
      }),
    ).toBe("pro");

    expect(
      resolveDataTierFromEntitlements({
        ultra: activeEntitlement("com.openburnbar.ultra.monthly"),
        cloudPro: activeEntitlement("com.openburnbar.proMax.v2.monthly"),
        cloud: activeEntitlement("com.openburnbar.hostedQuotaSync.cloud.monthly"),
      }),
    ).toBe("ultra");
  });
});

describe("data domain usage byte-source coverage", () => {
  it("counts bytes for every registry domain that declares a byte source", () => {
    for (const domain of registry.domains) {
      const source = DATA_DOMAIN_USAGE[domain.id];
      expect(source, `${domain.id} missing from DATA_DOMAIN_USAGE`).toBeTruthy();
      if (domain.byteSource) {
        expect(source.byteCollection, `${domain.id} byteCollection`).toBeTruthy();
        expect(source.byteField, `${domain.id} byteField`).toBeTruthy();
      }
    }
  });

  it("declares a count source exactly where the registry declares one", () => {
    // PR 4 review L7. `count: 0` for a domain nobody can count reads as "you
    // have none of this", which for a member with hundreds of team facts is
    // false. The registry's `countSource` is the authority for whether a
    // per-user count exists at all, and the server map must agree with it —
    // otherwise the `countable` flag on the response is decorative.
    for (const domain of registry.domains) {
      const source = DATA_DOMAIN_USAGE[domain.id];
      expect(source, `${domain.id} missing from DATA_DOMAIN_USAGE`).toBeTruthy();
      if (domain.countSource) {
        expect(source.countCollection, `${domain.id} countCollection`).toBeTruthy();
      } else {
        expect(source.countCollection, `${domain.id} must not claim a count source`).toBeUndefined();
      }
    }
    // Team memory is the case the flag exists for: its facts live in a shared
    // tenant at `team_memory_facts/{teamId}/facts`, not under `users/{uid}/`.
    expect(DATA_DOMAIN_USAGE.team_pensieve.countCollection).toBeUndefined();
  });

  it("uses the stored manifest byte fields for searchable logs and media", () => {
    expect(DATA_DOMAIN_USAGE.session_logs).toMatchObject({
      countCollection: "cloud_search_documents",
      byteCollection: "cloud_search_documents",
      byteField: "byteCount",
    });
    expect(DATA_DOMAIN_USAGE.media).toMatchObject({
      countCollection: "media_attachment_manifests",
      byteCollection: "media_attachment_manifests",
      byteField: "size",
    });
  });
});

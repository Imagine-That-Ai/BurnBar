/**
 * Asserts the console binds to the canonical data-domain registry (synced from
 * packages/data-domains) rather than a hand-authored list, and that the tier/
 * retention metadata covers every domain in the registry.
 */
import { describe, it, expect } from "vitest";
import { DATA_DOMAINS, DATA_DOMAIN_IDS, TIER_META, RETENTION_META, dataDomain } from "../lib/domains";

describe("data-domain registry binding", () => {
  it("ships the 12 canonical domains", () => {
    expect(DATA_DOMAINS.length).toBe(12);
    expect(DATA_DOMAIN_IDS).toContain("pensieve");
    expect(DATA_DOMAIN_IDS).toContain("audit_timeline");
  });

  it("has tier copy for every encryption tier used", () => {
    for (const d of DATA_DOMAINS) {
      expect(TIER_META[d.encryptionTier]).toBeDefined();
      expect(TIER_META[d.encryptionTier].whoReads.length).toBeGreaterThan(0);
    }
  });

  it("has retention copy for every retention value used", () => {
    for (const d of DATA_DOMAINS) {
      expect(RETENTION_META[d.retention]).toBeDefined();
    }
  });

  it("resolves a domain by id", () => {
    expect(dataDomain("pensieve")?.title).toBe("Pensieve Knowledge");
    expect(dataDomain("nope")).toBeUndefined();
  });
});

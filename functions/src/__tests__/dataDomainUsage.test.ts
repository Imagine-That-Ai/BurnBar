import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { Timestamp } from "firebase-admin/firestore";

import { DATA_DOMAIN_USAGE, summarizeCloudProfile } from "../callables/dataDomainUsage.js";

// vitest runs from the functions/ package root; the registry is a sibling package.
const registry = JSON.parse(
  readFileSync(join(process.cwd(), "..", "packages", "data-domains", "registry.json"), "utf8"),
);
const registryIds = registry.domains.map((d: { id: string }) => d.id).sort();

describe("DATA_DOMAIN_USAGE ⇄ data-domain registry", () => {
  it("covers exactly the registry's domain ids (no drift)", () => {
    const usageIds = Object.keys(DATA_DOMAIN_USAGE).sort();
    expect(usageIds).toEqual(registryIds);
  });

  it("every usage source names a non-empty count collection", () => {
    for (const [id, src] of Object.entries(DATA_DOMAIN_USAGE)) {
      expect(src.countCollection, `${id} countCollection`).toBeTruthy();
      if (src.byteCollection) expect(src.byteField, `${id} byteField`).toBeTruthy();
    }
  });

  it("the count collection is one of the domain's registered firestorePaths", () => {
    for (const [id, src] of Object.entries(DATA_DOMAIN_USAGE)) {
      const domain = registry.domains.find((d: { id: string }) => d.id === id);
      const tops = domain.firestorePaths.map((p: string) => p.split("/")[0]);
      // audit_timeline's unified_audit_log is a planned collection (registered in the domain too)
      expect(tops, `${id} count collection ${src.countCollection} not in firestorePaths`).toContain(
        src.countCollection,
      );
    }
  });
});

describe("summarizeCloudProfile", () => {
  it("reports a missing profile when the Mac has not published one", () => {
    expect(summarizeCloudProfile(undefined)).toEqual({ state: "missing" });
    expect(summarizeCloudProfile(null)).toEqual({ state: "missing" });
  });

  it("returns only safe profile summary fields", () => {
    const updatedAt = Timestamp.fromDate(new Date("2026-06-03T03:45:00.000Z"));

    expect(
      summarizeCloudProfile({
        displayName: " Alberto ",
        avatarURL: "https://example.com/avatar.png",
        sourceDeviceId: " macbook-pro ",
        updatedAt,
        ignoredSecret: "never returned",
      }),
    ).toEqual({
      state: "published",
      displayName: "Alberto",
      avatarURL: "https://example.com/avatar.png",
      sourceDeviceId: "macbook-pro",
      updatedAt: "2026-06-03T03:45:00.000Z",
    });
  });
});

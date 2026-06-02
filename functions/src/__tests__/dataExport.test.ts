import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import { DATA_DOMAIN_PATHS } from "../callables/dataExport.js";
import { UNDELETABLE_DOMAINS } from "../callables/dataDeletion.js";

// vitest runs from the functions/ package root; the registry is a sibling package.
const registry = JSON.parse(
  readFileSync(join(process.cwd(), "..", "packages", "data-domains", "registry.json"), "utf8"),
) as {
  domains: Array<{
    id: string;
    encryptionTier: string;
    firestorePaths: string[];
    storagePaths: string[];
    actions: string[];
  }>;
};
const registryIds = registry.domains.map((d) => d.id).sort();

describe("DATA_DOMAIN_PATHS ⇄ data-domain registry (no drift)", () => {
  it("covers exactly the registry's domain ids", () => {
    expect(Object.keys(DATA_DOMAIN_PATHS).sort()).toEqual(registryIds);
  });

  it("encryptionTier matches the registry for every domain", () => {
    for (const domain of registry.domains) {
      expect(DATA_DOMAIN_PATHS[domain.id].encryptionTier, `${domain.id} tier`).toBe(domain.encryptionTier);
    }
  });

  it("firestoreCollections match the registry's firestorePaths top-level collections", () => {
    for (const domain of registry.domains) {
      const expected = domain.firestorePaths.map((p) => p.split("/")[0]).sort();
      const actual = [...DATA_DOMAIN_PATHS[domain.id].firestoreCollections].sort();
      expect(actual, `${domain.id} collections`).toEqual(expected);
    }
  });

  it("storagePrefixes are the prefix-before-wildcard of the registry's storagePaths", () => {
    for (const domain of registry.domains) {
      const expected = domain.storagePaths
        .map((p) => {
          const idx = p.indexOf("/{");
          const slash = p.indexOf("/**");
          const cut = [idx, slash].filter((n) => n >= 0).sort((a, b) => a - b)[0];
          return cut == null || cut < 0 ? p.replace(/\/$/, "") : p.slice(0, cut);
        })
        .sort();
      const actual = [...DATA_DOMAIN_PATHS[domain.id].storagePrefixes].sort();
      expect(actual, `${domain.id} storage prefixes`).toEqual(expected);
    }
  });
});

describe("deleteDomainData deletability gate", () => {
  it("every domain that exposes a registry `delete` action is deletable here", () => {
    for (const domain of registry.domains) {
      if (domain.actions.includes("delete")) {
        expect(UNDELETABLE_DOMAINS.has(domain.id), `${domain.id} should be deletable`).toBe(false);
      }
    }
  });

  it("every undeletable domain is a real registry domain", () => {
    for (const id of UNDELETABLE_DOMAINS) {
      expect(registryIds, `${id} is a registry domain`).toContain(id);
    }
  });

  it("domains without a `delete` action are blocked from generic deletion", () => {
    for (const domain of registry.domains) {
      if (!domain.actions.includes("delete")) {
        expect(UNDELETABLE_DOMAINS.has(domain.id), `${domain.id} should be undeletable`).toBe(true);
      }
    }
  });
});

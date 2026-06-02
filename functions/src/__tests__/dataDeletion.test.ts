import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import { UNDELETABLE_DOMAINS } from "../callables/dataDeletion.js";
import { DATA_DOMAIN_PATHS } from "../callables/dataExport.js";

const registry = JSON.parse(
  readFileSync(join(process.cwd(), "..", "packages", "data-domains", "registry.json"), "utf8"),
);
type RegDomain = { id: string; actions: string[] };
const domains: RegDomain[] = registry.domains;

describe("deleteDomainData ⇄ registry consistency", () => {
  it("a domain is scoped-deletable IFF it does NOT have a dedicated revoke flow (UNDELETABLE)", () => {
    // The honest contract: registry 'delete' action <=> deleteDomainData accepts it.
    for (const d of domains) {
      const hasDeleteAction = d.actions.includes("delete");
      const isUndeletable = UNDELETABLE_DOMAINS.has(d.id);
      expect(hasDeleteAction, `${d.id}: delete-action(${hasDeleteAction}) must be the inverse of undeletable(${isUndeletable})`).toBe(
        !isUndeletable,
      );
    }
  });

  it("every UNDELETABLE id is a real registry domain (no typos)", () => {
    const ids = new Set(domains.map((d) => d.id));
    for (const id of UNDELETABLE_DOMAINS) expect(ids.has(id), `UNDELETABLE has unknown domain ${id}`).toBe(true);
  });

  it("every registry domain is classified by DATA_DOMAIN_PATHS (deletable or refused)", () => {
    for (const d of domains) {
      expect(DATA_DOMAIN_PATHS[d.id], `${d.id} missing from DATA_DOMAIN_PATHS`).toBeTruthy();
    }
  });

  it("at least one domain is deletable and at least one is protected (sanity)", () => {
    const deletable = domains.filter((d) => !UNDELETABLE_DOMAINS.has(d.id));
    expect(deletable.length).toBeGreaterThan(0);
    expect(UNDELETABLE_DOMAINS.size).toBeGreaterThan(0);
  });
});

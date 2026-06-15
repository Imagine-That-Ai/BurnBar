import { describe, expect, it } from "vitest";

import { endpointAuthorizationMatrix } from "../security/endpointAuthorizationMatrix.js";

describe("endpoint authorization matrix", () => {
  it("has actionable authorization fields for every endpoint", () => {
    for (const entry of endpointAuthorizationMatrix) {
      expect(entry.trigger, entry.exportedName).toMatch(
        /^(callable|http|scheduled|firestore-trigger|provider-webhook)$/u,
      );
      expect(entry.authMethod.trim(), entry.exportedName).not.toEqual("");
      expect(entry.appCheck, entry.exportedName).toMatch(/^(required|not-applicable|not-required)$/u);
      expect(entry.tenantSource.trim(), entry.exportedName).not.toEqual("");
      expect(entry.ownershipCheck.trim(), entry.exportedName).not.toEqual("");
      expect(entry.bolaCoverage.length, entry.exportedName).toBeGreaterThan(0);
      if (entry.appCheck === "not-required" || entry.trigger === "provider-webhook") {
        expect(entry.publicJustification?.trim(), entry.exportedName).toBeTruthy();
      }
    }
  });

  it("has no duplicate exported names", () => {
    const names = endpointAuthorizationMatrix.map((entry) => entry.exportedName);
    const duplicates = names.filter((name, index) => names.indexOf(name) !== index);
    expect(duplicates).toEqual([]);
  });
});

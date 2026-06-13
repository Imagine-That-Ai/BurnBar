import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

import { endpointAuthorizationMatrix, endpointAuthorizationByName } from "../security/endpointAuthorizationMatrix.js";

function exportedFunctionNames(): string[] {
  const indexSource = readFileSync(resolve(__dirname, "../index.ts"), "utf8");
  const names: string[] = [];
  for (const match of indexSource.matchAll(/export\s+\{([\s\S]*?)\}\s+from\s+"[^"]+";/g)) {
    for (const part of match[1].split(",")) {
      const raw = part.trim();
      if (!raw) continue;
      names.push(raw.split(/\s+as\s+/u).pop()?.trim() ?? raw);
    }
  }
  return names.sort((left, right) => left.localeCompare(right));
}

describe("endpoint authorization matrix", () => {
  it("covers every exported Cloud Function from index.ts", () => {
    const exported = exportedFunctionNames();
    const matrixNames = endpointAuthorizationMatrix
      .map((entry) => entry.exportedName)
      .sort((left, right) => left.localeCompare(right));

    expect(matrixNames).toEqual(exported);
  });

  it("has actionable BOLA fields for every endpoint", () => {
    const byName = endpointAuthorizationByName();
    const duplicateNames = endpointAuthorizationMatrix
      .map((entry) => entry.exportedName)
      .filter((name, index, all) => all.indexOf(name) !== index);

    expect(duplicateNames).toEqual([]);
    for (const entry of byName.values()) {
      expect(entry.trigger, entry.exportedName).toMatch(/^(callable|http|scheduled|firestore-trigger|provider-webhook)$/u);
      expect(entry.authMethod.trim(), entry.exportedName).not.toEqual("");
      expect(entry.appCheck, entry.exportedName).toMatch(/^(required|not-applicable|not-required)$/u);
      expect(entry.tenantSource.trim(), entry.exportedName).not.toEqual("");
      expect(entry.ownershipCheck.trim(), entry.exportedName).not.toEqual("");
      expect(entry.negativeBolaTest.trim(), entry.exportedName).not.toEqual("");
      if (entry.appCheck === "not-required" || entry.trigger === "provider-webhook") {
        expect(entry.publicJustification?.trim(), entry.exportedName).toBeTruthy();
      }
    }
  });
});

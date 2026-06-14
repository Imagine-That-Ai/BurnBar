import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

import { endpointAuthorizationMatrix, endpointAuthorizationByName } from "../security/endpointAuthorizationMatrix.js";

const REPO_ROOT = resolve(__dirname, "../../..");
const GENERIC_NEGATIVE_BOLA_PATTERN = /endpoint-specific|required|matrix drift/i;
const TEST_FILE_PATTERN = /(?:functions\/src\/__tests__|firestore-rules-tests)\/[A-Za-z0-9_.\/-]+\.(?:test\.)?(?:ts|js)/gu;

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

function referencedTestFiles(value: string): string[] {
  return Array.from(value.matchAll(TEST_FILE_PATTERN), (match) => match[0]);
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

  it("ties client-object endpoints to concrete negative-coverage test files", () => {
    for (const entry of endpointAuthorizationMatrix) {
      expect(entry.negativeBolaTest, entry.exportedName).not.toMatch(GENERIC_NEGATIVE_BOLA_PATTERN);

      const platformOnly =
        entry.trigger === "scheduled" ||
        entry.trigger === "firestore-trigger" ||
        entry.negativeBolaTest.startsWith("not-applicable-");
      if (platformOnly || entry.objectIdsFromClient.length === 0) continue;

      const refs = referencedTestFiles(entry.negativeBolaTest);
      expect(refs.length, `${entry.exportedName} must reference at least one executable BOLA test file`).toBeGreaterThan(0);
      for (const ref of refs) {
        expect(existsSync(resolve(REPO_ROOT, ref)), `${entry.exportedName} references missing test file ${ref}`).toBe(
          true,
        );
      }
    }
  });
});

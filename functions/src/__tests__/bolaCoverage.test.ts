import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

import { endpointAuthorizationMatrix } from "../security/endpointAuthorizationMatrix.js";
import { validateEndpointBolaCoverage } from "../security/bolaCoverageValidators.js";

const REPO_ROOT = resolve(__dirname, "../../..");

function exportedFunctionNames(): string[] {
  const indexSource = readFileSync(resolve(REPO_ROOT, "functions/src/index.ts"), "utf8");
  const names: string[] = [];
  for (const match of indexSource.matchAll(/export\s+\{([\s\S]*?)\}\s+from\s+"[^"]+";/g)) {
    for (const part of match[1].split(",")) {
      const raw = part.trim();
      if (!raw) continue;
      names.push(
        raw
          .split(/\s+as\s+/u)
          .pop()
          ?.trim() ?? raw,
      );
    }
  }
  return names.sort((left, right) => left.localeCompare(right));
}

/** Endpoints with handler-level cross-tenant proofs (not scaffold smoke). */
const P0_RUNTIME_PROOFS = new Set([
  "burnBarHermesGateway",
  "consumeCredentialTransfer",
  "pollCliLink",
  "triggerVoIPCall",
  "validateOpenTimestampsProof",
]);

/** Tier-2: every object-id runtime test seeds victim tenant (see callableBolaHarness tier2CallableProof). */
const TIER2_ISOLATION_ENDPOINTS = new Set(
  endpointAuthorizationMatrix
    .filter(
      (entry) =>
        entry.objectIdsFromClient.length > 0 &&
        entry.bolaCoverage.some((ref) => ref.kind === "runtime-cross-user" && ref.covers.includes(entry.exportedName)),
    )
    .map((entry) => entry.exportedName),
);

describe("bola coverage registry", () => {
  it("matrix covers every exported Cloud Function from index.ts", () => {
    const exported = exportedFunctionNames();
    const matrixNames = endpointAuthorizationMatrix
      .map((entry) => entry.exportedName)
      .sort((left, right) => left.localeCompare(right));
    expect(matrixNames).toEqual(exported);
  });

  it("validates bola coverage for every endpoint", () => {
    const failures: string[] = [];
    for (const entry of endpointAuthorizationMatrix) {
      failures.push(...validateEndpointBolaCoverage(entry, REPO_ROOT));
    }
    expect(failures, failures.join("\n")).toEqual([]);
  });

  it("does not use legacy negativeBolaTest field", () => {
    for (const entry of endpointAuthorizationMatrix) {
      expect("negativeBolaTest" in (entry as Record<string, unknown>)).toBe(false);
    }
  });

  it("requires handler modules for object-id callables", () => {
    for (const entry of endpointAuthorizationMatrix) {
      if (entry.objectIdsFromClient.length === 0) continue;
      expect(entry.handlerModule, entry.exportedName).toBeTruthy();
      expect(
        existsSync(resolve(REPO_ROOT, "functions/src", entry.handlerModule!)),
        `${entry.exportedName} handler missing`,
      ).toBe(true);
    }
  });

  it("tracks P0 cross-tenant runtime proofs separately from scaffold smoke", () => {
    const runtimeEndpoints = endpointAuthorizationMatrix.filter((entry) =>
      entry.bolaCoverage.some((ref) => ref.kind === "runtime-cross-user"),
    );
    for (const name of P0_RUNTIME_PROOFS) {
      expect(runtimeEndpoints.map((entry) => entry.exportedName)).toContain(name);
    }
    expect(P0_RUNTIME_PROOFS.size).toBeGreaterThanOrEqual(5);
  });

  it("requires tier-2 victim seeding for every object-id runtime endpoint", () => {
    expect(TIER2_ISOLATION_ENDPOINTS.size).toBeGreaterThanOrEqual(60);
    for (const name of P0_RUNTIME_PROOFS) {
      expect(TIER2_ISOLATION_ENDPOINTS).toContain(name);
    }
  });
});

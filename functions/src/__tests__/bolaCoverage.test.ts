import { existsSync, readdirSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

import {
  BOLA_STRICT_CODE_ENDPOINTS,
  BOLA_STRICT_CODE_PENDING,
} from "./bola/callableBolaHarness.js";
import { BOLA_EXPECTED_CODES } from "./bola/bolaExpectedCodes.generated.js";
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
const P0_RUNTIME_PROOFS = BOLA_STRICT_CODE_ENDPOINTS;

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

const BOLA_STRICT_CODE_PENDING_BASELINE = new Set([
  "appendCliAgentMissionEvent",
  "approveEscrowDeviceTrust",
  "beginBurnbarAttachment",
  "beginEncryptedSessionBlobUpload",
  "cancelCliAgentMission",
  "claimCliAgentMission",
  "claimSignalPrekeyBundle",
  "commitEncryptedProjectMemorySnapshot",
  "commitEncryptedSearchIndexBatch",
  "commitKnowledgeBatch",
  "completeCliLink",
  "completeHermesPairing",
  "completePiAgentPairing",
  "composeBurnbarAttachment",
  "configureKnowledgeSource",
  "confirmRecovery",
  "connectHostedQuotaAccount",
  "connectKnowledgeRepo",
  "connectProviderAccount",
  "connectSelfHostedQuotaAccount",
  "createCliAgentMission",
  "createCredentialTransfer",
  "createHermesPairing",
  "createPiAgentPairing",
  "deleteBurnbarAttachment",
  "deleteHostedQuotaCredentials",
  "deleteKnowledgeSource",
  "disconnectKnowledgeRepo",
  "enqueueHermesGatewayEvent",
  "finalizeBurnbarAttachment",
  "getEncryptedProjectMemorySnapshot",
  "getEncryptedSessionBlobDownloadUrl",
  "mintBurnbarAttachmentPartURL",
  "publishAgentGrantAuthority",
  "publishIrohPairingPublicKey",
  "publishIrohPairingRecord",
  "publishMissionApprovalCeiling",
  "publishPhoneControlAuthority",
  "publishRelaySenderKey",
  "publishSignalPrekeyBundle",
  "queryConversations",
  "queueAgentCapabilityGrantRequest",
  "recordSignalRotation",
  "recordSignalSession",
  "redeemMissionApprovalAnswer",
  "registerEscrowDevice",
  "respondMissionApproval",
  "revokeHermesConnection",
  "revokeIrohPairingRecord",
  "revokePiAgentConnection",
  "rotateCloudVaultKey",
  "searchEncryptedConversationIndex",
  "setHermesGatewayOversightMode",
  "signalPrekeyWatermark",
  "submitAgentNotificationReply",
  "ticketBurnbarAttachmentDownload",
  "updateCliAgentMissionStatus",
  "updateHermesConnectionStatus",
  "updatePiAgentConnectionStatus",
  "consumeCredentialTransfer",
]);

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

  it("assigns one expected denial code to every object-id endpoint", () => {
    const objectIdNames = endpointAuthorizationMatrix
      .filter((entry) => entry.objectIdsFromClient.length > 0)
      .map((entry) => entry.exportedName)
      .sort((left, right) => left.localeCompare(right));
    const expectedCodeNames = Object.keys(BOLA_EXPECTED_CODES).sort((left, right) => left.localeCompare(right));

    expect(expectedCodeNames).toEqual(objectIdNames);
    for (const name of objectIdNames) {
      expect(BOLA_EXPECTED_CODES[name], name).toBeTruthy();
    }
  });

  it("keeps the strict-code pending ledger shrink-only", () => {
    const pendingNames = [...BOLA_STRICT_CODE_PENDING.keys()];
    expect(new Set(pendingNames).size).toBe(pendingNames.length);
    for (const name of pendingNames) {
      expect(BOLA_STRICT_CODE_PENDING_BASELINE, name).toContain(name);
      expect(BOLA_STRICT_CODE_ENDPOINTS.has(name), name).toBe(false);
      expect(BOLA_STRICT_CODE_PENDING.get(name), name).toBe(BOLA_EXPECTED_CODES[name]);
    }
  });

  it("does not duplicate tier2CallableProof invocations per test case", () => {
    const bolaDir = resolve(REPO_ROOT, "functions/src/__tests__/bola");
    const duplicates: string[] = [];
    for (const file of readdirSync(bolaDir).filter((name) => name.endsWith(".bola.test.ts"))) {
      const source = readFileSync(resolve(bolaDir, file), "utf8");
      for (const block of source.matchAll(/\bit\s*\([^)]+\)\s*,\s*async\s*\(\)\s*=>\s*\{([\s\S]*?)\n\s*\}\);/gu)) {
        const body = block[1];
        const names = [...body.matchAll(/exportedName:\s*["']([^"']+)["']/gu)].map((match) => match[1]);
        const seen = new Set<string>();
        for (const name of names) {
          if (seen.has(name)) {
            duplicates.push(`${file}: duplicate tier2CallableProof for ${name}`);
          }
          seen.add(name);
        }
      }
    }
    expect(duplicates, duplicates.join("\n")).toEqual([]);
  });
});

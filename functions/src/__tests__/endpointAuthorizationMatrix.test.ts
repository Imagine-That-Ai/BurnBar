import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

import { endpointAuthorizationMatrix, endpointAuthorizationByName } from "../security/endpointAuthorizationMatrix.js";

const CALLABLES_DIR = resolve(__dirname, "../callables");

function readCallableSource(name: string): string {
  return readFileSync(resolve(CALLABLES_DIR, name), "utf8");
}

const HIGH_RISK_ACTION_KIND_TO_FILE: Record<string, string> = {
  data_export: "dataExport.ts",
  revoke_all_access: "panic.ts",
  provider_account_connect: "providerAccounts.ts",
  provider_account_delete: "providerAccounts.ts",
  provider_credential_connect: "providerAccounts.ts",
  provider_credential_delete: "providerAccounts.ts",
  hosted_quota_account_connect: "providerAccounts.ts",
  user_cloud_data_delete: "providerAccounts.ts",
  hermes_gateway_device_grant_approve: "hermesGateway.ts",
  self_hosted_quota_account_connect: "providerAccounts.ts",
  provider_account_update: "providerAccounts.ts",
  remote_mcp_grant_revoke: "remoteMcp.ts",
  hosted_quota_credential_delete: "providerAccounts.ts",
  hermes_pairing_complete: "hermes.ts",
  pi_agent_pairing_complete: "piAgent.ts",
};

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

  it("maps every highRiskComputerUse endpoint to a callable source that enforces the guard", () => {
    for (const entry of endpointAuthorizationMatrix) {
      if (!entry.highRiskComputerUse) continue;
      const file = HIGH_RISK_ACTION_KIND_TO_FILE[entry.actionKind];
      expect(file, `${entry.exportedName} has known actionKind ${entry.actionKind}`).toBeTruthy();
      const source = readCallableSource(file);
      expect(source, entry.exportedName).toContain("enforceHighRiskOwnerAction");
      expect(source, entry.exportedName).toContain(`"${entry.actionKind}"`);
    }
  });
});

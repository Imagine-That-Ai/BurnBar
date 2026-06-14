/**
 * F-RR10-004 / F-RR10-022 — Verify that every trust/data-destructive callable
 * and pairing completion callable is wired to enforceHighRiskOwnerAction.
 *
 * Static source analysis is used because executing these callables requires
 * extensive Firestore mocking; the security invariant is that the guard call is
 * present in the source and uses the correct actionKind.
 */
import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { endpointAuthorizationMatrix } from "../security/endpointAuthorizationMatrix.js";

const SRC_ROOT = resolve(__dirname, "../callables");

function readCallableSource(name: string): string {
  return readFileSync(resolve(SRC_ROOT, name), "utf8");
}

const EXPECTED_GUARDS: Array<{
  exportedName: string;
  file: string;
  actionKind: string;
}> = [
  {
    exportedName: "approveHermesGatewayDeviceGrant",
    file: "hermesGateway.ts",
    actionKind: "hermes_gateway_device_grant_approve",
  },
  { exportedName: "connectProviderAccount", file: "providerAccounts.ts", actionKind: "provider_account_connect" },
  { exportedName: "connectProviderCredential", file: "providerAccounts.ts", actionKind: "provider_credential_connect" },
  {
    exportedName: "connectHostedQuotaAccount",
    file: "providerAccounts.ts",
    actionKind: "hosted_quota_account_connect",
  },
  { exportedName: "exportUserData", file: "dataExport.ts", actionKind: "data_export" },
  { exportedName: "deleteUserCloudData", file: "providerAccounts.ts", actionKind: "user_cloud_data_delete" },
  { exportedName: "revokeAllAccess", file: "panic.ts", actionKind: "revoke_all_access" },
  {
    exportedName: "connectSelfHostedQuotaAccount",
    file: "providerAccounts.ts",
    actionKind: "self_hosted_quota_account_connect",
  },
  { exportedName: "updateProviderAccount", file: "providerAccounts.ts", actionKind: "provider_account_update" },
  { exportedName: "revokeRemoteMcpClient", file: "remoteMcp.ts", actionKind: "remote_mcp_grant_revoke" },
  {
    exportedName: "deleteHostedQuotaCredentials",
    file: "providerAccounts.ts",
    actionKind: "hosted_quota_credential_delete",
  },
  { exportedName: "deleteProviderAccount", file: "providerAccounts.ts", actionKind: "provider_account_delete" },
  { exportedName: "completeHermesPairing", file: "hermes.ts", actionKind: "hermes_pairing_complete" },
  { exportedName: "completePiAgentPairing", file: "piAgent.ts", actionKind: "pi_agent_pairing_complete" },
];

describe("highRiskOwnerAction callable guards — source wiring", () => {
  it("matrix marks exactly the expected endpoints as highRiskComputerUse", () => {
    const marked = endpointAuthorizationMatrix.filter((e) => e.highRiskComputerUse).map((e) => e.exportedName);
    const expected = EXPECTED_GUARDS.map((g) => g.exportedName).sort();
    expect(marked.sort()).toEqual(expected);
  });

  for (const guard of EXPECTED_GUARDS) {
    it(`${guard.exportedName} calls enforceHighRiskOwnerAction with actionKind "${guard.actionKind}"`, () => {
      const source = readCallableSource(guard.file);
      expect(source).toContain("enforceHighRiskOwnerAction");
      expect(source).toContain(`"${guard.actionKind}"`);
    });
  }

  it("providerAccounts.ts invokes enforceHighRiskOwnerAction at most once per actionKind", () => {
    const source = readCallableSource("providerAccounts.ts");
    const actionKinds = EXPECTED_GUARDS.filter((g) => g.file === "providerAccounts.ts").map((g) => g.actionKind);
    for (const actionKind of actionKinds) {
      const matches = source.match(new RegExp(`actionKind:\\s*"${actionKind}"`, "g"));
      expect(matches?.length ?? 0, actionKind).toBe(1);
    }
  });
});

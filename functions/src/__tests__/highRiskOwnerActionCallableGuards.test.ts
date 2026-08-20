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
  guardFunction?: string;
}> = [
  {
    exportedName: "approveHermesGatewayDeviceGrant",
    file: "hermesGatewayApprove.ts",
    actionKind: "hermes_gateway_device_grant_approve",
  },
  {
    exportedName: "approveLinuxAppCheckDevice",
    file: "linuxAppCheckDevices.ts",
    actionKind: "linux_app_check_device_approve",
    guardFunction: "enforceHighRiskComputerUseCallableWithNonce",
  },
  { exportedName: "connectProviderAccount", file: "providerAccounts.ts", actionKind: "provider_account_connect" },
  { exportedName: "connectProviderCredential", file: "providerAccounts.ts", actionKind: "provider_credential_connect" },
  {
    exportedName: "connectHostedQuotaAccount",
    file: "providerAccounts.ts",
    actionKind: "hosted_quota_account_connect",
  },
  { exportedName: "exportUserData", file: "dataExport.ts", actionKind: "data_export" },
  { exportedName: "deleteDomainData", file: "dataDeletion.ts", actionKind: "data_domain_delete" },
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
    exportedName: "revokeLinuxAppCheckDevice",
    file: "linuxAppCheckDevices.ts",
    actionKind: "linux_app_check_device_revoke",
    guardFunction: "enforceHighRiskComputerUseCallableWithNonce",
  },
  {
    exportedName: "deleteHostedQuotaCredentials",
    file: "providerAccounts.ts",
    actionKind: "hosted_quota_credential_delete",
  },
  { exportedName: "deleteProviderAccount", file: "providerAccounts.ts", actionKind: "provider_account_delete" },
  { exportedName: "completeHermesPairing", file: "hermes.ts", actionKind: "hermes_pairing_complete" },
  { exportedName: "completePiAgentPairing", file: "piAgent.ts", actionKind: "pi_agent_pairing_complete" },
  {
    exportedName: "beginBurnbarAttachment",
    file: "burnbarAttachments.ts",
    actionKind: "burnbar_attachment_begin",
    guardFunction: "enforceHighRiskComputerUseCallableWithNonce",
  },
  {
    exportedName: "mintBurnbarAttachmentPartURL",
    file: "burnbarAttachments.ts",
    actionKind: "burnbar_attachment_part",
    guardFunction: "enforceHighRiskComputerUseCallableWithNonce",
  },
  {
    exportedName: "composeBurnbarAttachment",
    file: "burnbarAttachments.ts",
    actionKind: "burnbar_attachment_compose",
    guardFunction: "enforceHighRiskComputerUseCallableWithNonce",
  },
  {
    exportedName: "finalizeBurnbarAttachment",
    file: "burnbarAttachments.ts",
    actionKind: "burnbar_attachment_finalize",
    guardFunction: "enforceHighRiskComputerUseCallableWithNonce",
  },
  {
    exportedName: "deleteBurnbarAttachment",
    file: "burnbarAttachments.ts",
    actionKind: "burnbar_attachment_delete",
    guardFunction: "enforceHighRiskComputerUseCallableWithNonce",
  },
  {
    exportedName: "ticketBurnbarAttachmentDownload",
    file: "burnbarAttachments.ts",
    actionKind: "burnbar_attachment_download",
    guardFunction: "enforceHighRiskComputerUseCallableWithNonce",
  },
  {
    exportedName: "createCliAgentMission",
    file: "cliAgentMissions.ts",
    actionKind: "cli_agent_mission_create",
    guardFunction: "enforceHighRiskComputerUseCallableWithNonce",
  },
  {
    exportedName: "cancelCliAgentMission",
    file: "cliAgentMissions.ts",
    actionKind: "cli_agent_mission_cancel",
    guardFunction: "enforceHighRiskComputerUseCallableWithNonce",
  },
  {
    exportedName: "claimCliAgentMission",
    file: "cliAgentMissions.ts",
    actionKind: "cli_agent_mission_claim",
    guardFunction: "enforceHighRiskComputerUseCallableWithNonce",
  },
  {
    exportedName: "appendCliAgentMissionEvent",
    file: "cliAgentMissions.ts",
    actionKind: "cli_agent_mission_append_event",
    guardFunction: "enforceHighRiskComputerUseCallableWithNonce",
  },
  {
    exportedName: "updateCliAgentMissionStatus",
    file: "cliAgentMissions.ts",
    actionKind: "cli_agent_mission_status",
    guardFunction: "enforceHighRiskComputerUseCallableWithNonce",
  },
  {
    exportedName: "publishMissionApprovalCeiling",
    file: "missionApprovalAnswers.ts",
    actionKind: "mission_approval_ceiling_publish",
    guardFunction: "enforceHighRiskComputerUseCallableWithNonce",
  },
  {
    exportedName: "redeemMissionApprovalAnswer",
    file: "missionApprovalAnswers.ts",
    actionKind: "mission_approval_answer_redeem",
    guardFunction: "enforceHighRiskComputerUseCallableWithNonce",
  },
];

describe("highRiskOwnerAction callable guards — source wiring", () => {
  it("matrix marks exactly the expected endpoints as highRiskComputerUse", () => {
    const marked = endpointAuthorizationMatrix.filter((e) => e.highRiskComputerUse).map((e) => e.exportedName);
    const expected = EXPECTED_GUARDS.map((g) => g.exportedName).sort();
    expect(marked.sort()).toEqual(expected);
  });

  for (const guard of EXPECTED_GUARDS) {
    const guardFunction = guard.guardFunction ?? "enforceHighRiskOwnerAction";
    it(`${guard.exportedName} calls ${guardFunction} with actionKind "${guard.actionKind}"`, () => {
      const source = readCallableSource(guard.file);
      expect(source).toContain(guardFunction);
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

  it("allows account-erasure retries only through the server-only nonterminal audit check", () => {
    const source = readCallableSource("providerAccounts.ts");
    expect(source).toContain("const resumeExistingIntent = await isAccountErasureResumable(db, uid)");
    expect(source).toContain("if (!resumeExistingIntent)");
    expect(source).toContain("await enforceHighRiskOwnerAction(request, uid");
    expect(source).toContain("await auth.revokeRefreshTokens(targetUID)");
    expect(source).toContain("resumeExistingIntent,");
  });
});

/**
 * F-RR10-004 / F-RR10-022 — Verify that every trust/data-destructive callable
 * and pairing completion callable is wired to enforceHighRiskOwnerAction.
 *
 * Static source analysis is used because executing these callables requires
 * extensive Firestore mocking; the security invariant is that the guard call is
 * present in the source and uses the correct actionKind.
 */
import { describe, expect, it } from "vitest";
import { readdirSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

import { endpointAuthorizationMatrix } from "../security/endpointAuthorizationMatrix.js";

// 3.5: callables live in four deploy codebases plus the shared runtime.
// Basenames are unique across trees; resolve by searching each src root.
const SRC_ROOTS = [
  resolve(__dirname, ".."),
  resolve(__dirname, "../../../functions-identity/src"),
  resolve(__dirname, "../../../functions-sync/src"),
  resolve(__dirname, "../../../functions-media/src"),
  resolve(__dirname, "../../../packages/functions-shared/src"),
];

function findBySuffix(root: string, suffix: string): string[] {
  const hits: string[] = [];
  const visit = (dir: string, depth: number): void => {
    if (depth > 4) return;
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (entry.name === "node_modules" || entry.name === "lib" || entry.name === "__tests__") continue;
      const full = resolve(dir, entry.name);
      if (entry.isFile() && full.endsWith(`/${suffix}`)) hits.push(full);
      else if (entry.isDirectory()) visit(full, depth + 1);
    }
  };
  visit(root, 0);
  return hits;
}

function readCallableSource(name: string): string {
  const hits = SRC_ROOTS.flatMap((root) => findBySuffix(root, name));
  if (hits.length !== 1) {
    throw new Error(`expected exactly one ${name} across codebase trees, found ${hits.length}`);
  }
  return readFileSync(hits[0], "utf8");
}

const EXPECTED_GUARDS: Array<{
  exportedName: string;
  file: string;
  actionKind: string;
  guardFunction?: string;
}> = [
  {
    exportedName: "approveHermesGatewayDeviceGrant",
    file: "callables/hermesGatewayApprove.ts",
    actionKind: "hermes_gateway_device_grant_approve",
  },
  {
    exportedName: "approveLinuxAppCheckDevice",
    file: "domains/app-check/linuxAppCheckDevices.ts",
    actionKind: "linux_app_check_device_approve",
    guardFunction: "enforceHighRiskComputerUseCallableWithNonce",
  },
  { exportedName: "connectProviderAccount", file: "domains/identity/providerAccounts.ts", actionKind: "provider_account_connect" },
  { exportedName: "connectProviderCredential", file: "domains/identity/providerAccounts.ts", actionKind: "provider_credential_connect" },
  {
    exportedName: "connectHostedQuotaAccount",
    file: "domains/identity/providerAccounts.ts",
    actionKind: "hosted_quota_account_connect",
  },
  { exportedName: "exportUserData", file: "domains/compliance/dataExport.ts", actionKind: "data_export" },
  { exportedName: "deleteDomainData", file: "domains/compliance/dataDeletion.ts", actionKind: "data_domain_delete" },
  { exportedName: "deleteUserCloudData", file: "domains/identity/providerAccounts.ts", actionKind: "user_cloud_data_delete" },
  { exportedName: "revokeAllAccess", file: "domains/ops/panic.ts", actionKind: "revoke_all_access" },
  {
    exportedName: "connectSelfHostedQuotaAccount",
    file: "domains/identity/providerAccounts.ts",
    actionKind: "self_hosted_quota_account_connect",
  },
  { exportedName: "updateProviderAccount", file: "domains/identity/providerAccounts.ts", actionKind: "provider_account_update" },
  { exportedName: "revokeRemoteMcpClient", file: "domains/identity/remoteMcp.ts", actionKind: "remote_mcp_grant_revoke" },
  {
    exportedName: "revokeLinuxAppCheckDevice",
    file: "domains/app-check/linuxAppCheckDevices.ts",
    actionKind: "linux_app_check_device_revoke",
    guardFunction: "enforceHighRiskComputerUseCallableWithNonce",
  },
  {
    exportedName: "deleteHostedQuotaCredentials",
    file: "domains/identity/providerAccounts.ts",
    actionKind: "hosted_quota_credential_delete",
  },
  { exportedName: "deleteProviderAccount", file: "domains/identity/providerAccounts.ts", actionKind: "provider_account_delete" },
  { exportedName: "completeHermesPairing", file: "domains/hermes/hermes.ts", actionKind: "hermes_pairing_complete" },
  { exportedName: "completePiAgentPairing", file: "domains/identity/piAgent.ts", actionKind: "pi_agent_pairing_complete" },
  {
    exportedName: "beginBurnbarAttachment",
    file: "domains/attachments/burnbarAttachments.ts",
    actionKind: "burnbar_attachment_begin",
    guardFunction: "enforceHighRiskComputerUseCallableWithNonce",
  },
  {
    exportedName: "mintBurnbarAttachmentPartURL",
    file: "domains/attachments/burnbarAttachments.ts",
    actionKind: "burnbar_attachment_part",
    guardFunction: "enforceHighRiskComputerUseCallableWithNonce",
  },
  {
    exportedName: "composeBurnbarAttachment",
    file: "domains/attachments/burnbarAttachments.ts",
    actionKind: "burnbar_attachment_compose",
    guardFunction: "enforceHighRiskComputerUseCallableWithNonce",
  },
  {
    exportedName: "finalizeBurnbarAttachment",
    file: "domains/attachments/burnbarAttachments.ts",
    actionKind: "burnbar_attachment_finalize",
    guardFunction: "enforceHighRiskComputerUseCallableWithNonce",
  },
  {
    exportedName: "deleteBurnbarAttachment",
    file: "domains/attachments/burnbarAttachments.ts",
    actionKind: "burnbar_attachment_delete",
    guardFunction: "enforceHighRiskComputerUseCallableWithNonce",
  },
  {
    exportedName: "ticketBurnbarAttachmentDownload",
    file: "domains/attachments/burnbarAttachments.ts",
    actionKind: "burnbar_attachment_download",
    guardFunction: "enforceHighRiskComputerUseCallableWithNonce",
  },
  {
    exportedName: "createCliAgentMission",
    file: "domains/missions/cliAgentMissions.ts",
    actionKind: "cli_agent_mission_create",
    guardFunction: "enforceHighRiskComputerUseCallableWithNonce",
  },
  {
    exportedName: "createCliAgentMissionGroup",
    file: "domains/missions/cliAgentMissions.ts",
    actionKind: "cli_agent_mission_group_create",
    guardFunction: "enforceHighRiskComputerUseCallableWithNonce",
  },
  {
    exportedName: "cancelCliAgentMission",
    file: "domains/missions/cliAgentMissions.ts",
    actionKind: "cli_agent_mission_cancel",
    guardFunction: "enforceHighRiskComputerUseCallableWithNonce",
  },
  {
    exportedName: "claimCliAgentMission",
    file: "domains/missions/cliAgentMissions.ts",
    actionKind: "cli_agent_mission_claim",
    guardFunction: "enforceHighRiskComputerUseCallableWithNonce",
  },
  {
    exportedName: "appendCliAgentMissionEvent",
    file: "domains/missions/cliAgentMissions.ts",
    actionKind: "cli_agent_mission_append_event",
    guardFunction: "enforceHighRiskComputerUseCallableWithNonce",
  },
  {
    exportedName: "updateCliAgentMissionStatus",
    file: "domains/missions/cliAgentMissions.ts",
    actionKind: "cli_agent_mission_status",
    guardFunction: "enforceHighRiskComputerUseCallableWithNonce",
  },
  {
    exportedName: "publishMissionApprovalCeiling",
    file: "domains/missions/missionApprovalAnswers.ts",
    actionKind: "mission_approval_ceiling_publish",
    guardFunction: "enforceHighRiskComputerUseCallableWithNonce",
  },
  {
    exportedName: "redeemMissionApprovalAnswer",
    file: "domains/missions/missionApprovalAnswers.ts",
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

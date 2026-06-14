import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";

import { enforceHighRiskComputerUseCallableWithNonce } from "../appCheckAttestation.js";
import { requireTrustedDeviceActionProof } from "./computerUseSecurity.js";
import { boundedTrimmedString } from "./shared.js";

const HIGH_RISK_OWNER_ACTION_PLATFORMS = new Set(["macOS", "iOS", "iPadOS", "Android"]);

type HighRiskOwnerActionKind =
  | "data_export"
  | "revoke_all_access"
  | "provider_account_connect"
  | "provider_account_delete"
  | "provider_credential_connect"
  | "provider_credential_delete"
  | "hosted_quota_account_connect"
  | "user_cloud_data_delete"
  | "hermes_gateway_device_grant_approve"
  | "self_hosted_quota_account_connect"
  | "provider_account_update"
  | "remote_mcp_grant_revoke"
  | "hosted_quota_credential_delete"
  | "hermes_pairing_complete"
  | "pi_agent_pairing_complete";

export async function enforceHighRiskOwnerAction(
  request: CallableRequest,
  uid: string,
  options: {
    actionKind: HighRiskOwnerActionKind;
    subjectId: string;
    approve?: boolean;
  },
): Promise<void> {
  const data = recordFromUnknown(request.data);
  const nonce = boundedTrimmedString(data.nonce, "nonce", 256, true);
  const { nonceConsumed } = await enforceHighRiskComputerUseCallableWithNonce(request, uid, nonce);
  if (!nonceConsumed) {
    throw new HttpsError(
      "failed-precondition",
      "This high-risk action requires App Check, a fresh high-risk nonce, and a trusted-device action proof.",
    );
  }

  const rawDeviceId = data.trustedDeviceId ?? data.deviceId ?? data.sourceDeviceId ?? data.sourceDeviceID;
  const deviceId = boundedTrimmedString(rawDeviceId, "trustedDeviceId", 160, true);
  const subjectId = boundedTrimmedString(options.subjectId, "subjectId", 240, true);
  await requireTrustedDeviceActionProof({
    uid,
    deviceId,
    actionKind: options.actionKind,
    subjectId,
    approve: options.approve ?? true,
    nonce,
    proofRaw: data.actionProof,
    allowedPlatforms: HIGH_RISK_OWNER_ACTION_PLATFORMS,
  });
}

function recordFromUnknown(value: unknown): Record<string, unknown> {
  const record: Record<string, unknown> = {};
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return record;
  }
  for (const [key, entry] of Object.entries(value)) {
    record[key] = entry;
  }
  return record;
}

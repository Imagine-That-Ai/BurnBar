/**
 * Idempotent Remote Config publish helpers for Computer Use safety gates.
 */

import { getRemoteConfig, type RemoteConfigTemplate } from "firebase-admin/remote-config";
import { getFirestore, Timestamp } from "firebase-admin/firestore";
import { remoteConfigStringValue } from "./remoteConfigGuards.js";

const KILL_SWITCH_PARAM = "computer_use_kill_switch";
export const COMPUTER_USE_PHONE_CONTROL_ATTESTATION_REQUIRED_PARAM =
  "computer_use_phone_control_attestation_required";

export async function publishComputerUseKillSwitch(enabled: boolean, reason: string): Promise<void> {
  const rc = getRemoteConfig();
  const template: RemoteConfigTemplate = await rc.getTemplate();
  const parameters = template.parameters ?? {};

  const current = remoteConfigStringValue(parameters[KILL_SWITCH_PARAM]?.defaultValue) ?? "false";
  const next = enabled ? "true" : "false";
  if (current === next) {
    return;
  }

  parameters[KILL_SWITCH_PARAM] = {
    ...(parameters[KILL_SWITCH_PARAM] ?? {}),
    defaultValue: { value: next },
  };
  template.parameters = parameters;

  await rc.publishTemplate(template);

  await getFirestore()
    .collection("ops/computer_use_budget_status/events")
    .doc(`${Date.now()}-${enabled ? "kill_on" : "kill_off"}`)
    .set({
      kind: "remote_config_kill_switch",
      enabled,
      reason,
      parameter: KILL_SWITCH_PARAM,
      updatedAt: Timestamp.now(),
    });
}

export async function publishComputerUsePhoneControlAttestationRequired(
  enabled: boolean,
  reason: string,
): Promise<void> {
  const rc = getRemoteConfig();
  const template: RemoteConfigTemplate = await rc.getTemplate();
  const parameters = template.parameters ?? {};

  const current =
    remoteConfigStringValue(parameters[COMPUTER_USE_PHONE_CONTROL_ATTESTATION_REQUIRED_PARAM]?.defaultValue) ??
    "false";
  const next = enabled ? "true" : "false";
  if (current === next) {
    return;
  }

  parameters[COMPUTER_USE_PHONE_CONTROL_ATTESTATION_REQUIRED_PARAM] = {
    ...(parameters[COMPUTER_USE_PHONE_CONTROL_ATTESTATION_REQUIRED_PARAM] ?? {}),
    defaultValue: { value: next },
  };
  template.parameters = parameters;

  await rc.publishTemplate(template);

  await getFirestore()
    .collection("ops/computer_use_budget_status/events")
    .doc(`${Date.now()}-${enabled ? "attestation_on" : "attestation_off"}`)
    .set({
      kind: "remote_config_phone_control_attestation",
      enabled,
      reason,
      parameter: COMPUTER_USE_PHONE_CONTROL_ATTESTATION_REQUIRED_PARAM,
      updatedAt: Timestamp.now(),
    });
}

export async function syncKillSwitchForBudgetLevel(level: "normal" | "soft_cap" | "hard_cap"): Promise<void> {
  if (level === "hard_cap") {
    await publishComputerUseKillSwitch(true, "budget_hard_cap");
    return;
  }
  await publishComputerUseKillSwitch(false, `budget_${level}`);
}

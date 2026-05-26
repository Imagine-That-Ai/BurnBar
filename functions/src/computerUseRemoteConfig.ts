/**
 * Idempotent Remote Config publish helpers for Computer Use safety gates.
 */

import { getRemoteConfig, type RemoteConfigTemplate } from "firebase-admin/remote-config";
import { getFirestore, Timestamp } from "firebase-admin/firestore";

const KILL_SWITCH_PARAM = "computer_use_kill_switch";

export async function publishComputerUseKillSwitch(enabled: boolean, reason: string): Promise<void> {
  const rc = getRemoteConfig();
  const template: RemoteConfigTemplate = await rc.getTemplate();
  const parameters = template.parameters ?? {};

  const current =
    (parameters[KILL_SWITCH_PARAM]?.defaultValue as { value?: string } | undefined)?.value ?? "false";
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

export async function syncKillSwitchForBudgetLevel(
  level: "normal" | "soft_cap" | "hard_cap",
): Promise<void> {
  if (level === "hard_cap") {
    await publishComputerUseKillSwitch(true, "budget_hard_cap");
    return;
  }
  await publishComputerUseKillSwitch(false, `budget_${level}`);
}

import { describe, expect, it } from "vitest";

import {
  decodeWindowsRuntimeSafetyConfig,
  getWindowsRuntimeSafetyConfig,
  readWindowsRuntimeSafetyConfig,
} from "../callables/windowsRuntimeSafetyConfig.js";

function template(values: Record<string, string>): Parameters<typeof decodeWindowsRuntimeSafetyConfig>[0] {
  return {
    parameters: Object.fromEntries(Object.entries(values).map(([key, value]) => [key, { defaultValue: { value } }])),
  };
}

describe("Windows runtime safety config", () => {
  it("rejects unauthenticated callers before reading Remote Config", async () => {
    const run = Reflect.get(getWindowsRuntimeSafetyConfig, "run") as (request: unknown) => Promise<unknown>;
    await expect(run({ data: {}, rawRequest: { headers: {} } })).rejects.toMatchObject({
      code: "unauthenticated",
    });
  });

  it("uses fail-closed defaults when parameters are absent or malformed", () => {
    const result = decodeWindowsRuntimeSafetyConfig(
      template({
        computer_use_kill_switch: "not-a-boolean",
        media_kill_switch: "1",
        computer_use_system_enabled: "yes",
        computer_use_phone_control_respects_deny_regions: "no",
      }),
      1_750_000_000_000,
    );

    expect(result).toMatchObject({
      schemaVersion: "openburnbar.windows.runtime-safety.v1",
      fetchedAtEpochMillis: 1_750_000_000_000,
      maxAgeSeconds: 90,
      computerUseWatchEnabled: false,
      computerUseBrowserEnabled: false,
      computerUseSystemEnabled: false,
      computerUsePhoneControlEnabled: false,
      computerUseKillSwitch: true,
      computerUsePhoneControlRespectsDenyRegions: true,
      mediaKillSwitch: true,
    });
  });

  it("projects every explicitly published boolean", () => {
    const result = decodeWindowsRuntimeSafetyConfig(
      template({
        computer_use_watch_enabled: "true",
        computer_use_browser_enabled: "true",
        computer_use_system_enabled: "true",
        computer_use_phone_control_enabled: "true",
        computer_use_phone_control_attestation_required: "true",
        computer_use_trust_modes_enabled: "true",
        computer_use_polish_enabled: "true",
        computer_use_kill_switch: "false",
        computer_use_phone_control_respects_deny_regions: "false",
        media_kill_switch: "false",
      }),
      1_750_000_000_000,
    );

    expect(result).toMatchObject({
      computerUseWatchEnabled: true,
      computerUseBrowserEnabled: true,
      computerUseSystemEnabled: true,
      computerUsePhoneControlEnabled: true,
      computerUsePhoneControlAttestationRequired: true,
      computerUseTrustModesEnabled: true,
      computerUsePolishEnabled: true,
      computerUseKillSwitch: false,
      computerUsePhoneControlRespectsDenyRegions: false,
      mediaKillSwitch: false,
    });
  });

  it("propagates Remote Config outages so the Windows client remains closed", async () => {
    await expect(
      readWindowsRuntimeSafetyConfig(async () => {
        throw new Error("remote config unavailable");
      }),
    ).rejects.toThrow("remote config unavailable");
  });
});

import { getRemoteConfig, type RemoteConfigTemplate } from "firebase-admin/remote-config";
import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";

import { enforceAuthAndAppCheck } from "../auth.js";
import { getConfig } from "../config.js";
import { onCallProduction } from "../logging.js";
import { remoteConfigStringValue } from "../remoteConfigGuards.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";

const SCHEMA_VERSION = "openburnbar.windows.runtime-safety.v1";
const MAX_AGE_SECONDS = 90;

const PARAMS = {
  computerUseWatchEnabled: "computer_use_watch_enabled",
  computerUseBrowserEnabled: "computer_use_browser_enabled",
  computerUseSystemEnabled: "computer_use_system_enabled",
  computerUsePhoneControlEnabled: "computer_use_phone_control_enabled",
  computerUsePhoneControlAttestationRequired: "computer_use_phone_control_attestation_required",
  computerUseTrustModesEnabled: "computer_use_trust_modes_enabled",
  computerUsePolishEnabled: "computer_use_polish_enabled",
  computerUseKillSwitch: "computer_use_kill_switch",
  computerUsePhoneControlRespectsDenyRegions: "computer_use_phone_control_respects_deny_regions",
  mediaKillSwitch: "media_kill_switch",
} as const;

type WindowsRuntimeSafetyConfig = {
  schemaVersion: typeof SCHEMA_VERSION;
  fetchedAtEpochMillis: number;
  maxAgeSeconds: number;
  computerUseWatchEnabled: boolean;
  computerUseBrowserEnabled: boolean;
  computerUseSystemEnabled: boolean;
  computerUsePhoneControlEnabled: boolean;
  computerUsePhoneControlAttestationRequired: boolean;
  computerUseTrustModesEnabled: boolean;
  computerUsePolishEnabled: boolean;
  computerUseKillSwitch: boolean;
  computerUsePhoneControlRespectsDenyRegions: boolean;
  mediaKillSwitch: boolean;
};

type RuntimeSafetyTemplate = {
  parameters?: Record<string, { defaultValue?: unknown }>;
};

function secureBoolean(template: RuntimeSafetyTemplate, parameter: string, secureDefault: boolean): boolean {
  const raw = remoteConfigStringValue(template.parameters?.[parameter]?.defaultValue);
  if (raw === "true") return true;
  if (raw === "false") return false;
  return secureDefault;
}

export function decodeWindowsRuntimeSafetyConfig(
  template: RuntimeSafetyTemplate,
  nowEpochMillis: number,
): WindowsRuntimeSafetyConfig {
  return {
    schemaVersion: SCHEMA_VERSION,
    fetchedAtEpochMillis: nowEpochMillis,
    maxAgeSeconds: MAX_AGE_SECONDS,
    computerUseWatchEnabled: secureBoolean(template, PARAMS.computerUseWatchEnabled, false),
    computerUseBrowserEnabled: secureBoolean(template, PARAMS.computerUseBrowserEnabled, false),
    computerUseSystemEnabled: secureBoolean(template, PARAMS.computerUseSystemEnabled, false),
    computerUsePhoneControlEnabled: secureBoolean(template, PARAMS.computerUsePhoneControlEnabled, false),
    computerUsePhoneControlAttestationRequired: secureBoolean(
      template,
      PARAMS.computerUsePhoneControlAttestationRequired,
      false,
    ),
    computerUseTrustModesEnabled: secureBoolean(template, PARAMS.computerUseTrustModesEnabled, false),
    computerUsePolishEnabled: secureBoolean(template, PARAMS.computerUsePolishEnabled, false),
    computerUseKillSwitch: secureBoolean(template, PARAMS.computerUseKillSwitch, true),
    computerUsePhoneControlRespectsDenyRegions: secureBoolean(
      template,
      PARAMS.computerUsePhoneControlRespectsDenyRegions,
      true,
    ),
    mediaKillSwitch: secureBoolean(template, PARAMS.mediaKillSwitch, true),
  };
}

export async function readWindowsRuntimeSafetyConfig(
  fetchTemplate: () => Promise<RemoteConfigTemplate> = () => getRemoteConfig().getTemplate(),
  nowEpochMillis: number = Date.now(),
): Promise<WindowsRuntimeSafetyConfig> {
  const template = await fetchTemplate();
  return decodeWindowsRuntimeSafetyConfig(template, nowEpochMillis);
}

export const getWindowsRuntimeSafetyConfig = onCallProduction(
  "getWindowsRuntimeSafetyConfig",
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 20,
    timeoutSeconds: 15,
  },
  async (request: CallableRequest<unknown>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before reading runtime safety configuration.");
    enforceAuthAndAppCheck(request, uid);
    return readWindowsRuntimeSafetyConfig();
  },
);

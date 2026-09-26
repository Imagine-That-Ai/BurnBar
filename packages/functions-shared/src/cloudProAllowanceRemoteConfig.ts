/**
 * @fileoverview Remote Config bridge for Cloud Pro commercial allowance caps.
 */

import { getRemoteConfig } from "firebase-admin/remote-config";

import {
  DEFAULT_CLOUD_PRO_ALLOWANCE_CONFIG,
  normalizeCloudProAllowanceConfig,
  type CloudProAllowanceConfig,
} from "./cloudProAllowanceCore.js";
import { errorMessage } from "./guards.js";
import { logWarn } from "./logging.js";
import { remoteConfigStringValue } from "./remoteConfigGuards.js";

function integerDefault(parameters: Record<string, { defaultValue?: unknown }>, key: string): number | undefined {
  const raw = remoteConfigStringValue(parameters[key]?.defaultValue);
  if (raw == null) return undefined;
  const parsed = Number(raw);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : undefined;
}

export async function loadCloudProAllowanceConfig(): Promise<CloudProAllowanceConfig> {
  try {
    const template = await getRemoteConfig().getTemplate();
    const parameters = template.parameters ?? {};
    return normalizeCloudProAllowanceConfig({
      includedHostedActionsMonthly: integerDefault(parameters, "cloud_pro_included_hosted_actions_monthly"),
      actionTopUpUnit: integerDefault(parameters, "cloud_pro_action_topup_unit"),
      monthlyHostedActionCap: integerDefault(parameters, "cloud_pro_monthly_hosted_action_cap"),
      includedRelayGBMonthly: integerDefault(parameters, "cloud_pro_included_relay_gb_monthly"),
      relayTopUpUnitGB: integerDefault(parameters, "cloud_pro_relay_topup_unit_gb"),
      monthlyRelayGBCap: integerDefault(parameters, "cloud_pro_monthly_relay_gb_cap"),
      includedFusionSearchesMonthly: integerDefault(parameters, "cloud_pro_included_fusion_searches_monthly"),
      includedUltraFusionSearchesMonthly: integerDefault(
        parameters,
        "cloud_ultra_included_fusion_searches_monthly",
      ),
      fusionSearchTopUpUnit: integerDefault(parameters, "cloud_pro_fusion_search_topup_unit"),
      fusionSearchLargeTopUpUnit: integerDefault(parameters, "cloud_pro_fusion_search_large_topup_unit"),
      monthlyFusionSearchCap: integerDefault(parameters, "cloud_pro_monthly_fusion_search_cap"),
      monthlyUltraFusionSearchCap: integerDefault(parameters, "cloud_ultra_monthly_fusion_search_cap"),
    });
  } catch (err) {
    logWarn({
      event: "cloud_pro_allowance.remote_config_unavailable",
      error: errorMessage(err),
    });
    return DEFAULT_CLOUD_PRO_ALLOWANCE_CONFIG;
  }
}

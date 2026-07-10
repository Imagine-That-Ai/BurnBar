import type { CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "../config.js";
import { isRecord } from "../guards.js";

export type AppCheckTrustClass =
  | "apple_attested"
  | "android_play_integrity"
  | "web_recaptcha"
  | "linux_lower_trust"
  | "windows_lower_trust"
  | "retired_desktop"
  | "unknown";

export function readAppIdFromCallableRequest(request: CallableRequest): string | undefined {
  const appCheck = "app" in request ? request.app : undefined;
  return isRecord(appCheck) && typeof appCheck.appId === "string" ? appCheck.appId : undefined;
}

export function appCheckTrustClassForAppId(
  appId: string | undefined,
  config: Pick<
    ReturnType<typeof getConfig>,
    "allowedAppCheckAppIDs" | "standardWebAppCheckAppIDs" | "linuxAppCheckAppID" | "windowsAppCheckAppID"
  > = getConfig(),
): AppCheckTrustClass {
  if (!appId) return "unknown";
  // Production getConfig() always supplies both arrays. Treat absent values as
  // empty so isolated unit-test mocks and staged callers fail closed instead of
  // throwing before an authorization decision can be made.
  const allowedDesktopAppIDs = config.allowedAppCheckAppIDs ?? [];
  const standardWebAppIDs = config.standardWebAppCheckAppIDs ?? [];
  if (appId === config.linuxAppCheckAppID) {
    return allowedDesktopAppIDs.includes(appId) ? "linux_lower_trust" : "retired_desktop";
  }
  if (appId === config.windowsAppCheckAppID) {
    return allowedDesktopAppIDs.includes(appId) ? "windows_lower_trust" : "retired_desktop";
  }
  if (allowedDesktopAppIDs.includes(appId)) return "retired_desktop";
  if (/^1:[0-9]+:ios:/u.test(appId)) return "apple_attested";
  if (/^1:[0-9]+:android:/u.test(appId)) return "android_play_integrity";
  if (standardWebAppIDs.includes(appId)) return "web_recaptcha";
  return "unknown";
}

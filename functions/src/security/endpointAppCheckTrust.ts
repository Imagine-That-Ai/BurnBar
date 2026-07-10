import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "../config.js";
import { endpointAuthorizationCatalog } from "./endpointAuthorizationCatalog.generated.js";
import { appCheckTrustClassForAppId, readAppIdFromCallableRequest, type AppCheckTrustClass } from "./appCheckTrust.js";

const endpointByName = new Map(endpointAuthorizationCatalog.map((entry) => [entry.exportedName, entry]));
const STANDARD_TRUST_CLASSES = new Set<AppCheckTrustClass>([
  "apple_attested",
  "android_play_integrity",
  "web_recaptcha",
]);

export function enforceEndpointAppCheckTrust(exportedName: string, request: CallableRequest): void {
  const config = getConfig();
  if (!config.enforceAppCheck) return;

  const entry = endpointByName.get(exportedName);
  if (!entry) {
    throw new HttpsError("internal", `Callable ${exportedName} has no endpoint authorization policy.`);
  }
  if (entry.appCheck !== "required") return;

  const appId = readAppIdFromCallableRequest(request);
  if (!appId) {
    throw new HttpsError("unauthenticated", "App Check attestation is required.");
  }
  const trustClass = appCheckTrustClassForAppId(appId, config);
  if (STANDARD_TRUST_CLASSES.has(trustClass)) return;

  const policy = entry.lowerTrustDesktopPolicy;
  if (trustClass === "linux_lower_trust") {
    if (
      policy === "linux-low-risk" ||
      policy === "desktop-attestation-binding" ||
      policy === "desktop-nonce-bootstrap" ||
      policy === "desktop-trusted-device-step-up"
    ) {
      return;
    }
  } else if (trustClass === "windows_lower_trust") {
    if (
      policy === "desktop-attestation-binding" ||
      policy === "desktop-nonce-bootstrap" ||
      policy === "desktop-trusted-device-step-up"
    ) {
      return;
    }
  }

  throw new HttpsError(
    "permission-denied",
    `App Check trust class ${trustClass} is not authorized for callable ${exportedName}.`,
  );
}

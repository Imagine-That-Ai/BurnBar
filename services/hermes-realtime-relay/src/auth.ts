import { getAppCheck } from "firebase-admin/app-check";
import { getAuth } from "firebase-admin/auth";
import type { IncomingMessage } from "node:http";
import type { EntitlementVerifier } from "./entitlements.js";
import { RelayHttpError } from "./errors.js";
import type { HermesRelaySocketRole } from "./protocol.js";

export interface AuthResult {
  uid: string;
  role: HermesRelaySocketRole;
  appID?: string;
  entitlementSource: "firestore" | "cache";
}

export interface AuthOptions {
  enforceAppCheck: boolean;
  verifyRevokedIdTokens: boolean;
  entitlementVerifier: EntitlementVerifier;
  allowedAppIDs: string[];
}

export async function authenticateRequest(
  req: IncomingMessage,
  options: AuthOptions
): Promise<AuthResult> {
  const role = relayRole(req);
  const authorization = req.headers.authorization;
  const match = typeof authorization === "string" ? authorization.match(/^Bearer\s+(.+)$/i) : null;
  if (!match) throw new RelayHttpError(401, "missing_firebase_token", "Missing Firebase ID token.");
  const decoded = await getAuth().verifyIdToken(match[1], options.verifyRevokedIdTokens);

  let appID: string | undefined;
  if (options.enforceAppCheck) {
    const appCheckToken = req.headers["x-firebase-appcheck"];
    if (typeof appCheckToken !== "string" || appCheckToken.length === 0) {
      throw new RelayHttpError(401, "missing_app_check", "Missing Firebase App Check token.");
    }
    const decodedAppCheck = await getAppCheck().verifyToken(appCheckToken);
    appID = decodedAppCheck.appId;
    if (options.allowedAppIDs.length > 0 && !options.allowedAppIDs.includes(decodedAppCheck.appId)) {
      throw new RelayHttpError(403, "app_check_app_denied", "Firebase App Check app is not allowed for Hermes relay.");
    }
  }

  const entitlement = await options.entitlementVerifier.assertActive(decoded.uid);
  return {
    uid: decoded.uid,
    role,
    appID,
    entitlementSource: entitlement.source,
  };
}

function relayRole(req: IncomingMessage): HermesRelaySocketRole {
  const raw = req.headers["x-openburnbar-relay-role"];
  const role = typeof raw === "string" ? raw.trim().toLowerCase() : "";
  if (role === "host" || role === "client") {
    return role;
  }
  throw new RelayHttpError(400, "missing_relay_role", "Missing Hermes relay role.");
}

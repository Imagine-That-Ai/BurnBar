/**
 * @fileoverview Remote MCP grants and stream search callables
 */

import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "../config.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { enforceHighRiskComputerUseCallableWithNonce } from "../appCheckAttestation.js";
import { db } from "../adminRuntime.js";
import { assertCloudFeatureNotSuspended } from "../cloudFeatureSuspensions.js";
import { logInfo, wrapCallableHandler } from "../logging.js";
import {
  REMOTE_MCP_TOKEN_HMAC_SECRET,
  boundedTrimmedString,
  assertActiveBurnBarProEntitlement,
} from "./shared.js";
import { issueRemoteMcpGrantForSignedInUser } from "../remoteMcpOAuth.js";
import { revokeRemoteMcpClient as revokeRemoteMcpClientDoc } from "../remoteMcpGrant.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";

export const issueRemoteMcpGrant = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
    secrets: [REMOTE_MCP_TOKEN_HMAC_SECRET],
  },
  wrapCallableHandler(
    "issueRemoteMcpGrant",
    async (
      request: CallableRequest<{
        clientId?: unknown;
        displayName?: unknown;
        clientType?: unknown;
        installFingerprint?: unknown;
        scopes?: unknown;
        grantMode?: unknown;
        nonce?: unknown;
      }>,
    ) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before connecting OpenBurnBar MCP.");
      await enforceHighRiskComputerUseCallableWithNonce(request, uid, request.data.nonce);
      await assertCloudFeatureNotSuspended(db, uid, "remote_mcp");
      await assertActiveBurnBarProEntitlement(uid);
      const tokenSecret = REMOTE_MCP_TOKEN_HMAC_SECRET.value();
      if (!tokenSecret) {
        throw new HttpsError("failed-precondition", "Remote MCP token signing secret is not configured.");
      }
      const scopes = Array.isArray(request.data.scopes)
        ? request.data.scopes.filter(
            (scope): scope is "search:read" | "conversation:read" | "usage:read" | "index:status" | "knowledge:read" =>
              ["search:read", "conversation:read", "usage:read", "index:status", "knowledge:read"].includes(
                String(scope),
              ),
          )
        : undefined;
      const grantModeRaw = typeof request.data.grantMode === "string" ? request.data.grantMode : "local_decrypt_shim";
      const grantMode =
        grantModeRaw === "sealed_only" || grantModeRaw === "remote_readable_explicit_opt_in"
          ? grantModeRaw
          : "local_decrypt_shim";
      const result = await issueRemoteMcpGrantForSignedInUser(db, uid, {
        clientId: boundedTrimmedString(request.data.clientId, "clientId", 160, false),
        displayName: boundedTrimmedString(request.data.displayName, "displayName", 120, false),
        clientType: boundedTrimmedString(request.data.clientType, "clientType", 80, false),
        installFingerprint: boundedTrimmedString(request.data.installFingerprint, "installFingerprint", 512, false),
        scopes,
        grantMode,
        entitlementFamily: "burnbar_pro",
        tokenSecret,
        audience: process.env.REMOTE_MCP_AUDIENCE ?? "https://mcp.burnbar.ai/mcp",
      });
      logInfo({
        event: "callable_info",
        message: "remote_mcp_grant_issued",
        client_id: boundedTrimmedString(request.data.clientId, "clientId", 160, false) ?? "unknown",
        grant_mode: grantMode,
      });
      return result;
    },
  ),
);

export const revokeRemoteMcpClient = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
  },
  wrapCallableHandler("revokeRemoteMcpClient", async (request: CallableRequest<{ clientId?: unknown }>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before revoking OpenBurnBar MCP clients.");
    enforceAuthAndAppCheck(request, uid);
    const clientId = boundedTrimmedString(request.data.clientId, "clientId", 160, true);
    await revokeRemoteMcpClientDoc(db, uid, clientId);
    logInfo({ event: "callable_info", message: "remote_mcp_client_revoked", client_id: clientId });
    return { ok: true, clientId };
  }),
);

// ---------------------------------------------------------------------------
// Callable: searchStreams
// ---------------------------------------------------------------------------

export const searchStreams = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler("searchStreams", async (request: CallableRequest<{ query?: unknown; limit?: unknown }>) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before searching streams.");
    }
    enforceAuthAndAppCheck(request, uid);
    await assertCloudFeatureNotSuspended(db, uid, "remote_mcp");

    const query = boundedTrimmedString(request.data.query, "query", 200, true) ?? "";
    const limitRaw = typeof request.data.limit === "number" ? request.data.limit : 25;
    const limit = Math.max(1, Math.min(Math.floor(limitRaw), 50));
    if (!query) {
      return { hits: [] };
    }
    // Remote MCP cannot derive Cloud Vault search trapdoors without the user's
    // local vault key. The previous implementation queried legacy plaintext
    // `session_logs/{id}/chunks` fields; hardened cloud search must stay empty
    // until the local decrypt shim supplies keyed hashes.
    return { hits: [], encryptedSearchRequired: true, limit };
  }),
);

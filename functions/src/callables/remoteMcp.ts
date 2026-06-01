/**
 * @fileoverview Remote MCP grants and stream search callables
 */

import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "../config.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { enforceHighRiskComputerUseCallable } from "../appCheckAttestation.js";
import { db } from "../adminRuntime.js";
import { assertCloudFeatureNotSuspended } from "../cloudFeatureSuspensions.js";
import { logInfo, wrapCallableHandler } from "../logging.js";
import {
  REMOTE_MCP_TOKEN_HMAC_SECRET,
  boundedTrimmedString,
  normalizedSearchTerms,
  searchScore,
  sha256Hex,
  serializeUsageForCallable,
  assertActiveBurnBarProEntitlement,
} from "./shared.js";
import { issueRemoteMcpGrantForSignedInUser } from "../remoteMcpOAuth.js";
import { revokeRemoteMcpClient as revokeRemoteMcpClientDoc } from "../remoteMcpGrant.js";

export const issueRemoteMcpGrant = onCall(
  {
    region: "us-central1",
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
      }>,
    ) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before connecting OpenBurnBar MCP.");
      enforceHighRiskComputerUseCallable(request, uid);
      await assertCloudFeatureNotSuspended(db, uid, "remote_mcp");
      await assertActiveBurnBarProEntitlement(uid);
      const tokenSecret = REMOTE_MCP_TOKEN_HMAC_SECRET.value();
      if (!tokenSecret) {
        throw new HttpsError("failed-precondition", "Remote MCP token signing secret is not configured.");
      }
      const scopes = Array.isArray(request.data.scopes)
        ? request.data.scopes.filter(
            (scope): scope is "search:read" | "conversation:read" | "usage:read" | "index:status" =>
              ["search:read", "conversation:read", "usage:read", "index:status"].includes(String(scope)),
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
    region: "us-central1",
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
    region: "us-central1",
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
    const terms = normalizedSearchTerms(query);
    if (terms.length === 0) {
      return { hits: [] };
    }

    const chunkSnap = await db
      .collectionGroup("chunks")
      .where("uid", "==", uid)
      .where("terms", "array-contains", terms[0])
      .select("docId", "sessionId", "deviceId", "bodyHash", "title", "snippet", "projectName", "model", "terms")
      .limit(200)
      .get();

    const scored = chunkSnap.docs
      .map((doc) => {
        const data = doc.data();
        const indexedTerms = Array.isArray(data.terms)
          ? data.terms.filter((term): term is string => typeof term === "string")
          : [];
        const haystack = `${data.title ?? ""} ${data.snippet ?? ""} ${data.projectName ?? ""} ${data.model ?? ""} ${indexedTerms.join(" ")}`;
        return { doc, data, score: searchScore(haystack, terms) };
      })
      .filter((item) => item.score > 0)
      .sort((a, b) => b.score - a.score || String(a.data.docId ?? "").localeCompare(String(b.data.docId ?? "")))
      .slice(0, limit * 3);

    const hits: Array<Record<string, unknown>> = [];
    const seenSessions = new Set<string>();

    for (const item of scored) {
      const deviceId = typeof item.data.deviceId === "string" ? item.data.deviceId : "";
      const sessionId = typeof item.data.sessionId === "string" ? item.data.sessionId : "";
      const docId = typeof item.data.docId === "string" ? item.data.docId : "";
      const bodyHash = typeof item.data.bodyHash === "string" ? item.data.bodyHash : "";
      if (!deviceId || !sessionId || !docId || !bodyHash) {
        continue;
      }

      const manifest = await db.doc(`users/${uid}/session_logs/${docId}`).get();
      if (!manifest.exists || manifest.get("bodyHash") !== bodyHash) {
        continue;
      }

      const dedupeKey = `${deviceId}:${sessionId}`;
      if (seenSessions.has(dedupeKey)) {
        continue;
      }

      const usageSnap = await db
        .collection(`users/${uid}/usage`)
        .where("deviceId", "==", deviceId)
        .where("sessionId", "==", sessionId)
        .limit(1)
        .get();
      const usageDoc = usageSnap.docs[0];
      if (!usageDoc) {
        continue;
      }

      const usage = serializeUsageForCallable(usageDoc.id, usageDoc.data());
      seenSessions.add(dedupeKey);
      hits.push({
        id: `${sha256Hex(`${docId}:${item.doc.id}`).slice(0, 16)}_${item.doc.id}`,
        title: item.data.title ?? usage.projectName ?? usage.model ?? "Stream",
        snippet: item.data.snippet ?? "",
        score: item.score / terms.length,
        usage,
      });
      if (hits.length >= limit) {
        break;
      }
    }

    return { hits };
  }),
);

/**
 * @fileoverview Callables and HTTPS endpoints for linking the CLI via device-code flow
 */

import { onRequest } from "firebase-functions/v2/https";
import { onCall, HttpsError, type CallableRequest } from "firebase-functions/v2/https";
import { Timestamp } from "firebase-admin/firestore";
import { randomBytes, createHash } from "node:crypto";
import { db } from "../adminRuntime.js";
import { logError, wrapCallableHandler } from "../logging.js";
import { enforceHighRiskComputerUseCallable } from "../appCheckAttestation.js";
import { assertActiveBurnBarProEntitlement, REMOTE_MCP_TOKEN_HMAC_SECRET } from "./shared.js";
import { issueRemoteMcpGrantForSignedInUser } from "../remoteMcpOAuth.js";
import { getConfig } from "../config.js";
import { isSha256Hex, safeEqualHex } from "../hermesGateway.js";
import {
  assertCallableApprovalNotLocked,
  checkPublicHttpRateLimit,
  clientIpFromHttpRequest,
  recordCallableApprovalFailure,
} from "./publicRateLimit.js";
import { FUNCTIONS_REGION, HOT_PATH_OPTIONS } from "../runtimeOptions.js";

function generateUserCode(): string {
  const chars = "ABCDEFGHJKLMNOPQRSTUVWXYZ23456789"; // Omit confusing chars: 0, 1, I, L
  const bytes = randomBytes(8);
  const code = Array.from(bytes, (byte) => chars.charAt(byte % chars.length)).join("");
  return `${code.slice(0, 4)}-${code.slice(4)}`;
}

/**
 * Public HTTPS endpoint to start a CLI link session.
 * Generates user code, device code, and sets up a pending session.
 */
export const startCliLink = onRequest(
  {
    region: FUNCTIONS_REGION,
    cors: true,
    ...HOT_PATH_OPTIONS,
  },
  async (req, res) => {
    if (req.method !== "POST") {
      res.status(405).json({ error: "method_not_allowed" });
      return;
    }
    try {
      await checkPublicHttpRateLimit(clientIpFromHttpRequest(req), "cli_link_start");
      const { clientType, displayName, deviceSecretHash } = req.body;
      if (!deviceSecretHash || typeof deviceSecretHash !== "string" || !isSha256Hex(deviceSecretHash)) {
        res.status(400).json({ error: "invalid_device_secret_hash" });
        return;
      }
      const normalizedDeviceSecretHash = deviceSecretHash.trim().toLowerCase();

      const deviceCode = randomBytes(24).toString("hex");
      const userCode = generateUserCode();
      const expiresAt = new Date(Date.now() + 10 * 60 * 1000); // 10 minutes

      await db.doc(`cli_link_sessions/${deviceCode}`).set({
        userCode,
        deviceSecretHash: normalizedDeviceSecretHash,
        status: "pending",
        clientType: clientType || "cli",
        displayName: displayName || "CLI Session",
        expiresAt: Timestamp.fromDate(expiresAt),
        createdAt: Timestamp.now(),
      });

      const domain = process.env.BURNBAR_WEBSITE_DOMAIN ?? "https://burnbar.ai";
      const verificationUriComplete = `${domain}/link?code=${userCode}`;

      res.status(200).json({
        deviceCode,
        userCode,
        verificationUriComplete,
        interval: 5,
        expiresIn: 600,
      });
    } catch (err) {
      logError({ event: "cli_link.start_failed", error: String(err) });
      res.status(500).json({ error: "internal" });
    }
  },
);

/**
 * Public HTTPS endpoint for polling CLI link session status.
 * Checks whether user has completed sign-in / linking.
 */
export const pollCliLink = onRequest(
  {
    region: FUNCTIONS_REGION,
    cors: true,
  },
  async (req, res) => {
    if (req.method !== "POST") {
      res.status(405).json({ error: "method_not_allowed" });
      return;
    }
    try {
      const { deviceCode, deviceSecret } = req.body;
      if (!deviceCode || typeof deviceCode !== "string" || !deviceSecret || typeof deviceSecret !== "string") {
        res.status(400).json({ error: "invalid_payload" });
        return;
      }

      const sessionRef = db.doc(`cli_link_sessions/${deviceCode}`);
      const snap = await sessionRef.get();
      if (!snap.exists) {
        res.status(200).json({ status: "expired" });
        return;
      }

      const data = snap.data()!;

      // Verify deviceSecretHash matches sha256(deviceSecret)
      const computedHash = createHash("sha256").update(deviceSecret).digest("hex");
      if (!safeEqualHex(computedHash, data.deviceSecretHash)) {
        res.status(403).json({ error: "invalid_secret" });
        return;
      }

      // Check expiration
      const expiresAt = data.expiresAt as Timestamp;
      if (expiresAt.toDate().getTime() < Date.now()) {
        res.status(200).json({ status: "expired" });
        await sessionRef.delete();
        return;
      }

      if (data.status === "approved") {
        res.status(200).json({
          status: "approved",
          accessToken: data.accessToken,
          expiresIn: data.expiresIn,
          clientId: data.clientId,
          scopes: data.scopes,
          grantMode: data.grantMode,
        });
        await sessionRef.delete();
        return;
      }

      if (data.status === "denied") {
        res.status(200).json({ status: "denied" });
        await sessionRef.delete();
        return;
      }

      res.status(200).json({ status: "authorization_pending" });
    } catch (err) {
      logError({ event: "cli_link.poll_failed", error: String(err) });
      res.status(500).json({ error: "internal" });
    }
  },
);

/**
 * Callable endpoint to approve/complete CLI link from the website after sign-in.
 */
export const completeCliLink = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
    secrets: [REMOTE_MCP_TOKEN_HMAC_SECRET],
  },
  wrapCallableHandler("completeCliLink", async (request: CallableRequest<{ userCode?: unknown }>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before completing CLI link.");
    enforceHighRiskComputerUseCallable(request, uid);
    await assertCallableApprovalNotLocked(uid, "cli_link_approve_fail");
    await assertActiveBurnBarProEntitlement(uid);

    const tokenSecret = REMOTE_MCP_TOKEN_HMAC_SECRET.value();
    if (!tokenSecret) {
      throw new HttpsError("failed-precondition", "Remote MCP token signing secret is not configured.");
    }

    const { userCode } = request.data;
    if (!userCode || typeof userCode !== "string") {
      throw new HttpsError("invalid-argument", "Missing or invalid userCode.");
    }

    // Find the session in Firestore where userCode === userCode and status === "pending"
    const sessionsQuery = await db
      .collection("cli_link_sessions")
      .where("userCode", "==", userCode)
      .where("status", "==", "pending")
      .limit(1)
      .get();

    if (sessionsQuery.empty) {
      await recordCallableApprovalFailure(uid, "cli_link_approve_fail");
      throw new HttpsError("not-found", "No pending link session found for this code.");
    }

    const sessionDoc = sessionsQuery.docs[0];
    const sessionRef = sessionDoc.ref;
    const sessionData = sessionDoc.data();

    // Check expiration
    const expiresAt = sessionData.expiresAt as Timestamp;
    if (expiresAt.toDate().getTime() < Date.now()) {
      await sessionRef.delete();
      throw new HttpsError("failed-precondition", "This link code has expired.");
    }

    // Issue Remote MCP Grant
    const grantResult = await issueRemoteMcpGrantForSignedInUser(db, uid, {
      clientType: sessionData.clientType,
      displayName: sessionData.displayName,
      entitlementFamily: "burnbar_pro",
      tokenSecret,
      audience: process.env.REMOTE_MCP_AUDIENCE ?? "https://mcp.burnbar.ai/mcp",
    });

    // Write resulting token and status to session doc
    await sessionRef.update({
      status: "approved",
      accessToken: grantResult.accessToken,
      expiresIn: grantResult.expiresIn,
      clientId: grantResult.clientId,
      scopes: grantResult.scopes,
      grantMode: grantResult.grantMode,
    });

    return {
      ok: true,
      displayName: sessionData.displayName,
      scopes: grantResult.scopes,
    };
  }),
);

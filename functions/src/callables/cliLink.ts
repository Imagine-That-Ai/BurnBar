/**
 * @fileoverview Callables and HTTPS endpoints for linking the CLI via device-code flow
 */

import { onRequest } from "firebase-functions/v2/https";
import { onCall, HttpsError, type CallableRequest } from "firebase-functions/v2/https";
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { createCipheriv, createECDH, createHash, randomBytes } from "node:crypto";
import { db } from "../adminRuntime.js";
import { assertCloudFeatureNotSuspended } from "../cloudFeatureSuspensions.js";
import { logError, wrapCallableHandler } from "../logging.js";
import { enforceHighRiskComputerUseCallableWithNonce } from "../appCheckAttestation.js";
import {
  assertActiveBurnBarProEntitlement,
  REMOTE_MCP_TOKEN_ED25519_PRIVATE_KEY_BASE64,
  REMOTE_MCP_TOKEN_HMAC_SECRET,
} from "./shared.js";
import { issueRemoteMcpGrantForSignedInUser } from "../remoteMcpOAuth.js";
import { getConfig } from "../config.js";
import { isSha256Hex, safeEqualHex } from "../hermesGateway.js";
import {
  assertCallableApprovalNotLocked,
  checkPublicHttpEndpointRateLimit,
  clientIpFromHttpRequest,
  isPublicRateLimitExceeded,
  recordCallableApprovalFailure,
} from "./publicRateLimit.js";
import { FUNCTIONS_REGION, HOT_PATH_OPTIONS } from "../runtimeOptions.js";
import { setPublicJsonNoStoreHeaders } from "../publicHttpSecurityHeaders.js";

interface CliLinkSessionDoc {
  deviceSecretHash?: string;
  deviceSecretVerifierHash?: string;
  expiresAt: Timestamp;
  status: string;
  accessToken?: string;
  refreshToken?: string;
  expiresIn?: number;
  clientId?: string;
  scopes?: string[];
  grantMode?: string;
  clientType?: string;
  displayName?: string;
  credentialDelivery?: CliLinkCredentialDelivery;
  credentialEnvelope?: CliLinkCredentialEnvelope;
}

const CLI_LINK_SEALING_ALGORITHM = "p256-ecdh-aes-256-gcm-v1";
const CLI_LINK_SEALING_CONTEXT = "OpenBurnBar CLI link credential delivery v1";
const CLI_LINK_SEALING_AAD = "openburnbar:cli-link:credential-delivery:v1";

interface CliLinkCredentialDelivery {
  algorithm: typeof CLI_LINK_SEALING_ALGORITHM;
  publicKeyBase64: string;
}

interface CliLinkCredentialEnvelope {
  algorithm: typeof CLI_LINK_SEALING_ALGORITHM;
  ephemeralPublicKeyBase64: string;
  ivBase64: string;
  ciphertextBase64: string;
  authTagBase64: string;
  aad: string;
}

function readCliLinkSessionData(raw: FirebaseFirestore.DocumentData | undefined): CliLinkSessionDoc | undefined {
  if (raw == null) return undefined;
  const expiresAt = raw.expiresAt;
  if (!(expiresAt instanceof Timestamp)) return undefined;
  if (
    typeof raw.status !== "string" ||
    (typeof raw.deviceSecretVerifierHash !== "string" && typeof raw.deviceSecretHash !== "string")
  ) {
    return undefined;
  }
  return {
    deviceSecretHash: typeof raw.deviceSecretHash === "string" ? raw.deviceSecretHash : undefined,
    deviceSecretVerifierHash:
      typeof raw.deviceSecretVerifierHash === "string" ? raw.deviceSecretVerifierHash : undefined,
    expiresAt,
    status: raw.status,
    accessToken: typeof raw.accessToken === "string" ? raw.accessToken : undefined,
    refreshToken: typeof raw.refreshToken === "string" ? raw.refreshToken : undefined,
    expiresIn: typeof raw.expiresIn === "number" ? raw.expiresIn : undefined,
    clientId: typeof raw.clientId === "string" ? raw.clientId : undefined,
    scopes: Array.isArray(raw.scopes)
      ? raw.scopes.filter((scope): scope is string => typeof scope === "string")
      : undefined,
    grantMode: typeof raw.grantMode === "string" ? raw.grantMode : undefined,
    clientType: typeof raw.clientType === "string" ? raw.clientType : undefined,
    displayName: typeof raw.displayName === "string" ? raw.displayName : undefined,
    credentialDelivery: readCliLinkCredentialDelivery(raw.credentialDelivery),
    credentialEnvelope: readCliLinkCredentialEnvelope(raw.credentialEnvelope),
  };
}

function sha256Hex(value: string | Buffer): string {
  return createHash("sha256").update(value).digest("hex");
}

function cliLinkCredentialDeliveryKey(secret: Buffer): Buffer {
  return createHash("sha256").update(CLI_LINK_SEALING_CONTEXT).update("\0").update(secret).digest();
}

function readCliLinkCredentialDelivery(raw: unknown): CliLinkCredentialDelivery | undefined {
  if (raw == null || typeof raw !== "object") return undefined;
  const algorithm = Reflect.get(raw, "algorithm");
  const publicKeyBase64 = Reflect.get(raw, "publicKeyBase64");
  if (algorithm !== CLI_LINK_SEALING_ALGORITHM || typeof publicKeyBase64 !== "string") return undefined;
  const publicKey = Buffer.from(publicKeyBase64, "base64");
  if (publicKey.length !== 65 || publicKey[0] !== 0x04 || publicKey.toString("base64") !== publicKeyBase64) {
    return undefined;
  }
  try {
    const probe = createECDH("prime256v1");
    probe.generateKeys();
    probe.computeSecret(publicKey);
  } catch {
    return undefined;
  }
  return { algorithm, publicKeyBase64 };
}

function requireCliLinkCredentialDelivery(raw: unknown): CliLinkCredentialDelivery {
  const delivery = readCliLinkCredentialDelivery(raw);
  if (!delivery) {
    throw new HttpsError(
      "invalid-argument",
      "credentialDelivery must contain a valid P-256 public key for credential delivery.",
    );
  }
  return delivery;
}

function readCliLinkCredentialEnvelope(raw: unknown): CliLinkCredentialEnvelope | undefined {
  if (raw == null || typeof raw !== "object") return undefined;
  const algorithm = Reflect.get(raw, "algorithm");
  const ephemeralPublicKeyBase64 = Reflect.get(raw, "ephemeralPublicKeyBase64");
  const ivBase64 = Reflect.get(raw, "ivBase64");
  const ciphertextBase64 = Reflect.get(raw, "ciphertextBase64");
  const authTagBase64 = Reflect.get(raw, "authTagBase64");
  const aad = Reflect.get(raw, "aad");
  if (
    algorithm !== CLI_LINK_SEALING_ALGORITHM ||
    typeof ephemeralPublicKeyBase64 !== "string" ||
    typeof ivBase64 !== "string" ||
    typeof ciphertextBase64 !== "string" ||
    typeof authTagBase64 !== "string" ||
    aad !== CLI_LINK_SEALING_AAD
  ) {
    return undefined;
  }
  return { algorithm, ephemeralPublicKeyBase64, ivBase64, ciphertextBase64, authTagBase64, aad };
}

export function sealCliLinkCredentialsForDelivery(
  delivery: CliLinkCredentialDelivery,
  credentials: {
    accessToken: string;
    refreshToken: string;
    expiresIn: number;
    clientId: string;
    scopes: string[];
    grantMode: string;
  },
): CliLinkCredentialEnvelope {
  const clientPublicKey = Buffer.from(delivery.publicKeyBase64, "base64");
  const ephemeral = createECDH("prime256v1");
  ephemeral.generateKeys();
  const sharedSecret = ephemeral.computeSecret(clientPublicKey);
  const key = cliLinkCredentialDeliveryKey(sharedSecret);
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  cipher.setAAD(Buffer.from(CLI_LINK_SEALING_AAD, "utf8"));
  const plaintext = Buffer.from(JSON.stringify(credentials), "utf8");
  const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  const authTag = cipher.getAuthTag();
  return {
    algorithm: CLI_LINK_SEALING_ALGORITHM,
    ephemeralPublicKeyBase64: ephemeral.getPublicKey("base64", "uncompressed"),
    ivBase64: iv.toString("base64"),
    ciphertextBase64: ciphertext.toString("base64"),
    authTagBase64: authTag.toString("base64"),
    aad: CLI_LINK_SEALING_AAD,
  };
}

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
    setPublicJsonNoStoreHeaders(res);
    if (req.method !== "POST") {
      res.status(405).json({ error: "method_not_allowed" });
      return;
    }
    try {
      await checkPublicHttpEndpointRateLimit("startCliLink", clientIpFromHttpRequest(req));
    } catch (err) {
      if (isPublicRateLimitExceeded(err)) {
        res.status(429).json({ error: "too_many_requests" });
        return;
      }
      logError({ event: "cli_link.start_rate_limit_failed", error: String(err) });
      res.status(500).json({ error: "internal" });
      return;
    }
    try {
      const { clientType, displayName, deviceSecretHash, credentialDelivery } = req.body;
      if (!deviceSecretHash || typeof deviceSecretHash !== "string" || !isSha256Hex(deviceSecretHash)) {
        res.status(400).json({ error: "invalid_device_secret_hash" });
        return;
      }
      const normalizedDeviceSecretHash = deviceSecretHash.trim().toLowerCase();
      const delivery = readCliLinkCredentialDelivery(credentialDelivery);
      if (!delivery) {
        res.status(400).json({ error: "invalid_credential_delivery" });
        return;
      }

      const deviceCode = randomBytes(24).toString("hex");
      const userCode = generateUserCode();
      const expiresAt = new Date(Date.now() + 10 * 60 * 1000); // 10 minutes

      await db.doc(`cli_link_sessions/${deviceCode}`).set({
        userCode,
        deviceSecretVerifierHash: sha256Hex(normalizedDeviceSecretHash),
        credentialDelivery: delivery,
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
    setPublicJsonNoStoreHeaders(res);
    if (req.method !== "POST") {
      res.status(405).json({ error: "method_not_allowed" });
      return;
    }
    try {
      await checkPublicHttpEndpointRateLimit("pollCliLink", clientIpFromHttpRequest(req));
    } catch (err) {
      if (isPublicRateLimitExceeded(err)) {
        res.status(429).json({ error: "too_many_requests" });
        return;
      }
      logError({ event: "cli_link.poll_rate_limit_failed", error: String(err) });
      res.status(500).json({ error: "internal" });
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

      const data = readCliLinkSessionData(snap.data());
      if (data == null) {
        res.status(200).json({ status: "expired" });
        return;
      }

      // Verify deviceSecretHash matches sha256(deviceSecret)
      const computedHash = sha256Hex(deviceSecret);
      const verifierHash = sha256Hex(computedHash);
      const matchesCurrentVerifier =
        typeof data.deviceSecretVerifierHash === "string" && safeEqualHex(verifierHash, data.deviceSecretVerifierHash);
      const matchesLegacyVerifier =
        typeof data.deviceSecretHash === "string" && safeEqualHex(computedHash, data.deviceSecretHash);
      if (!matchesCurrentVerifier && !matchesLegacyVerifier) {
        res.status(403).json({ error: "invalid_secret" });
        return;
      }

      // Check expiration
      if (data.expiresAt.toDate().getTime() < Date.now()) {
        res.status(200).json({ status: "expired" });
        await sessionRef.delete();
        return;
      }

      if (data.status === "approved") {
        if (data.credentialEnvelope) {
          res.status(200).json({
            status: "approved",
            credentialEnvelope: data.credentialEnvelope,
          });
          await sessionRef.delete();
          return;
        }
        res.status(200).json({
          status: "approved",
          accessToken: data.accessToken,
          refreshToken: data.refreshToken,
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
    secrets: [REMOTE_MCP_TOKEN_HMAC_SECRET, REMOTE_MCP_TOKEN_ED25519_PRIVATE_KEY_BASE64],
  },
  wrapCallableHandler("completeCliLink", async (request: CallableRequest<{ userCode?: unknown; nonce?: unknown }>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before completing CLI link.");
    await enforceHighRiskComputerUseCallableWithNonce(request, uid, request.data.nonce);
    await assertCallableApprovalNotLocked(uid, "cli_link_approve_fail");
    await assertCloudFeatureNotSuspended(db, uid, "remote_mcp");
    await assertActiveBurnBarProEntitlement(uid);

    const tokenSecret = REMOTE_MCP_TOKEN_HMAC_SECRET.value();
    const tokenEd25519PrivateKeyBase64PEM = REMOTE_MCP_TOKEN_ED25519_PRIVATE_KEY_BASE64.value();
    if (!tokenSecret && !tokenEd25519PrivateKeyBase64PEM) {
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
    const sessionData = readCliLinkSessionData(sessionDoc.data());
    if (sessionData == null) {
      await sessionRef.delete();
      throw new HttpsError("failed-precondition", "This link code has expired.");
    }

    // Check expiration
    if (sessionData.expiresAt.toDate().getTime() < Date.now()) {
      await sessionRef.delete();
      throw new HttpsError("failed-precondition", "This link code has expired.");
    }

    const credentialDelivery = requireCliLinkCredentialDelivery(sessionData.credentialDelivery);

    // Issue Remote MCP Grant
    const grantResult = await issueRemoteMcpGrantForSignedInUser(db, uid, {
      clientType: sessionData.clientType,
      displayName: sessionData.displayName,
      entitlementFamily: "burnbar_pro",
      tokenSecret,
      tokenEd25519PrivateKeyBase64PEM,
      audience: process.env.REMOTE_MCP_AUDIENCE ?? "https://mcp.burnbar.ai/mcp",
    });

    const credentialEnvelope = sealCliLinkCredentialsForDelivery(credentialDelivery, {
      accessToken: grantResult.accessToken,
      refreshToken: grantResult.refreshToken,
      expiresIn: grantResult.expiresIn,
      clientId: grantResult.clientId,
      scopes: grantResult.scopes,
      grantMode: grantResult.grantMode,
    });

    // Store only a sealed credential envelope on the transient polling document.
    // The polling device must still prove possession of the device secret, and
    // only its locally-held delivery private key can open the returned envelope.
    await sessionRef.update({
      status: "approved",
      credentialEnvelope,
      accessToken: FieldValue.delete(),
      refreshToken: FieldValue.delete(),
      expiresIn: FieldValue.delete(),
      clientId: FieldValue.delete(),
      scopes: FieldValue.delete(),
      grantMode: FieldValue.delete(),
      tokenSigningAlgorithm: grantResult.tokenSigningAlgorithm,
    });

    return {
      ok: true,
      displayName: sessionData.displayName,
      scopes: grantResult.scopes,
    };
  }),
);

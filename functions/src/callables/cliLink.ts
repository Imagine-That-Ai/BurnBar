/**
 * @fileoverview Callables and HTTPS endpoints for linking the CLI via device-code flow
 */

import { onRequest } from "firebase-functions/v2/https";
import { onCall, HttpsError, type CallableRequest } from "firebase-functions/v2/https";
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { createCipheriv, createECDH, createHash, randomBytes } from "node:crypto";
import { auth, db } from "../adminRuntime.js";
import { assertCloudFeatureNotSuspended } from "../cloudFeatureSuspensions.js";
import { logError, wrapCallableHandler } from "../logging.js";
import { enforceHighRiskComputerUseCallableWithNonce } from "../appCheckAttestation.js";
import { assertActiveBurnBarProEntitlement, REMOTE_MCP_TOKEN_ED25519_PRIVATE_KEY_BASE64 } from "./shared.js";
import { remoteMcpTokenHmacSecretValueForRuntime, remoteMcpTokenSigningSecrets } from "./remoteMcpSigningSecrets.js";
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
import {
  claimCliLinkSessionForApproval,
  finalizeCliLinkApproval,
  finalizeCliLinkApprovalWithWrites,
  releaseCliLinkApprovalClaim,
} from "./cliLinkApprovalLease.js";
import { resolveCliLinkFirebaseWebAPIKey } from "./cliLinkFirebaseConfig.js";

export interface CliLinkSessionDoc {
  deviceSecretHash?: string; deviceSecretVerifierHash?: string; userCode: string; expiresAt: Timestamp;
  status: CliLinkSessionStatus; purpose: CliLinkPurpose; clientType?: string; displayName?: string;
  credentialDelivery?: CliLinkCredentialDelivery; credentialEnvelope?: CliLinkCredentialEnvelope; approvalClaimUid?: string; approvalClaimID?: string; approvalClaimedAt?: Timestamp;
}

export type CliLinkPurpose = "remote_mcp" | "desktop_auth";
export type CliLinkSessionStatus = "pending" | "approving" | "approved" | "denied";

const CLI_LINK_REMOTE_MCP_SEALING_ALGORITHM = "p256-ecdh-aes-256-gcm-v1";
const CLI_LINK_DESKTOP_AUTH_SEALING_ALGORITHM = "p256-ecdh-aes-256-gcm-v2";
const CLI_LINK_REMOTE_MCP_SEALING_CONTEXT = "OpenBurnBar CLI link credential delivery v1";
const CLI_LINK_REMOTE_MCP_SEALING_AAD = "openburnbar:cli-link:credential-delivery:v1";
const CLI_LINK_DESKTOP_AUTH_SEALING_CONTEXT = "OpenBurnBar desktop auth credential delivery v2";
const CLI_LINK_DESKTOP_AUTH_AAD_PREFIX = "openburnbar:desktop-auth:credential-delivery:v2:";
const CLI_LINK_DEFAULT_PURPOSE: CliLinkPurpose = "remote_mcp";
const CLI_LINK_USER_CODE_PATTERN = /^[A-HJ-KM-NP-Z2-9]{8}$/u;
const CLI_LINK_UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;
const CLI_LINK_BASE64URL_128_PATTERN = /^[A-Za-z0-9_-]{22}$/u;

interface CliLinkCredentialDelivery {
  algorithm: typeof CLI_LINK_REMOTE_MCP_SEALING_ALGORITHM | typeof CLI_LINK_DESKTOP_AUTH_SEALING_ALGORITHM;
  publicKeyBase64: string;
  flowBinding?: string;
}

interface CliLinkCredentialEnvelope {
  algorithm: typeof CLI_LINK_REMOTE_MCP_SEALING_ALGORITHM | typeof CLI_LINK_DESKTOP_AUTH_SEALING_ALGORITHM;
  ephemeralPublicKeyBase64: string;
  ivBase64: string;
  ciphertextBase64: string;
  authTagBase64: string;
  aad: string;
}

function readCliLinkSessionData(raw: FirebaseFirestore.DocumentData | undefined): CliLinkSessionDoc | undefined {
  if (raw == null) return undefined;
  const expiresAt = raw.expiresAt;
  const purpose = readCliLinkPurpose(raw.purpose, true);
  const status = readCliLinkSessionStatus(raw.status);
  const userCode = canonicalCliLinkUserCode(raw.userCode);
  if (!(expiresAt instanceof Timestamp)) return undefined;
  if (
    !purpose ||
    !status ||
    !userCode ||
    (typeof raw.deviceSecretVerifierHash !== "string" && typeof raw.deviceSecretHash !== "string")
  ) {
    return undefined;
  }
  const credentialDelivery = readCliLinkCredentialDelivery(raw.credentialDelivery, purpose);
  return {
    deviceSecretHash: typeof raw.deviceSecretHash === "string" ? raw.deviceSecretHash : undefined,
    deviceSecretVerifierHash:
      typeof raw.deviceSecretVerifierHash === "string" ? raw.deviceSecretVerifierHash : undefined,
    userCode,
    expiresAt,
    status,
    purpose,
    clientType: typeof raw.clientType === "string" ? raw.clientType : undefined,
    displayName: typeof raw.displayName === "string" ? raw.displayName : undefined,
    credentialDelivery,
    credentialEnvelope: readCliLinkCredentialEnvelope(raw.credentialEnvelope, purpose, credentialDelivery),
    approvalClaimUid: typeof raw.approvalClaimUid === "string" ? raw.approvalClaimUid : undefined,
    approvalClaimID: typeof raw.approvalClaimID === "string" ? raw.approvalClaimID : undefined,
    approvalClaimedAt: raw.approvalClaimedAt instanceof Timestamp ? raw.approvalClaimedAt : undefined,
  };
}

function readCliLinkPurpose(raw: unknown, allowLegacyDefault: boolean): CliLinkPurpose | undefined {
  if (raw == null && allowLegacyDefault) return CLI_LINK_DEFAULT_PURPOSE;
  return raw === "remote_mcp" || raw === "desktop_auth" ? raw : undefined;
}

function readCliLinkSessionStatus(raw: unknown): CliLinkSessionStatus | undefined {
  return raw === "pending" || raw === "approving" || raw === "approved" || raw === "denied" ? raw : undefined;
}

function approvedCliLinkSessionUpdate(
  credentialEnvelope: CliLinkCredentialEnvelope,
  tokenSigningAlgorithm: string | FieldValue = FieldValue.delete(),
): FirebaseFirestore.UpdateData<FirebaseFirestore.DocumentData> {
  return {
    status: "approved",
    credentialEnvelope,
    approvalClaimUid: FieldValue.delete(),
    approvalClaimID: FieldValue.delete(),
    approvalClaimedAt: FieldValue.delete(),
    accessToken: FieldValue.delete(),
    refreshToken: FieldValue.delete(),
    expiresIn: FieldValue.delete(),
    clientId: FieldValue.delete(),
    scopes: FieldValue.delete(),
    grantMode: FieldValue.delete(),
    tokenSigningAlgorithm,
    approvedAt: Timestamp.now(),
  };
}

export function canonicalCliLinkUserCode(raw: unknown): string | undefined {
  if (typeof raw !== "string") return undefined;
  const compact = raw.trim().toUpperCase().replaceAll("-", "");
  if (!CLI_LINK_USER_CODE_PATTERN.test(compact)) return undefined;
  return `${compact.slice(0, 4)}-${compact.slice(4)}`;
}

function readCliLinkFlowBinding(raw: unknown): string | undefined {
  if (typeof raw !== "string") return undefined;
  const value = raw.trim();
  if (value.length === 0 || value.length > 64) return undefined;
  if (CLI_LINK_UUID_PATTERN.test(value)) return value;
  if (!CLI_LINK_BASE64URL_128_PATTERN.test(value)) return undefined;
  const bytes = Buffer.from(value, "base64url");
  return bytes.length === 16 && bytes.toString("base64url") === value ? value : undefined;
}

function sha256Hex(value: string | Buffer): string {
  return createHash("sha256").update(value).digest("hex");
}

function cliLinkCredentialDeliveryKey(secret: Buffer, context: string): Buffer {
  return createHash("sha256").update(context).update("\0").update(secret).digest();
}

function readCliLinkCredentialDelivery(raw: unknown, purpose: CliLinkPurpose): CliLinkCredentialDelivery | undefined {
  if (raw == null || typeof raw !== "object") return undefined;
  const algorithm = Reflect.get(raw, "algorithm");
  const publicKeyBase64 = Reflect.get(raw, "publicKeyBase64");
  const expectedAlgorithm =
    purpose === "desktop_auth" ? CLI_LINK_DESKTOP_AUTH_SEALING_ALGORITHM : CLI_LINK_REMOTE_MCP_SEALING_ALGORITHM;
  if (algorithm !== expectedAlgorithm || typeof publicKeyBase64 !== "string") return undefined;
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
  if (purpose === "desktop_auth") {
    const flowBinding = readCliLinkFlowBinding(Reflect.get(raw, "flowBinding"));
    if (!flowBinding) return undefined;
    return { algorithm, publicKeyBase64, flowBinding };
  }
  return { algorithm, publicKeyBase64 };
}

function requireCliLinkCredentialDelivery(raw: unknown, purpose: CliLinkPurpose): CliLinkCredentialDelivery {
  const delivery = readCliLinkCredentialDelivery(raw, purpose);
  if (!delivery) {
    throw new HttpsError(
      "invalid-argument",
      purpose === "desktop_auth"
        ? "credentialDelivery must contain a valid P-256 public key and 128-bit flowBinding."
        : "credentialDelivery must contain a valid P-256 public key for credential delivery.",
    );
  }
  return delivery;
}

function desktopAuthAAD(flowBinding: string): string {
  return `${CLI_LINK_DESKTOP_AUTH_AAD_PREFIX}${flowBinding}`;
}

function readCliLinkCredentialEnvelope(
  raw: unknown,
  purpose: CliLinkPurpose,
  delivery: CliLinkCredentialDelivery | undefined,
): CliLinkCredentialEnvelope | undefined {
  if (raw == null || typeof raw !== "object") return undefined;
  const algorithm = Reflect.get(raw, "algorithm");
  const ephemeralPublicKeyBase64 = Reflect.get(raw, "ephemeralPublicKeyBase64");
  const ivBase64 = Reflect.get(raw, "ivBase64");
  const ciphertextBase64 = Reflect.get(raw, "ciphertextBase64");
  const authTagBase64 = Reflect.get(raw, "authTagBase64");
  const aad = Reflect.get(raw, "aad");
  const expectedAlgorithm =
    purpose === "desktop_auth" ? CLI_LINK_DESKTOP_AUTH_SEALING_ALGORITHM : CLI_LINK_REMOTE_MCP_SEALING_ALGORITHM;
  const expectedAAD =
    purpose === "desktop_auth" && delivery?.flowBinding
      ? desktopAuthAAD(delivery.flowBinding)
      : CLI_LINK_REMOTE_MCP_SEALING_AAD;
  if (
    algorithm !== expectedAlgorithm ||
    typeof ephemeralPublicKeyBase64 !== "string" ||
    typeof ivBase64 !== "string" ||
    typeof ciphertextBase64 !== "string" ||
    typeof authTagBase64 !== "string" ||
    aad !== expectedAAD
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
  return sealCliLinkPayloadForDelivery(
    delivery,
    CLI_LINK_REMOTE_MCP_SEALING_CONTEXT,
    CLI_LINK_REMOTE_MCP_SEALING_AAD,
    credentials,
  );
}

export function sealCliLinkDesktopAuthTokenForDelivery(
  delivery: CliLinkCredentialDelivery,
  credentials: {
    firebaseCustomToken: string;
    apiKey: string;
    projectId: string;
  },
): CliLinkCredentialEnvelope {
  if (!delivery.flowBinding) {
    throw new HttpsError("invalid-argument", "Desktop auth credential delivery requires flowBinding.");
  }
  return sealCliLinkPayloadForDelivery(
    delivery,
    CLI_LINK_DESKTOP_AUTH_SEALING_CONTEXT,
    desktopAuthAAD(delivery.flowBinding),
    {
      schemaVersion: 1,
      purpose: "desktop_auth",
      credentialKind: "firebase_custom_token",
      ...credentials,
    },
  );
}

function sealCliLinkPayloadForDelivery(
  delivery: CliLinkCredentialDelivery,
  context: string,
  aad: string,
  credentials: object,
): CliLinkCredentialEnvelope {
  const clientPublicKey = Buffer.from(delivery.publicKeyBase64, "base64");
  const ephemeral = createECDH("prime256v1");
  ephemeral.generateKeys();
  const sharedSecret = ephemeral.computeSecret(clientPublicKey);
  const key = cliLinkCredentialDeliveryKey(sharedSecret, context);
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  cipher.setAAD(Buffer.from(aad, "utf8"));
  const plaintext = Buffer.from(JSON.stringify(credentials), "utf8");
  const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  const authTag = cipher.getAuthTag();
  return {
    algorithm: delivery.algorithm,
    ephemeralPublicKeyBase64: ephemeral.getPublicKey("base64", "uncompressed"),
    ivBase64: iv.toString("base64"),
    ciphertextBase64: ciphertext.toString("base64"),
    authTagBase64: authTag.toString("base64"),
    aad,
  };
}

function generateUserCode(): string {
  const chars = "ABCDEFGHJKLMNOPQRSTUVWXYZ23456789"; // Omit confusing chars: 0, 1, I, L
  const bytes = randomBytes(8);
  const code = Array.from(bytes, (byte) => chars.charAt(byte % chars.length)).join("");
  return `${code.slice(0, 4)}-${code.slice(4)}`;
}

function boundedCliLinkLabel(raw: unknown, fallback: string, maxLength: number): string {
  if (typeof raw !== "string") return fallback;
  const value = raw.trim();
  return value.length > 0 && value.length <= maxLength ? value : fallback;
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
      const { clientType, displayName, deviceSecretHash, credentialDelivery, purpose: rawPurpose } = req.body;
      const purpose = readCliLinkPurpose(rawPurpose, true);
      if (!purpose) {
        res.status(400).json({ error: "invalid_purpose" });
        return;
      }
      if (!deviceSecretHash || typeof deviceSecretHash !== "string" || !isSha256Hex(deviceSecretHash)) {
        res.status(400).json({ error: "invalid_device_secret_hash" });
        return;
      }
      const normalizedDeviceSecretHash = deviceSecretHash.trim().toLowerCase();
      const delivery = readCliLinkCredentialDelivery(credentialDelivery, purpose);
      if (!delivery) {
        res.status(400).json({ error: "invalid_credential_delivery" });
        return;
      }

      const deviceCode = randomBytes(24).toString("hex");
      const userCode = generateUserCode();
      const expiresAt = new Date(Date.now() + 10 * 60 * 1000); // 10 minutes
      const resolvedClientType =
        purpose === "desktop_auth" ? "linux_desktop" : boundedCliLinkLabel(clientType, "cli", 48);
      const resolvedDisplayName =
        purpose === "desktop_auth" ? "OpenBurnBar Linux desktop" : boundedCliLinkLabel(displayName, "CLI Session", 96);

      await db.doc(`cli_link_sessions/${deviceCode}`).set({
        userCode,
        purpose,
        deviceSecretVerifierHash: sha256Hex(normalizedDeviceSecretHash),
        credentialDelivery: delivery,
        status: "pending",
        clientType: resolvedClientType,
        displayName: resolvedDisplayName,
        expiresAt: Timestamp.fromDate(expiresAt),
        createdAt: Timestamp.now(),
      });

      const domain = process.env.BURNBAR_WEBSITE_DOMAIN ?? "https://burnbar.ai";
      const verificationUriComplete = `${domain}/link?code=${encodeURIComponent(userCode)}&flow=${purpose}`;

      res.status(200).json({
        deviceCode,
        userCode,
        purpose,
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
      const { deviceCode, deviceSecret, action = "poll" } = req.body;
      if (!deviceCode || typeof deviceCode !== "string" || !deviceSecret || typeof deviceSecret !== "string") {
        res.status(400).json({ error: "invalid_payload" });
        return;
      }
      if (action !== "poll" && action !== "cancel") {
        res.status(400).json({ error: "invalid_action" });
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

      if (action === "cancel") {
        await sessionRef.delete();
        res.status(200).json({ status: "cancelled" });
        return;
      }

      if (data.status === "approved") {
        if (data.credentialEnvelope) {
          res.status(200).json({
            status: "approved",
            purpose: data.purpose,
            credentialEnvelope: data.credentialEnvelope,
          });
          // Keep the client-bound sealed envelope available until the short
          // session TTL so a lost HTTP response can be retried idempotently.
          return;
        }
        await sessionRef.delete();
        res.status(200).json({ status: "expired" });
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
    secrets: remoteMcpTokenSigningSecrets(),
  },
  wrapCallableHandler(
    "completeCliLink",
    async (
      request: CallableRequest<{
        userCode?: unknown;
        expectedPurpose?: unknown;
        nonce?: unknown;
      }>,
    ) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before completing CLI link.");
      await enforceHighRiskComputerUseCallableWithNonce(request, uid, request.data.nonce);
      await assertCallableApprovalNotLocked(uid, "cli_link_approve_fail");

      const userCode = canonicalCliLinkUserCode(request.data.userCode);
      if (!userCode) throw new HttpsError("invalid-argument", "Missing or invalid userCode.");
      const expectedPurpose = readCliLinkPurpose(request.data.expectedPurpose, true);
      if (!expectedPurpose) throw new HttpsError("invalid-argument", "Missing or invalid expectedPurpose.");

      const sessionsQuery = await db.collection("cli_link_sessions").where("userCode", "==", userCode).limit(3).get();
      const activeSessions = sessionsQuery.docs.filter((document) => {
        const session = readCliLinkSessionData(document.data());
        return (
          session != null &&
          session.expiresAt.toMillis() >= Date.now() &&
          (session.status === "pending" || session.status === "approving")
        );
      });

      if (activeSessions.length === 0) {
        await recordCallableApprovalFailure(uid, "cli_link_approve_fail");
        throw new HttpsError("not-found", "No pending link session found for this code.");
      }
      if (activeSessions.length !== 1) {
        await recordCallableApprovalFailure(uid, "cli_link_approve_fail");
        throw new HttpsError("failed-precondition", "This link code is ambiguous. Start a new link session.");
      }

      const sessionRef = activeSessions[0].ref;
      const { session: sessionData, claimID } = await claimCliLinkSessionForApproval(
        db,
        sessionRef,
        uid,
        expectedPurpose,
        readCliLinkSessionData,
      );

      try {
        const credentialDelivery = requireCliLinkCredentialDelivery(
          sessionData.credentialDelivery,
          sessionData.purpose,
        );
        if (sessionData.purpose === "desktop_auth") {
          const firebaseCustomToken = await auth.createCustomToken(uid);
          const config = getConfig();
          let firebaseWebAPIKey: string;
          try {
            firebaseWebAPIKey = resolveCliLinkFirebaseWebAPIKey(config.projectId, config.firebaseWebAPIKey);
          } catch (error) {
            throw new HttpsError(
              "failed-precondition",
              error instanceof Error ? error.message : "Firebase config invalid.",
            );
          }
          const credentialEnvelope = sealCliLinkDesktopAuthTokenForDelivery(credentialDelivery, {
            firebaseCustomToken,
            apiKey: firebaseWebAPIKey,
            projectId: config.projectId,
          });
          await finalizeCliLinkApproval(db, sessionRef, uid, claimID, approvedCliLinkSessionUpdate(credentialEnvelope));
          return {
            ok: true,
            purpose: sessionData.purpose,
            displayName: sessionData.displayName,
          };
        }

        await assertCloudFeatureNotSuspended(db, uid, "remote_mcp");
        await assertActiveBurnBarProEntitlement(uid);
        const tokenSecret = remoteMcpTokenHmacSecretValueForRuntime();
        const tokenEd25519PrivateKeyBase64PEM = REMOTE_MCP_TOKEN_ED25519_PRIVATE_KEY_BASE64.value();
        if (!tokenSecret && !tokenEd25519PrivateKeyBase64PEM) {
          throw new HttpsError("failed-precondition", "Remote MCP token signing secret is not configured.");
        }
        const scopes = await finalizeCliLinkApprovalWithWrites(db, sessionRef, uid, claimID, async (writer) => {
          const grantResult = await issueRemoteMcpGrantForSignedInUser(writer, uid, {
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
          return {
            update: approvedCliLinkSessionUpdate(credentialEnvelope, grantResult.tokenSigningAlgorithm),
            result: grantResult.scopes,
          };
        });

        return {
          ok: true,
          purpose: sessionData.purpose,
          displayName: sessionData.displayName,
          scopes,
        };
      } catch (error) {
        try {
          await releaseCliLinkApprovalClaim(db, sessionRef, uid, claimID);
        } catch (releaseError) {
          logError({ event: "cli_link.release_approval_claim_failed", error: String(releaseError) });
        }
        throw error;
      }
    },
  ),
);

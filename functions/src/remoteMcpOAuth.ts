import { createHash, createHmac, createPrivateKey, randomBytes, sign as signDetached } from "node:crypto";
import { Timestamp, type Firestore } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";
import {
  createRemoteMcpGrant,
  hashRemoteMcpSecret,
  type RemoteMcpGrantMode,
  type RemoteMcpScope,
  upsertRemoteMcpClient,
} from "./remoteMcpGrant.js";

export interface RemoteMcpAccessClaims {
  sub: string;
  aud: string;
  client_id: string;
  scopes: RemoteMcpScope[];
  entitlement_family: "burnbar_pro" | "hosted_quota_sync";
  grant_mode: RemoteMcpGrantMode;
  exp: number;
  jti: string;
}

function privateKeyFromBase64PEM(value: string) {
  return createPrivateKey(Buffer.from(value, "base64").toString("utf8"));
}

export function signRemoteMcpAccessToken(
  claims: RemoteMcpAccessClaims,
  secret?: string,
  ed25519PrivateKeyBase64PEM?: string,
): { token: string; algorithm: "ed25519" | "hmac-sha256" } {
  const body = Buffer.from(JSON.stringify(claims)).toString("base64url");
  if (ed25519PrivateKeyBase64PEM) {
    const sig = signDetached(null, Buffer.from(body), privateKeyFromBase64PEM(ed25519PrivateKeyBase64PEM)).toString("base64url");
    return { token: `ed25519.${body}.${sig}`, algorithm: "ed25519" };
  }
  if (!secret) {
    throw new HttpsError("failed-precondition", "Remote MCP token signer is not configured.");
  }
  const sig = createHmac("sha256", secret).update(body).digest("base64url");
  return { token: `${body}.${sig}`, algorithm: "hmac-sha256" };
}

export function assertPkce(verifier: string, challenge: string): void {
  const actual = Buffer.from(createHash("sha256").update(verifier).digest()).toString("base64url");
  if (actual !== challenge) {
    throw new HttpsError("permission-denied", "PKCE challenge verification failed.");
  }
}

export async function issueRemoteMcpGrantForSignedInUser(
  db: Firestore,
  uid: string,
  input: {
    clientId?: string;
    displayName?: string;
    clientType?: string;
    installFingerprint?: string;
    scopes?: RemoteMcpScope[];
    grantMode?: RemoteMcpGrantMode;
    entitlementFamily: "burnbar_pro" | "hosted_quota_sync";
    entitlementExpiresAt?: string;
    tokenSecret?: string;
    tokenEd25519PrivateKeyBase64PEM?: string;
    audience: string;
  },
) {
  const clientId = input.clientId?.trim() || `obbc_${randomBytes(12).toString("hex")}`;
  const scopes: RemoteMcpScope[] = input.scopes?.length
    ? input.scopes
    : ["search:read", "conversation:read", "usage:read", "index:status", "knowledge:read"];
  const grantMode = input.grantMode ?? "local_decrypt_shim";
  await upsertRemoteMcpClient(db, uid, {
    clientId,
    displayName: input.displayName?.trim() || "OpenBurnBar MCP client",
    clientType: input.clientType?.trim() || "generic",
    installFingerprint: input.installFingerprint,
    allowedScopes: scopes,
    grantMode,
  });
  const { grant, refreshToken } = await createRemoteMcpGrant(db, uid, {
    clientId,
    scopes,
    entitlementFamily: input.entitlementFamily,
    entitlementExpiresAt: input.entitlementExpiresAt,
  });
  const signedAccessToken = signRemoteMcpAccessToken(
    {
      sub: uid,
      aud: input.audience,
      client_id: clientId,
      scopes,
      entitlement_family: input.entitlementFamily,
      grant_mode: grantMode,
      exp: Math.floor(Date.now() / 1000) + 15 * 60,
      jti: `mcp_${randomBytes(16).toString("hex")}`,
    },
    input.tokenSecret,
    input.tokenEd25519PrivateKeyBase64PEM,
  );
  await db.doc(`users/${uid}/remote_mcp_audit_events/${Date.now()}_${grant.grantId}`).set({
    eventKind: "grant_issued",
    hashedClientID: hashRemoteMcpSecret(clientId),
    scopes,
    entitlementSource: input.entitlementFamily,
    createdAt: Timestamp.now(),
    schemaVersion: 1,
  });
  return {
    tokenType: "Bearer",
    accessToken: signedAccessToken.token,
    tokenSigningAlgorithm: signedAccessToken.algorithm,
    expiresIn: 15 * 60,
    refreshToken,
    clientId,
    scopes,
    grantMode,
  };
}

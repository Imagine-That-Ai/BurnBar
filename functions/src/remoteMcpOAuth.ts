import { createHash, createHmac, randomBytes } from "node:crypto";
import { Timestamp, type Firestore } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";
import {
  createRemoteMcpGrant,
  hashRemoteMcpSecret,
  type RemoteMcpGrantMode,
  type RemoteMcpScope,
  upsertRemoteMcpClient
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

export function signRemoteMcpAccessToken(claims: RemoteMcpAccessClaims, secret: string): string {
  const body = Buffer.from(JSON.stringify(claims)).toString("base64url");
  const sig = createHmac("sha256", secret).update(body).digest("base64url");
  return `${body}.${sig}`;
}

export function assertPkce(verifier: string, challenge: string): void {
  const actual = Buffer.from(
    createHash("sha256").update(verifier).digest()
  ).toString("base64url");
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
    tokenSecret: string;
    audience: string;
  }
) {
  const clientId = input.clientId?.trim() || `obbc_${randomBytes(12).toString("hex")}`;
  const scopes: RemoteMcpScope[] = input.scopes?.length
    ? input.scopes
    : ["search:read", "conversation:read", "usage:read", "index:status"];
  const grantMode = input.grantMode ?? "local_decrypt_shim";
  await upsertRemoteMcpClient(db, uid, {
    clientId,
    displayName: input.displayName?.trim() || "OpenBurnBar MCP client",
    clientType: input.clientType?.trim() || "generic",
    installFingerprint: input.installFingerprint,
    allowedScopes: scopes,
    grantMode
  });
  const { grant, refreshToken } = await createRemoteMcpGrant(db, uid, {
    clientId,
    scopes,
    entitlementFamily: input.entitlementFamily,
    entitlementExpiresAt: input.entitlementExpiresAt
  });
  const accessToken = signRemoteMcpAccessToken({
    sub: uid,
    aud: input.audience,
    client_id: clientId,
    scopes,
    entitlement_family: input.entitlementFamily,
    grant_mode: grantMode,
    exp: Math.floor(Date.now() / 1000) + 15 * 60,
    jti: `mcp_${randomBytes(16).toString("hex")}`
  }, input.tokenSecret);
  await db.doc(`users/${uid}/remote_mcp_audit_events/${Date.now()}_${grant.grantId}`).set({
    eventKind: "grant_issued",
    hashedClientID: hashRemoteMcpSecret(clientId),
    scopes,
    entitlementSource: input.entitlementFamily,
    createdAt: Timestamp.now(),
    schemaVersion: 1
  });
  return {
    tokenType: "Bearer",
    accessToken,
    expiresIn: 15 * 60,
    refreshToken,
    clientId,
    scopes,
    grantMode
  };
}

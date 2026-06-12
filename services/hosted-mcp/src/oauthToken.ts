import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { mintDevelopmentToken, verifyAccessTokenString, type AccessTokenClaims } from "./auth.js";
import { MCP_RESOURCE } from "./config.js";
import { requireActiveBurnBarPro, requireActiveRemoteMcpClient } from "./entitlements.js";
import { HttpError } from "./errors.js";
import type { RemoteMcpClientFirestore } from "./firestoreTypes.js";

const ACCESS_TOKEN_TTL_SECONDS = 15 * 60;

/**
 * Minimal grant document shape read/rotated by the refresh path. Mirrors
 * RemoteMcpGrantDoc in functions/src/remoteMcpGrant.ts (the writer of these docs).
 */
export interface GrantDocLike {
  id: string;
  get(field: string): unknown;
  ref: { set(value: unknown, options?: unknown): Promise<unknown> };
}

export interface GrantQuery {
  get(): Promise<{ docs: GrantDocLike[] }>;
}

export interface GrantCollection {
  where(field: string, op: "==", value: unknown): { limit(count: number): GrantQuery };
}

/** Firestore surface the refresh path needs: grant collection + the entitlement/client doc reads. */
export interface RefreshFirestore extends RemoteMcpClientFirestore {
  collection(path: string): GrantCollection;
}

export interface RefreshTokenRequest {
  grantType?: unknown;
  refreshToken?: unknown;
  /** The expiring/expired access token, used to locate the grant being rotated. */
  accessToken?: unknown;
}

export interface RefreshTokenResponse {
  token_type: "Bearer";
  access_token: string;
  expires_in: number;
  refresh_token: string;
  scope: string;
  client_id: string;
}

function hashSecret(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

function randomSecret(prefix: string): string {
  return `${prefix}_${randomBytes(32).toString("base64url")}`;
}

function safeEqualHash(raw: string, expectedHash: unknown): boolean {
  if (typeof expectedHash !== "string" || expectedHash.length === 0) return false;
  let expected: Buffer;
  try {
    expected = Buffer.from(expectedHash, "hex");
  } catch {
    return false;
  }
  const actual = Buffer.from(hashSecret(raw), "hex");
  return actual.length === expected.length && actual.length > 0 && timingSafeEqual(actual, expected);
}

function toMillis(raw: unknown): number | undefined {
  if (raw && typeof raw === "object" && "toMillis" in raw && typeof (raw as { toMillis: unknown }).toMillis === "function") {
    return (raw as { toMillis(): number }).toMillis();
  }
  if (raw instanceof Date) return raw.getTime();
  if (typeof raw === "string") {
    const ms = new Date(raw).getTime();
    return Number.isNaN(ms) ? undefined : ms;
  }
  if (typeof raw === "number") return raw;
  return undefined;
}

/**
 * RFC 6749 §6 refresh-token grant. Verifies the presented refresh token against the
 * stored refreshTokenHash, re-checks client revocation + Pro entitlement + grant
 * expiry/revocation, then ROTATES the refresh token and re-mints a 15-minute access
 * token. The grant doc is the same one functions/src/remoteMcpGrant.ts writes.
 */
export async function handleRefreshTokenGrant(
  db: RefreshFirestore,
  request: RefreshTokenRequest,
): Promise<RefreshTokenResponse> {
  if (request.grantType !== "refresh_token") {
    throw new HttpError(400, "Only the refresh_token grant is supported at this endpoint.", "unsupported_grant_type");
  }
  if (typeof request.refreshToken !== "string" || request.refreshToken.length === 0) {
    throw new HttpError(400, "A refresh_token is required.", "invalid_request");
  }
  if (typeof request.accessToken !== "string" || request.accessToken.length === 0) {
    throw new HttpError(400, "The expiring access token must be presented to locate the grant.", "invalid_request");
  }

  const secret = process.env.MCP_TOKEN_HMAC_SECRET;
  if (!secret) {
    throw new HttpError(503, "MCP token signer is not configured.", "token_signer_unconfigured");
  }

  // Locate the grant via the (possibly just-expired) access token. Signature is
  // still verified — only the expiry gate is relaxed.
  const presented = verifyAccessTokenString(request.accessToken, { allowExpired: true });
  const uid = presented.sub;
  const clientId = presented.client_id;

  const snap = await db
    .collection(`users/${uid}/remote_mcp_grants`)
    .where("clientId", "==", clientId)
    .limit(25)
    .get();

  const presentedRefresh = request.refreshToken;
  const grant = snap.docs.find((doc) => safeEqualHash(presentedRefresh, doc.get("refreshTokenHash")));
  if (!grant) {
    throw new HttpError(401, "OpenBurnBar MCP refresh token is invalid or has been rotated.", "invalid_grant");
  }

  if (toMillis(grant.get("revokedAt")) !== undefined) {
    throw new HttpError(401, "OpenBurnBar MCP grant has been revoked.", "invalid_grant");
  }
  const grantExpiresAt = toMillis(grant.get("expiresAt"));
  if (grantExpiresAt !== undefined && grantExpiresAt <= Date.now()) {
    throw new HttpError(401, "OpenBurnBar MCP grant has expired; re-link the CLI.", "invalid_grant");
  }

  // Re-check client revocation and the live Pro/Ultra entitlement: a refresh must
  // not outlive a cancelled subscription or a revoked client.
  await requireActiveRemoteMcpClient(uid, clientId, db);
  const entitlement = await requireActiveBurnBarPro(uid, db);

  const grantScopes = Array.isArray(grant.get("scopes"))
    ? (grant.get("scopes") as unknown[]).filter((s): s is string => typeof s === "string")
    : presented.scopes;

  // Rotate the refresh token: a used refresh token must never be replayable.
  const newRefreshToken = randomSecret("obbr");
  await grant.ref.set(
    { refreshTokenHash: hashSecret(newRefreshToken), updatedAt: new Date() },
    { merge: true },
  );

  const entitlementFamily: AccessTokenClaims["entitlement_family"] =
    entitlement.source === "hosted_quota_sync" ? "hosted_quota_sync" : "burnbar_pro";

  const accessClaims: AccessTokenClaims = {
    sub: uid,
    aud: MCP_RESOURCE,
    client_id: clientId,
    scopes: grantScopes,
    entitlement_family: entitlementFamily,
    grant_mode: presented.grant_mode,
    exp: Math.floor(Date.now() / 1000) + ACCESS_TOKEN_TTL_SECONDS,
    jti: `mcp_${randomBytes(16).toString("hex")}`,
  };
  const accessToken = mintDevelopmentToken(accessClaims, secret);

  return {
    token_type: "Bearer",
    access_token: accessToken,
    expires_in: ACCESS_TOKEN_TTL_SECONDS,
    refresh_token: newRefreshToken,
    scope: grantScopes.join(" "),
    client_id: clientId,
  };
}

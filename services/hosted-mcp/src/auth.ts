import { createHmac, timingSafeEqual } from "node:crypto";
import { MCP_RESOURCE } from "./config.js";
import { HttpError } from "./errors.js";

export type GrantMode = "sealed_only" | "local_decrypt_shim" | "remote_readable_explicit_opt_in";

export interface AccessTokenClaims {
  sub: string;
  aud: string;
  client_id: string;
  scopes: string[];
  entitlement_family: "burnbar_pro" | "hosted_quota_sync";
  grant_mode: GrantMode;
  exp: number;
  jti: string;
}

const SAFE_CLIENT_ID = /^[A-Za-z0-9_.:-]{1,160}$/u;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isGrantMode(value: unknown): value is GrantMode {
  return value === "sealed_only" || value === "local_decrypt_shim" || value === "remote_readable_explicit_opt_in";
}

function isEntitlementFamily(value: unknown): value is AccessTokenClaims["entitlement_family"] {
  return value === "burnbar_pro" || value === "hosted_quota_sync";
}

function parseAccessTokenClaims(raw: unknown): AccessTokenClaims {
  if (!isRecord(raw)) {
    throw new HttpError(401, "Malformed OpenBurnBar MCP token claims.", "malformed_claims");
  }
  const sub = raw.sub;
  const aud = raw.aud;
  const clientId = raw.client_id;
  const jti = raw.jti;
  const exp = raw.exp;
  const scopes = raw.scopes;
  const entitlementFamily = raw.entitlement_family;
  const grantMode = raw.grant_mode;
  if (
    typeof sub !== "string"
    || typeof aud !== "string"
    || typeof clientId !== "string"
    || typeof jti !== "string"
    || typeof exp !== "number"
    || !Array.isArray(scopes)
    || !scopes.every((scope): scope is string => typeof scope === "string")
    || !isEntitlementFamily(entitlementFamily)
    || !isGrantMode(grantMode)
  ) {
    throw new HttpError(401, "Malformed OpenBurnBar MCP token claims.", "malformed_claims");
  }
  return {
    sub,
    aud,
    client_id: clientId,
    scopes,
    entitlement_family: entitlementFamily,
    grant_mode: grantMode,
    exp,
    jti,
  };
}

function base64UrlDecode(value: string): Buffer {
  return Buffer.from(value.replace(/-/g, "+").replace(/_/g, "/"), "base64");
}

function base64UrlEncode(value: Buffer | string): string {
  return Buffer.from(value).toString("base64url");
}

export function mintDevelopmentToken(claims: AccessTokenClaims, secret = process.env.MCP_TOKEN_HMAC_SECRET ?? "dev-secret"): string {
  const body = base64UrlEncode(JSON.stringify(claims));
  const sig = createHmac("sha256", secret).update(body).digest("base64url");
  return `${body}.${sig}`;
}

/**
 * Verify an HMAC access token string (the `<body>.<sig>` form, no "Bearer " prefix)
 * and return its claims. When `allowExpired` is true the expiry gate is skipped —
 * used by the refresh-token endpoint, which must accept a just-expired access token
 * as the locator for the grant it is rotating.
 */
export function verifyAccessTokenString(token: string, options: { allowExpired?: boolean } = {}): AccessTokenClaims {
  const trimmed = token.trim();
  if (!trimmed || trimmed.includes(" ")) {
    throw new HttpError(401, "Malformed OpenBurnBar MCP access token.", "malformed_token");
  }
  if (trimmed.includes("?")) {
    throw new HttpError(401, "Tokens in query strings are rejected.", "token_query_string_rejected");
  }
  const [body, sig] = trimmed.split(".");
  if (!body || !sig) {
    throw new HttpError(401, "Malformed OpenBurnBar MCP access token.", "malformed_token");
  }
  const secret = process.env.MCP_TOKEN_HMAC_SECRET;
  if (!secret) {
    throw new HttpError(503, "MCP token verifier is not configured.", "token_verifier_unconfigured");
  }
  const expected = createHmac("sha256", secret).update(body).digest();
  const actual = base64UrlDecode(sig);
  if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) {
    throw new HttpError(401, "Invalid OpenBurnBar MCP access token signature.", "bad_token_signature");
  }
  let claims: AccessTokenClaims;
  try {
    claims = parseAccessTokenClaims(JSON.parse(base64UrlDecode(body).toString("utf8")));
  } catch (error) {
    if (error instanceof HttpError) {throw error;}
    throw new HttpError(401, "Malformed OpenBurnBar MCP access token claims.", "malformed_claims");
  }
  if (!claims.sub || !claims.client_id || !claims.jti || claims.aud !== MCP_RESOURCE) {
    throw new HttpError(401, "OpenBurnBar MCP token audience or subject is invalid.", "invalid_claims");
  }
  if (!SAFE_CLIENT_ID.test(claims.client_id)) {
    throw new HttpError(401, "OpenBurnBar MCP token client ID is invalid.", "invalid_client_id");
  }
  if (!Array.isArray(claims.scopes)) {
    throw new HttpError(401, "OpenBurnBar MCP token has invalid scopes.", "invalid_scopes");
  }
  if (!options.allowExpired && claims.exp * 1000 <= Date.now()) {
    throw new HttpError(401, "OpenBurnBar MCP access token expired.", "expired_token");
  }
  return claims;
}

export function verifyBearerToken(header: string | undefined): AccessTokenClaims {
  if (!header) {
    throw new HttpError(401, "Missing OpenBurnBar MCP bearer token.", "missing_auth");
  }
  const trimmed = header.trim();
  const separator = trimmed.indexOf(" ");
  if (separator <= 0 || trimmed.slice(0, separator).toLowerCase() !== "bearer") {
    throw new HttpError(401, "Bearer token must be sent in the Authorization header.", "invalid_auth_header");
  }
  const token = trimmed.slice(separator + 1).trim();
  if (!token || token.includes(" ")) {
    throw new HttpError(401, "Bearer token must be sent in the Authorization header.", "invalid_auth_header");
  }
  return verifyAccessTokenString(token);
}

export function requireScope(claims: AccessTokenClaims, scope: string): void {
  if (!claims.scopes.includes(scope)) {
    throw new HttpError(403, `Missing required scope ${scope}.`, "insufficient_scope");
  }
}

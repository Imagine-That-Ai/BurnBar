import assert from "node:assert/strict";
import test from "node:test";
import { createHash } from "node:crypto";
import { MCP_AUTH_ISSUER, MCP_RESOURCE } from "./config.js";
import { mintDevelopmentToken, verifyBearerToken, type AccessTokenClaims } from "./auth.js";
import { authorizationServerMetadata, protectedResourceMetadata } from "./oauthMetadata.js";
import { handleRefreshTokenGrant, type RefreshFirestore } from "./oauthToken.js";

const SECRET = "integration-secret";

function sha256(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

const SCOPES = ["search:read", "conversation:read", "usage:read", "index:status"];

function mintAccessToken(uid: string, clientId: string, overrides: Partial<AccessTokenClaims> = {}): string {
  const claims: AccessTokenClaims = {
    sub: uid,
    aud: MCP_RESOURCE,
    client_id: clientId,
    scopes: SCOPES,
    entitlement_family: "burnbar_pro",
    grant_mode: "local_decrypt_shim",
    exp: Math.floor(Date.now() / 1000) + 15 * 60,
    jti: `jti-${uid}`,
    ...overrides,
  };
  return mintDevelopmentToken(claims, SECRET);
}

/**
 * In-memory Firestore double mirroring the grant doc written by
 * functions/src/remoteMcpGrant.ts (createRemoteMcpGrant) plus the entitlement and
 * client docs the refresh path re-checks. Each test uses a distinct uid so the
 * per-uid entitlement cache in entitlements.ts never bleeds across cases.
 */
function makeDb(opts: {
  uid: string;
  clientId: string;
  refreshTokenHash: string;
  clientRevoked?: boolean;
  entitled?: boolean;
  grantRevoked?: boolean;
  grantExpiresAtMs?: number;
}): { db: RefreshFirestore; grantState: { refreshTokenHash: string; sets: unknown[] } } {
  const grantState = { refreshTokenHash: opts.refreshTokenHash, sets: [] };
  const db: RefreshFirestore = {
    doc(path: string) {
      return {
        async get() {
          if (path.endsWith(`/remote_mcp_clients/${opts.clientId}`)) {
            return opts.clientRevoked
              ? { exists: true, data: () => ({ revokedAt: new Date().toISOString(), allowedScopes: ["search:read"] }) }
              : { exists: true, data: () => ({ allowedScopes: SCOPES }) };
          }
          if (path.endsWith("/entitlements/burnbar_pro")) {
            return opts.entitled === false
              ? { exists: false, data: () => undefined }
              : { exists: true, data: () => ({ active: true, expiresAt: new Date(Date.now() + 3_600_000).toISOString() }) };
          }
          return { exists: false, data: () => undefined };
        },
        async set() {},
      };
    },
    collection(path: string) {
      assert.equal(path, `users/${opts.uid}/remote_mcp_grants`);
      return {
        where(field: string, _op: "==", value: unknown) {
          assert.equal(field, "clientId");
          assert.equal(value, opts.clientId);
          return {
            limit() {
              return {
                async get() {
                  return {
                    docs: [
                      {
                        id: "rmg_int",
                        get(f: string) {
                          if (f === "refreshTokenHash") {return grantState.refreshTokenHash;}
                          if (f === "clientId") {return opts.clientId;}
                          if (f === "scopes") {return SCOPES;}
                          if (f === "revokedAt") {return opts.grantRevoked ? new Date().toISOString() : undefined;}
                          if (f === "expiresAt") {
                            return { toMillis: () => opts.grantExpiresAtMs ?? Date.now() + 90 * 24 * 3_600_000 };
                          }
                          return undefined;
                        },
                        ref: {
                          async set(value: unknown) {
                            grantState.sets.push(value);
                            const v = value as { refreshTokenHash?: string };
                            if (typeof v.refreshTokenHash === "string") {grantState.refreshTokenHash = v.refreshTokenHash;}
                          },
                        },
                      },
                    ],
                  };
                },
              };
            },
          };
        },
      };
    },
  };
  return { db, grantState };
}

test("discovery advertises only routes that exist and points at the served issuer", () => {
  const resource = protectedResourceMetadata();
  const server = authorizationServerMetadata();

  // RFC 9728: protected resource points clients at the served authorization server.
  assert.deepEqual(resource.authorization_servers, [MCP_AUTH_ISSUER]);
  assert.equal(server.issuer, MCP_AUTH_ISSUER);
  assert.ok(MCP_AUTH_ISSUER.startsWith("https://mcp.burnbar.ai"), "issuer must be the served domain, not openburnbar.com");

  // The token endpoint is the only OAuth route, and it lives on the served domain.
  assert.equal(server.token_endpoint, `${MCP_AUTH_ISSUER}/oauth/token`);
  assert.deepEqual(server.grant_types_supported, ["refresh_token"]);
  // Authorize/revoke endpoints (which would 404) must NOT be advertised.
  assert.equal("authorization_endpoint" in server, false);
  assert.equal("revocation_endpoint" in server, false);
});

test("full lifecycle: issue -> expire -> refresh -> 200, with rotation", async () => {
  process.env.MCP_TOKEN_HMAC_SECRET = SECRET;
  const uid = "user-lifecycle";
  const clientId = "obbc_lifecycle";

  // Issue: a freshly minted access token verifies on the resource server.
  const issued = mintAccessToken(uid, clientId);
  assert.equal(verifyBearerToken(`Bearer ${issued}`).sub, uid);

  // Expire: a token past its exp is rejected by the resource server's /mcp gate.
  const expired = mintAccessToken(uid, clientId, { exp: Math.floor(Date.now() / 1000) - 60, jti: "jti-expired" });
  assert.throws(() => verifyBearerToken(`Bearer ${expired}`), /expired/);

  // Refresh: present the expired access token + the durable refresh token.
  const refreshToken = "obbr_originalsecret";
  const { db, grantState } = makeDb({ uid, clientId, refreshTokenHash: sha256(refreshToken) });
  const refreshed = await handleRefreshTokenGrant(db, {
    grantType: "refresh_token",
    refreshToken,
    accessToken: expired,
  });

  // 200-equivalent: the re-minted access token verifies on the resource server.
  assert.equal(refreshed.token_type, "Bearer");
  assert.equal(refreshed.expires_in, 15 * 60);
  const claims = verifyBearerToken(`Bearer ${refreshed.access_token}`);
  assert.equal(claims.sub, uid);
  assert.equal(claims.client_id, clientId);
  assert.ok(claims.exp * 1000 > Date.now());

  // Rotation: a new refresh token was issued and persisted to the grant doc.
  assert.notEqual(refreshed.refresh_token, refreshToken);
  assert.equal(grantState.refreshTokenHash, sha256(refreshed.refresh_token));
});

test("rotated refresh token cannot be replayed", async () => {
  process.env.MCP_TOKEN_HMAC_SECRET = SECRET;
  const uid = "user-replay";
  const clientId = "obbc_replay";
  const expired = mintAccessToken(uid, clientId, { exp: Math.floor(Date.now() / 1000) - 60 });
  const refreshToken = "obbr_replaysecret";
  const { db } = makeDb({ uid, clientId, refreshTokenHash: sha256(refreshToken) });

  await handleRefreshTokenGrant(db, { grantType: "refresh_token", refreshToken, accessToken: expired });
  // The original refresh token now hashes to nothing stored -> invalid_grant.
  await assert.rejects(
    () => handleRefreshTokenGrant(db, { grantType: "refresh_token", refreshToken, accessToken: expired }),
    /invalid or has been rotated/,
  );
});

test("refresh fails closed on client revocation, lost entitlement, and revoked/expired grant", async () => {
  process.env.MCP_TOKEN_HMAC_SECRET = SECRET;
  const refreshToken = "obbr_gatesecret";
  const hash = sha256(refreshToken);

  const revokedClient = "user-gate-clientrevoked";
  await assert.rejects(
    () => handleRefreshTokenGrant(makeDb({ uid: revokedClient, clientId: "obbc_cr", refreshTokenHash: hash, clientRevoked: true }).db, {
      grantType: "refresh_token", refreshToken, accessToken: mintAccessToken(revokedClient, "obbc_cr", { exp: Math.floor(Date.now() / 1000) - 60 }),
    }),
    /revoked/,
  );

  const noPro = "user-gate-nopro";
  await assert.rejects(
    () => handleRefreshTokenGrant(makeDb({ uid: noPro, clientId: "obbc_np", refreshTokenHash: hash, entitled: false }).db, {
      grantType: "refresh_token", refreshToken, accessToken: mintAccessToken(noPro, "obbc_np", { exp: Math.floor(Date.now() / 1000) - 60 }),
    }),
    /BurnBar Pro/,
  );

  const grantRevoked = "user-gate-grantrevoked";
  await assert.rejects(
    () => handleRefreshTokenGrant(makeDb({ uid: grantRevoked, clientId: "obbc_gr", refreshTokenHash: hash, grantRevoked: true }).db, {
      grantType: "refresh_token", refreshToken, accessToken: mintAccessToken(grantRevoked, "obbc_gr", { exp: Math.floor(Date.now() / 1000) - 60 }),
    }),
    /revoked/,
  );

  const grantExpired = "user-gate-grantexpired";
  await assert.rejects(
    () => handleRefreshTokenGrant(makeDb({ uid: grantExpired, clientId: "obbc_ge", refreshTokenHash: hash, grantExpiresAtMs: Date.now() - 1000 }).db, {
      grantType: "refresh_token", refreshToken, accessToken: mintAccessToken(grantExpired, "obbc_ge", { exp: Math.floor(Date.now() / 1000) - 60 }),
    }),
    /expired/,
  );
});

test("refresh rejects wrong grant type and a forged refresh token", async () => {
  process.env.MCP_TOKEN_HMAC_SECRET = SECRET;
  const uid = "user-forge";
  const clientId = "obbc_forge";
  const expired = mintAccessToken(uid, clientId, { exp: Math.floor(Date.now() / 1000) - 60 });
  const { db } = makeDb({ uid, clientId, refreshTokenHash: sha256("obbr_realsecret") });

  await assert.rejects(
    () => handleRefreshTokenGrant(db, { grantType: "authorization_code", refreshToken: "obbr_realsecret", accessToken: expired }),
    /Only the refresh_token grant/,
  );
  await assert.rejects(
    () => handleRefreshTokenGrant(db, { grantType: "refresh_token", refreshToken: "obbr_forged", accessToken: expired }),
    /invalid or has been rotated/,
  );
});

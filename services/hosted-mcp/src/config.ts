export const MCP_PROTOCOL_VERSION = "2025-11-25";
export const MCP_RESOURCE = process.env.MCP_RESOURCE ?? "https://mcp.burnbar.ai/mcp";
export const MCP_AUTH_ISSUER = process.env.MCP_AUTH_ISSUER ?? "https://mcp.burnbar.ai";
export const MAX_REQUEST_BYTES = Number(process.env.MCP_MAX_REQUEST_BYTES ?? 128 * 1024);
export const MAX_OUTPUT_BYTES = Number(process.env.MCP_MAX_OUTPUT_BYTES ?? 64 * 1024);
export const POSITIVE_ENTITLEMENT_CACHE_MS = Number(process.env.MCP_POSITIVE_ENTITLEMENT_CACHE_MS ?? 60_000);
export const NEGATIVE_ENTITLEMENT_CACHE_MS = Number(process.env.MCP_NEGATIVE_ENTITLEMENT_CACHE_MS ?? 15_000);
export const REMOTE_MCP_LAST_USED_WRITE_INTERVAL_MS = Number(process.env.MCP_LAST_USED_WRITE_INTERVAL_MS ?? 60_000);

export function allowedOrigins(): Set<string> {
  const raw = process.env.MCP_ALLOWED_ORIGINS ?? "https://mcp.burnbar.ai,https://burnbar.ai,https://openburnbar.com";
  return new Set(raw.split(",").map((item) => item.trim()).filter(Boolean));
}

/**
 * Whether this process is a production runtime. Cloud Run sets `K_SERVICE`;
 * `NODE_ENV=production` is the other signal. `MCP_RUNTIME_ENVIRONMENT` is an
 * explicit override (and the hook tests use it to exercise the prod branch
 * without depending on the ambient `NODE_ENV=test`).
 */
export function isProductionRuntime(env: NodeJS.ProcessEnv = process.env): boolean {
  const explicit = (env.MCP_RUNTIME_ENVIRONMENT ?? "").toLowerCase();
  if (explicit === "production") {return true;}
  if (explicit === "development" || explicit === "test") {return false;}
  if (env.NODE_ENV === "test") {return false;}
  return env.NODE_ENV === "production" || Boolean(env.K_SERVICE);
}

/**
 * Fail-closed startup guard for the token posture. In production the service
 * must verify ASYMMETRIC Ed25519 access tokens; it must NOT silently accept the
 * legacy symmetric HMAC form, because anyone holding the shared `MCP_TOKEN_HMAC_SECRET`
 * (including the operator) can mint a token for ANY uid. Without this guard a deploy
 * that simply forgot to set `MCP_TOKEN_ED25519_PUBLIC_KEY_BASE64` would regress to
 * HMAC-for-any-uid with no signal (the audit's RR-13 residual). Refuse to boot instead.
 */
export function assertProductionTokenPosture(env: NodeJS.ProcessEnv = process.env): void {
  if (!isProductionRuntime(env)) {return;}
  const errors: string[] = [];
  if (!env.MCP_TOKEN_ED25519_PUBLIC_KEY_BASE64) {
    errors.push("MCP_TOKEN_ED25519_PUBLIC_KEY_BASE64 must be set — asymmetric token verification is required in production");
  }
  if (env.MCP_ALLOW_LEGACY_HMAC_TOKENS === "true") {
    errors.push("MCP_ALLOW_LEGACY_HMAC_TOKENS must not be 'true' in production — symmetric HMAC tokens are mintable for any uid by anyone with the shared secret");
  }
  if (env.MCP_TOKEN_HMAC_SECRET === "dev-secret") {
    errors.push("MCP_TOKEN_HMAC_SECRET is the insecure development default 'dev-secret'");
  }
  if (errors.length > 0) {
    throw new Error(`[hosted-mcp] refusing to start: insecure production token posture:\n  - ${errors.join("\n  - ")}`);
  }
}

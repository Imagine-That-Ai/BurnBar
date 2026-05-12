import { DEFAULT_MAX_FRAME_BYTES } from "./protocol.js";

export interface RelayLimitsConfig {
  maxFrameBytes: number;
  maxHostSocketsPerUser: number;
  maxClientSocketsPerUser: number;
  maxRequestStartsPerMinute: number;
  maxBytesPerMinute: number;
  maxInFlightRequestsPerUser: number;
  socketLeaseSeconds: number;
  inFlightLeaseSeconds: number;
}

export interface RelayConfig {
  port: number;
  redisURL: string;
  redisTLSCA?: string;
  redisTLSServername?: string;
  enforceAppCheck: boolean;
  verifyRevokedIdTokens: boolean;
  hostedRelayProductIDs: string[];
  entitlementCacheTTLSeconds: number;
  entitlementNegativeCacheTTLSeconds: number;
  allowedAppIDs: string[];
  limits: RelayLimitsConfig;
}

export function loadRelayConfig(env: NodeJS.ProcessEnv = process.env): RelayConfig {
  return {
    port: numberEnv(env.PORT, 8080),
    redisURL: env.REDIS_URL ?? "redis://127.0.0.1:6379",
    redisTLSCA: textEnv(env.REDIS_TLS_CA_PEM) ?? base64TextEnv(env.REDIS_TLS_CA_BASE64),
    redisTLSServername: textEnv(env.REDIS_TLS_SERVERNAME),
    enforceAppCheck: boolEnv(env.ENFORCE_APP_CHECK, true),
    verifyRevokedIdTokens: boolEnv(env.VERIFY_REVOKED_ID_TOKENS, false),
    hostedRelayProductIDs: listEnv(
      env.HOSTED_RELAY_PRODUCT_IDS ?? env.HOSTED_QUOTA_PRODUCT_ID,
      ["com.openburnbar.hostedQuotaSync.cloud.monthly"]
    ),
    entitlementCacheTTLSeconds: numberEnv(env.ENTITLEMENT_CACHE_TTL_SECONDS, 60),
    entitlementNegativeCacheTTLSeconds: numberEnv(env.ENTITLEMENT_NEGATIVE_CACHE_TTL_SECONDS, 15),
    allowedAppIDs: listEnv(env.APP_CHECK_ALLOWED_APP_IDS, []),
    limits: {
      maxFrameBytes: numberEnv(env.MAX_FRAME_BYTES, DEFAULT_MAX_FRAME_BYTES),
      maxHostSocketsPerUser: numberEnv(env.MAX_HOST_SOCKETS_PER_USER, 2),
      maxClientSocketsPerUser: numberEnv(env.MAX_CLIENT_SOCKETS_PER_USER, 4),
      maxRequestStartsPerMinute: numberEnv(env.MAX_REQUEST_STARTS_PER_MINUTE, 60),
      maxBytesPerMinute: numberEnv(env.MAX_BYTES_PER_MINUTE, 25 * 1024 * 1024),
      maxInFlightRequestsPerUser: numberEnv(env.MAX_IN_FLIGHT_REQUESTS_PER_USER, 6),
      socketLeaseSeconds: numberEnv(env.SOCKET_LEASE_SECONDS, 120),
      inFlightLeaseSeconds: numberEnv(env.IN_FLIGHT_LEASE_SECONDS, 10 * 60),
    },
  };
}

function numberEnv(value: string | undefined, fallback: number): number {
  if (value === undefined || value.trim() === "") return fallback;
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function boolEnv(value: string | undefined, fallback: boolean): boolean {
  if (value === undefined || value.trim() === "") return fallback;
  return ["1", "true", "yes", "on"].includes(value.toLowerCase());
}

function listEnv(value: string | undefined, fallback: string[]): string[] {
  if (value === undefined || value.trim() === "") return fallback;
  const parsed = value
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
  return parsed.length > 0 ? parsed : fallback;
}

function textEnv(value: string | undefined): string | undefined {
  if (value === undefined || value.trim() === "") return undefined;
  return value.replace(/\\n/g, "\n").trim();
}

function base64TextEnv(value: string | undefined): string | undefined {
  const encoded = textEnv(value);
  if (!encoded) return undefined;
  return Buffer.from(encoded, "base64").toString("utf8").replace(/\\n/g, "\n").trim();
}

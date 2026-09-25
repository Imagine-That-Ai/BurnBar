import { defineSecret } from "firebase-functions/params";

import { shouldBindRemoteMcpHmacSecretForRuntime } from "../remoteMcpOAuth.js";

const REMOTE_MCP_TOKEN_HMAC_SECRET = defineSecret("REMOTE_MCP_TOKEN_HMAC_SECRET");
export const REMOTE_MCP_TOKEN_ED25519_PRIVATE_KEY_BASE64 = defineSecret("REMOTE_MCP_TOKEN_ED25519_PRIVATE_KEY_BASE64");

export function remoteMcpTokenSigningSecrets() {
  return shouldBindRemoteMcpHmacSecretForRuntime()
    ? [REMOTE_MCP_TOKEN_HMAC_SECRET, REMOTE_MCP_TOKEN_ED25519_PRIVATE_KEY_BASE64]
    : [REMOTE_MCP_TOKEN_ED25519_PRIVATE_KEY_BASE64];
}

export function remoteMcpTokenHmacSecretValueForRuntime(): string | undefined {
  return shouldBindRemoteMcpHmacSecretForRuntime() ? REMOTE_MCP_TOKEN_HMAC_SECRET.value() : undefined;
}

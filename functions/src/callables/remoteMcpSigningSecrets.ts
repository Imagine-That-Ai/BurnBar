import { shouldBindRemoteMcpHmacSecretForRuntime } from "../remoteMcpOAuth.js";
import { REMOTE_MCP_TOKEN_ED25519_PRIVATE_KEY_BASE64, REMOTE_MCP_TOKEN_HMAC_SECRET } from "./shared.js";

export function remoteMcpTokenSigningSecrets() {
  return shouldBindRemoteMcpHmacSecretForRuntime()
    ? [REMOTE_MCP_TOKEN_HMAC_SECRET, REMOTE_MCP_TOKEN_ED25519_PRIVATE_KEY_BASE64]
    : [REMOTE_MCP_TOKEN_ED25519_PRIVATE_KEY_BASE64];
}

export function remoteMcpTokenHmacSecretValueForRuntime(): string | undefined {
  return shouldBindRemoteMcpHmacSecretForRuntime() ? REMOTE_MCP_TOKEN_HMAC_SECRET.value() : undefined;
}

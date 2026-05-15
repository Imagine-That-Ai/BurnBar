const SECRET_KEYS = new Set([
  "authorization",
  "access_token",
  "refresh_token",
  "id_token",
  "token",
  "apiKey",
  "cookie",
  "vaultKey",
  "query",
  "snippet",
  "body",
  "ciphertext",
  "sealedSnippet",
  "sealedBodyPreview"
]);

export function redact(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(redact);
  if (!value || typeof value !== "object") return value;
  const output: Record<string, unknown> = {};
  for (const [key, item] of Object.entries(value)) {
    if (SECRET_KEYS.has(key) || SECRET_KEYS.has(key.toLowerCase())) {
      output[key] = "[REDACTED]";
    } else {
      output[key] = redact(item);
    }
  }
  return output;
}

export function truncateJson(value: unknown, maxBytes: number): unknown {
  const encoded = Buffer.from(JSON.stringify(value));
  if (encoded.length <= maxBytes) return value;
  return {
    content: [
      {
        type: "text",
        text: `OpenBurnBar MCP response exceeded ${maxBytes} bytes and was truncated before logging or returning.`
      }
    ],
    isError: true
  };
}

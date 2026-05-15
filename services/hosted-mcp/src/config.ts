export const MCP_PROTOCOL_VERSION = "2025-11-25";
export const MCP_RESOURCE = process.env.MCP_RESOURCE ?? "https://mcp.openburnbar.com/mcp";
export const MCP_AUTH_ISSUER = process.env.MCP_AUTH_ISSUER ?? "https://openburnbar.com";
export const MAX_REQUEST_BYTES = Number(process.env.MCP_MAX_REQUEST_BYTES ?? 128 * 1024);
export const MAX_OUTPUT_BYTES = Number(process.env.MCP_MAX_OUTPUT_BYTES ?? 64 * 1024);
export const POSITIVE_ENTITLEMENT_CACHE_MS = Number(process.env.MCP_POSITIVE_ENTITLEMENT_CACHE_MS ?? 60_000);
export const NEGATIVE_ENTITLEMENT_CACHE_MS = Number(process.env.MCP_NEGATIVE_ENTITLEMENT_CACHE_MS ?? 15_000);

export function allowedOrigins(): Set<string> {
  const raw = process.env.MCP_ALLOWED_ORIGINS ?? "https://mcp.openburnbar.com,https://openburnbar.com";
  return new Set(raw.split(",").map((item) => item.trim()).filter(Boolean));
}

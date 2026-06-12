import { MCP_AUTH_ISSUER, MCP_RESOURCE } from "./config.js";

export function protectedResourceMetadata() {
  return {
    resource: MCP_RESOURCE,
    authorization_servers: [MCP_AUTH_ISSUER],
    scopes_supported: ["search:read", "conversation:read", "usage:read", "index:status"],
    bearer_methods_supported: ["header"],
    resource_documentation: "https://burnbar.ai/docs/remote-mcp"
  };
}

export function authorizationServerMetadata() {
  // Grants are minted out-of-band by the device-code link flow (startCliLink ->
  // completeCliLink). The only OAuth endpoint this server exposes is the refresh
  // token endpoint, so we advertise exactly that — no authorization_code, no
  // authorize/revoke endpoints (which would 404). Discovery must only point at
  // routes that exist on this service.
  return {
    issuer: MCP_AUTH_ISSUER,
    token_endpoint: `${MCP_AUTH_ISSUER}/oauth/token`,
    grant_types_supported: ["refresh_token"],
    scopes_supported: ["search:read", "conversation:read", "usage:read", "index:status"],
    token_endpoint_auth_methods_supported: ["none"]
  };
}

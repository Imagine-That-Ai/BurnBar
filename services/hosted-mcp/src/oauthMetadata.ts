import { MCP_AUTH_ISSUER, MCP_RESOURCE } from "./config.js";

export function protectedResourceMetadata() {
  return {
    resource: MCP_RESOURCE,
    authorization_servers: [MCP_AUTH_ISSUER],
    scopes_supported: ["search:read", "conversation:read", "usage:read", "index:status"],
    bearer_methods_supported: ["header"],
    resource_documentation: "https://openburnbar.com/docs/remote-mcp"
  };
}

export function authorizationServerMetadata() {
  return {
    issuer: MCP_AUTH_ISSUER,
    authorization_endpoint: `${MCP_AUTH_ISSUER}/oauth/authorize`,
    token_endpoint: `${MCP_AUTH_ISSUER}/oauth/token`,
    revocation_endpoint: `${MCP_AUTH_ISSUER}/oauth/revoke`,
    response_types_supported: ["code"],
    grant_types_supported: ["authorization_code", "refresh_token"],
    code_challenge_methods_supported: ["S256"],
    scopes_supported: ["search:read", "conversation:read", "usage:read", "index:status"],
    token_endpoint_auth_methods_supported: ["none", "client_secret_post"]
  };
}

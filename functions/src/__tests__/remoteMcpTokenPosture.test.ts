import { describe, expect, it } from "vitest";

import { assertRemoteMcpIssuerTokenPosture, isRemoteMcpProductionIssuerRuntime } from "../remoteMcpOAuth.js";

describe("Remote MCP Functions issuer token posture", () => {
  it("allows local/test HMAC fallback for emulator compatibility", () => {
    expect(() =>
      assertRemoteMcpIssuerTokenPosture({ tokenSecret: "local-secret" }, { NODE_ENV: "test" }),
    ).not.toThrow();
  });

  it("refuses HMAC signing in production, even with an Ed25519 key present", () => {
    expect(() =>
      assertRemoteMcpIssuerTokenPosture(
        {
          tokenSecret: "shared-prod-secret",
          tokenEd25519PrivateKeyBase64PEM: "base64-pem",
        },
        { REMOTE_MCP_RUNTIME_ENVIRONMENT: "production" },
      ),
    ).toThrow(/REMOTE_MCP_TOKEN_HMAC_SECRET must not be used/u);
  });

  it("requires Ed25519 signing in production", () => {
    expect(() => assertRemoteMcpIssuerTokenPosture({}, { REMOTE_MCP_RUNTIME_ENVIRONMENT: "production" })).toThrow(
      /REMOTE_MCP_TOKEN_ED25519_PRIVATE_KEY_BASE64/u,
    );
  });

  it("detects production Cloud Run/Functions runtime", () => {
    expect(isRemoteMcpProductionIssuerRuntime({ K_SERVICE: "issue-remote-mcp-grant" })).toBe(true);
    expect(isRemoteMcpProductionIssuerRuntime({ NODE_ENV: "test", K_SERVICE: "ignored-in-tests" })).toBe(false);
  });
});

import { describe, expect, it } from "vitest";

import {
  assertRemoteMcpIssuerTokenPosture,
  issueRemoteMcpGrantForSignedInUser,
  isRemoteMcpProductionIssuerRuntime,
  REMOTE_MCP_DEFAULT_GRANT_SCOPES,
} from "../remoteMcpOAuth.js";
import { pathKeyedFirestore } from "./bola/callableBolaHarness.js";

function decodeHmacAccessToken(token: string): { scopes?: unknown } {
  const [body] = token.split(".");
  if (!body) throw new Error("missing token body");
  const decoded: { scopes?: unknown } = JSON.parse(Buffer.from(body, "base64url").toString("utf8"));
  return decoded;
}

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

  it("keeps hosted knowledge access out of default grants", async () => {
    const store = new Map<string, Record<string, unknown>>();
    const db = pathKeyedFirestore(store);

    const grant = await issueRemoteMcpGrantForSignedInUser(db, "alice-uid", {
      clientId: "obbc_default",
      entitlementFamily: "burnbar_pro",
      tokenSecret: "local-test-secret",
      audience: "https://mcp.burnbar.ai/mcp",
    });

    expect(grant.scopes).toEqual([...REMOTE_MCP_DEFAULT_GRANT_SCOPES]);
    expect(grant.scopes).not.toContain("knowledge:read");
    expect(decodeHmacAccessToken(grant.accessToken).scopes).toEqual([...REMOTE_MCP_DEFAULT_GRANT_SCOPES]);

    const client = store.get("users/alice-uid/remote_mcp_clients/obbc_default");
    expect(client?.allowedScopes).toEqual([...REMOTE_MCP_DEFAULT_GRANT_SCOPES]);

    const grantDoc = [...store.entries()].find(([key]) => key.startsWith("users/alice-uid/remote_mcp_grants/"))?.[1];
    expect(grantDoc?.scopes).toEqual([...REMOTE_MCP_DEFAULT_GRANT_SCOPES]);
  });

  it("preserves explicit hosted knowledge opt-in grants", async () => {
    const store = new Map<string, Record<string, unknown>>();
    const db = pathKeyedFirestore(store);
    const explicitScopes = ["search:read", "knowledge:read"] as const;

    const grant = await issueRemoteMcpGrantForSignedInUser(db, "alice-uid", {
      clientId: "obbc_knowledge",
      scopes: [...explicitScopes],
      entitlementFamily: "burnbar_pro",
      tokenSecret: "local-test-secret",
      audience: "https://mcp.burnbar.ai/mcp",
    });

    expect(grant.scopes).toEqual([...explicitScopes]);
    expect(decodeHmacAccessToken(grant.accessToken).scopes).toEqual([...explicitScopes]);
    expect(store.get("users/alice-uid/remote_mcp_clients/obbc_knowledge")?.allowedScopes).toEqual([...explicitScopes]);
  });
});

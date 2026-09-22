import { createHash, createHmac } from "node:crypto";
import { describe, expect, it } from "vitest";

import { createRemoteMcpGrant, hashRemoteMcpSecret, upsertRemoteMcpClient } from "../remoteMcpGrant.js";
import { pathKeyedFirestore } from "./bola/callableBolaHarness.js";

const HASH_CONTEXT_V1 = "remote-mcp-secret-hash-v1";

function expectedPepperedHash(value: string, pepper: string): string {
  return createHmac("sha256", pepper).update(`${HASH_CONTEXT_V1}\0${value}`, "utf8").digest("hex");
}

describe("Remote MCP secret hashing", () => {
  it("peppers stored verifiers with HMAC-SHA256 and a domain-separation context", () => {
    expect(hashRemoteMcpSecret("obbr_refresh_token", "test-pepper")).toBe(
      expectedPepperedHash("obbr_refresh_token", "test-pepper"),
    );
  });

  it("is deterministic per pepper and separates peppers", () => {
    const first = hashRemoteMcpSecret("obbr_refresh_token", "pepper-a");
    expect(hashRemoteMcpSecret("obbr_refresh_token", "pepper-a")).toBe(first);
    expect(hashRemoteMcpSecret("obbr_refresh_token", "pepper-b")).not.toBe(first);
    expect(hashRemoteMcpSecret("obbr_other_token", "pepper-a")).not.toBe(first);
  });

  it("differs from the legacy unpeppered construction so rows cannot be confused", () => {
    const legacy = createHash("sha256").update("obbr_refresh_token").digest("hex");
    expect(hashRemoteMcpSecret("obbr_refresh_token", "test-pepper")).not.toBe(legacy);
    expect(hashRemoteMcpSecret("obbr_refresh_token", "")).toBe(legacy);
  });

  it("persists peppered verifiers for grants and fingerprints when a pepper is bound", async () => {
    const store = new Map<string, Record<string, unknown>>();
    const db = pathKeyedFirestore(store);
    process.env.REMOTE_MCP_TOKEN_HASH_PEPPER = "bound-pepper-for-test";
    try {
      const { grant, refreshToken } = await createRemoteMcpGrant(db, "alice-uid", {
        clientId: "obbc_peppered",
        scopes: ["search:read"],
        entitlementFamily: "burnbar_pro",
      });
      await upsertRemoteMcpClient(db, "alice-uid", {
        clientId: "obbc_peppered",
        displayName: "peppered cli",
        clientType: "cli",
        installFingerprint: "install-fingerprint-material",
        allowedScopes: ["search:read"],
        grantMode: "local_decrypt_shim",
      });

      const persistedGrant = store.get(`users/alice-uid/remote_mcp_grants/${grant.grantId}`);
      expect(persistedGrant?.refreshTokenHash).toBe(expectedPepperedHash(refreshToken, "bound-pepper-for-test"));
      expect(persistedGrant?.tokenFamilyHash).toBe(
        expectedPepperedHash(`${grant.grantId}:obbc_peppered`, "bound-pepper-for-test"),
      );
      const persistedClient = store.get("users/alice-uid/remote_mcp_clients/obbc_peppered");
      expect(persistedClient?.installFingerprintHash).toBe(
        expectedPepperedHash("install-fingerprint-material", "bound-pepper-for-test"),
      );
    } finally {
      delete process.env.REMOTE_MCP_TOKEN_HASH_PEPPER;
    }
  });
});

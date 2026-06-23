import { describe, expect, it } from "vitest";

import { createRemoteMcpGrant, hashRemoteMcpSecret, upsertRemoteMcpClient } from "../remoteMcpGrant.js";
import { pathKeyedFirestore } from "./bola/callableBolaHarness.js";

describe("Remote MCP grant storage", () => {
  it("persists only verifier material for durable refresh grants", async () => {
    const store = new Map<string, Record<string, unknown>>();
    const db = pathKeyedFirestore(store);

    const { grant, refreshToken } = await createRemoteMcpGrant(db, "alice-uid", {
      clientId: "obbc_storage",
      scopes: ["search:read", "usage:read"],
      entitlementFamily: "burnbar_pro",
      entitlementExpiresAt: "2027-01-01T00:00:00.000Z",
    });

    const persisted = store.get(`users/alice-uid/remote_mcp_grants/${grant.grantId}`);
    expect(persisted).toBeTruthy();
    expect(JSON.stringify(persisted)).not.toContain(refreshToken);
    expect(persisted).not.toHaveProperty("refreshToken");
    expect(persisted?.refreshTokenHash).toBe(hashRemoteMcpSecret(refreshToken));
    expect(persisted?.tokenFamilyHash).toBe(hashRemoteMcpSecret(`${grant.grantId}:obbc_storage`));
  });

  it("hashes client install fingerprints before persistence", async () => {
    const store = new Map<string, Record<string, unknown>>();
    const db = pathKeyedFirestore(store);
    const installFingerprint = "openburnbar-cli-install-fingerprint";

    await upsertRemoteMcpClient(db, "alice-uid", {
      clientId: "obbc_storage",
      displayName: "local cli",
      clientType: "cli",
      installFingerprint,
      allowedScopes: ["search:read"],
      grantMode: "local_decrypt_shim",
    });

    const persisted = store.get("users/alice-uid/remote_mcp_clients/obbc_storage");
    expect(persisted).toBeTruthy();
    expect(JSON.stringify(persisted)).not.toContain(installFingerprint);
    expect(persisted).not.toHaveProperty("installFingerprint");
    expect(persisted?.installFingerprintHash).toBe(hashRemoteMcpSecret(installFingerprint));
  });
});

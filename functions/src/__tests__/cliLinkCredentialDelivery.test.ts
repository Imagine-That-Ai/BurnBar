import { createECDH } from "node:crypto";
import { Timestamp } from "firebase-admin/firestore";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { callableRequest, callableRunner, pathKeyedFirestore, seedDoc } from "./bola/callableBolaHarness.js";
import {
  DELIVERY_ALGORITHM,
  DESKTOP_DELIVERY_ALGORITHM,
  DESKTOP_DELIVERY_KEY_CONTEXT,
  DESKTOP_FLOW_BINDING,
  FakeRes,
  REMOTE_DELIVERY_KEY_CONTEXT,
  decryptEnvelope,
  runHttpHandler,
  sha256Hex,
} from "./cliLinkCredentialDeliveryTestSupport.js";

const cliLinkStore = vi.hoisted(() => new Map());
const issueGrantMock = vi.hoisted(() => vi.fn());
const assertCloudFeatureNotSuspendedMock = vi.hoisted(() => vi.fn(async () => undefined));
const assertActiveBurnBarProEntitlementMock = vi.hoisted(() => vi.fn(async () => undefined));
const createCustomTokenMock = vi.hoisted(() => vi.fn(async () => "firebase-custom-token"));
process.env.OPENBURNBAR_FIREBASE_WEB_API_KEY = `AIza${"T".repeat(35)}`;

function cliLinkSessionQuery(filters: Array<[string, unknown]> = []) {
  return {
    where: (field: string, _op: string, value: unknown) => cliLinkSessionQuery([...filters, [field, value]]),
    limit: () => cliLinkSessionQuery(filters),
    orderBy: () => cliLinkSessionQuery(filters),
    get: async () => {
      const base = pathKeyedFirestore(cliLinkStore);
      const docs = Array.from(cliLinkStore.entries())
        .filter(
          ([path, data]) =>
            path.startsWith("cli_link_sessions/") && filters.every(([field, value]) => data[field] === value),
        )
        .map(([path, data]) => ({
          ref: base.doc(path),
          data: () => data,
        }));
      return { docs, empty: docs.length === 0 };
    },
  };
}

function cliLinkFirestore() {
  const base = pathKeyedFirestore(cliLinkStore);
  return {
    ...base,
    collection: (name: string) => {
      const collection = base.collection(name);
      if (name !== "cli_link_sessions") return collection;
      return {
        ...collection,
        where: (field: string, op: string, value: unknown) => cliLinkSessionQuery([[field, value]]),
      };
    },
  };
}

vi.mock("../adminRuntime.js", () => ({
  db: cliLinkFirestore(),
  auth: { createCustomToken: createCustomTokenMock },
}));
vi.mock("firebase-admin/firestore", async () => {
  const actual = await vi.importActual<typeof import("firebase-admin/firestore")>("firebase-admin/firestore");
  return {
    ...actual,
    getFirestore: () => pathKeyedFirestore(cliLinkStore),
  };
});
vi.mock("../appCheckAttestation.js", async () => {
  const actual = await vi.importActual<typeof import("../appCheckAttestation.js")>("../appCheckAttestation.js");
  return {
    ...actual,
    enforceHighRiskComputerUseCallableWithNonce: vi.fn(async () => ({ nonceConsumed: true })),
  };
});
vi.mock("../cloudFeatureSuspensions.js", () => ({
  assertCloudFeatureNotSuspended: assertCloudFeatureNotSuspendedMock,
}));
vi.mock("../callables/shared.js", () => ({
  assertActiveBurnBarProEntitlement: assertActiveBurnBarProEntitlementMock,
  REMOTE_MCP_TOKEN_ED25519_PRIVATE_KEY_BASE64: { value: () => "" },
  REMOTE_MCP_TOKEN_HMAC_SECRET: { value: () => "test-hmac-secret" },
}));
vi.mock("../callables/publicRateLimit.js", async () => {
  const actual = await vi.importActual<typeof import("../callables/publicRateLimit.js")>(
    "../callables/publicRateLimit.js",
  );
  return {
    ...actual,
    assertCallableApprovalNotLocked: vi.fn(async () => undefined),
    recordCallableApprovalFailure: vi.fn(async () => undefined),
  };
});
vi.mock("../remoteMcpOAuth.js", () => ({
  issueRemoteMcpGrantForSignedInUser: issueGrantMock,
  shouldBindRemoteMcpHmacSecretForRuntime: () => true,
}));

describe("CLI link credential delivery", () => {
  beforeEach(() => {
    cliLinkStore.clear();
    issueGrantMock.mockReset();
    createCustomTokenMock.mockReset();
    createCustomTokenMock.mockResolvedValue("firebase-custom-token");
    assertActiveBurnBarProEntitlementMock.mockReset();
    assertActiveBurnBarProEntitlementMock.mockResolvedValue(undefined);
    assertCloudFeatureNotSuspendedMock.mockReset();
    assertCloudFeatureNotSuspendedMock.mockResolvedValue(undefined);
  });

  it("seals credentials to the polling client's delivery key", async () => {
    const delivery = createECDH("prime256v1");
    delivery.generateKeys();
    const { sealCliLinkCredentialsForDelivery } = await import("../callables/cliLink.js");

    const envelope = sealCliLinkCredentialsForDelivery(
      {
        algorithm: DELIVERY_ALGORITHM,
        publicKeyBase64: delivery.getPublicKey("base64", "uncompressed"),
      },
      {
        accessToken: "access-secret",
        refreshToken: "refresh-secret",
        expiresIn: 900,
        clientId: "client-1",
        scopes: ["search:read"],
        grantMode: "local_decrypt_shim",
      },
    );

    expect(JSON.stringify(envelope)).not.toContain("access-secret");
    expect(JSON.stringify(envelope)).not.toContain("refresh-secret");

    expect(decryptEnvelope(delivery, envelope, REMOTE_DELIVERY_KEY_CONTEXT)).toMatchObject({
      accessToken: "access-secret",
      refreshToken: "refresh-secret",
      clientId: "client-1",
    });
  });

  it("starts sessions with a verifier hash and delivery key, not the raw device-secret hash", async () => {
    const deviceSecret = "device-secret-for-link";
    const deviceSecretHash = sha256Hex(deviceSecret);
    const delivery = createECDH("prime256v1");
    delivery.generateKeys();

    const req = {
      method: "POST",
      body: {
        clientType: "cli",
        displayName: "local-cli",
        deviceSecretHash,
        credentialDelivery: {
          algorithm: DELIVERY_ALGORITHM,
          publicKeyBase64: delivery.getPublicKey("base64", "uncompressed"),
        },
      },
      headers: {},
      socket: { remoteAddress: "127.0.0.1" },
    };
    const res = new FakeRes();

    const { startCliLink } = await import("../callables/cliLink.js");
    await runHttpHandler(startCliLink, req, res);

    expect(res.statusCode).toBe(200);
    expect(res.getHeader("cache-control")).toBe("no-store, max-age=0");
    const deviceCode = res.body && typeof res.body === "object" ? Reflect.get(res.body, "deviceCode") : undefined;
    expect(typeof deviceCode).toBe("string");
    const stored = cliLinkStore.get(`cli_link_sessions/${deviceCode}`);
    expect(stored).toBeTruthy();
    expect(stored.deviceSecretHash).toBeUndefined();
    expect(stored.deviceSecretVerifierHash).toBe(sha256Hex(deviceSecretHash));
    expect(stored.credentialDelivery).toMatchObject({
      algorithm: DELIVERY_ALGORITHM,
      publicKeyBase64: delivery.getPublicKey("base64", "uncompressed"),
    });
    expect(stored.purpose).toBe("remote_mcp");
    expect(Reflect.get(Object(res.body), "purpose")).toBe("remote_mcp");
    expect(Reflect.get(Object(res.body), "verificationUriComplete")).toContain("flow=remote_mcp");
    expect(Reflect.get(Object(res.body), "verificationUriComplete")).not.toContain("purpose=");
  });

  it("requires and persists a bounded flow binding for desktop auth", async () => {
    const deviceSecretHash = sha256Hex("desktop-device-secret");
    const delivery = createECDH("prime256v1");
    delivery.generateKeys();
    const baseBody = {
      purpose: "desktop_auth",
      deviceSecretHash,
      credentialDelivery: {
        algorithm: DESKTOP_DELIVERY_ALGORITHM,
        publicKeyBase64: delivery.getPublicKey("base64", "uncompressed"),
      },
    };

    const { startCliLink } = await import("../callables/cliLink.js");
    const missingBindingResponse = new FakeRes();
    await runHttpHandler(
      startCliLink,
      { method: "POST", body: baseBody, headers: {}, socket: { remoteAddress: "127.0.0.1" } },
      missingBindingResponse,
    );
    expect(missingBindingResponse.statusCode).toBe(400);
    expect(missingBindingResponse.body).toMatchObject({ error: "invalid_credential_delivery" });

    const malformedBindingResponse = new FakeRes();
    await runHttpHandler(
      startCliLink,
      {
        method: "POST",
        body: {
          ...baseBody,
          credentialDelivery: { ...baseBody.credentialDelivery, flowBinding: "predictable-session-label" },
        },
        headers: {},
        socket: { remoteAddress: "127.0.0.2" },
      },
      malformedBindingResponse,
    );
    expect(malformedBindingResponse.statusCode).toBe(400);
    expect(malformedBindingResponse.body).toMatchObject({ error: "invalid_credential_delivery" });

    const response = new FakeRes();
    await runHttpHandler(
      startCliLink,
      {
        method: "POST",
        body: {
          ...baseBody,
          clientType: "spoofed",
          displayName: "spoofed",
          credentialDelivery: { ...baseBody.credentialDelivery, flowBinding: DESKTOP_FLOW_BINDING },
        },
        headers: {},
        socket: { remoteAddress: "127.0.0.2" },
      },
      response,
    );

    expect(response.statusCode).toBe(200);
    const deviceCode = Reflect.get(Object(response.body), "deviceCode");
    const stored = cliLinkStore.get(`cli_link_sessions/${String(deviceCode)}`);
    expect(stored).toMatchObject({
      purpose: "desktop_auth",
      clientType: "linux_desktop",
      displayName: "OpenBurnBar Linux desktop",
      credentialDelivery: { flowBinding: DESKTOP_FLOW_BINDING },
    });
    expect(Reflect.get(Object(response.body), "verificationUriComplete")).toContain("flow=desktop_auth");
    expect(Reflect.get(Object(response.body), "verificationUriComplete")).not.toContain("purpose=");
  });

  it("rejects unknown purposes instead of silently changing credential classes", async () => {
    const delivery = createECDH("prime256v1");
    delivery.generateKeys();
    const response = new FakeRes();
    const { startCliLink } = await import("../callables/cliLink.js");
    await runHttpHandler(
      startCliLink,
      {
        method: "POST",
        body: {
          purpose: "admin_auth",
          deviceSecretHash: sha256Hex("secret"),
          credentialDelivery: {
            algorithm: DELIVERY_ALGORITHM,
            publicKeyBase64: delivery.getPublicKey("base64", "uncompressed"),
          },
        },
        headers: {},
        socket: { remoteAddress: "127.0.0.3" },
      },
      response,
    );
    expect(response.statusCode).toBe(400);
    expect(response.body).toMatchObject({ error: "invalid_purpose" });
  });

  it("returns approved envelopes idempotently after a simulated lost response", async () => {
    const deviceCode = "poll-device-code";
    const deviceSecret = "device-secret-for-poll";

    seedDoc(cliLinkStore, `cli_link_sessions/${deviceCode}`, {
      userCode: "ABCD-EFGH",
      deviceSecretVerifierHash: sha256Hex(sha256Hex(deviceSecret)),
      status: "approved",
      expiresAt: Timestamp.fromMillis(Date.now() + 60_000),
      credentialEnvelope: {
        algorithm: DELIVERY_ALGORITHM,
        ephemeralPublicKeyBase64: "ephemeral-key",
        ivBase64: "iv",
        ciphertextBase64: "ciphertext",
        authTagBase64: "auth-tag",
        aad: "openburnbar:cli-link:credential-delivery:v1",
      },
    });

    const req = {
      method: "POST",
      body: { deviceCode, deviceSecret },
      headers: {},
      socket: { remoteAddress: "127.0.0.1" },
    };
    const res = new FakeRes();

    const { pollCliLink } = await import("../callables/cliLink.js");
    await runHttpHandler(pollCliLink, req, res);

    expect(res.getHeader("cache-control")).toBe("no-store, max-age=0");
    expect(res.getHeader("expires")).toBe("0");
    expect(res.body).toMatchObject({
      status: "approved",
      purpose: "remote_mcp",
      credentialEnvelope: { ciphertextBase64: "ciphertext" },
    });
    expect(cliLinkStore.has(`cli_link_sessions/${deviceCode}`)).toBe(true);

    const retry = new FakeRes();
    await runHttpHandler(pollCliLink, req, retry);
    expect(retry).toMatchObject({ statusCode: 200, body: res.body });
  });

  it("cancels only after the polling device proves its secret", async () => {
    const deviceCode = "cancel-device-code";
    const deviceSecret = "cancel-device-secret";
    seedDoc(cliLinkStore, `cli_link_sessions/${deviceCode}`, {
      userCode: "ABCD-EFGH",
      deviceSecretVerifierHash: sha256Hex(sha256Hex(deviceSecret)),
      status: "pending",
      expiresAt: Timestamp.fromMillis(Date.now() + 60_000),
      credentialDelivery: undefined,
    });
    const { pollCliLink } = await import("../callables/cliLink.js");

    const denied = new FakeRes();
    await runHttpHandler(
      pollCliLink,
      {
        method: "POST",
        body: { deviceCode, deviceSecret: "wrong", action: "cancel" },
        headers: {},
        socket: { remoteAddress: "127.0.0.1" },
      },
      denied,
    );
    expect(denied.statusCode).toBe(403);
    expect(cliLinkStore.has(`cli_link_sessions/${deviceCode}`)).toBe(true);

    const cancelled = new FakeRes();
    await runHttpHandler(
      pollCliLink,
      {
        method: "POST",
        body: { deviceCode, deviceSecret, action: "cancel" },
        headers: {},
        socket: { remoteAddress: "127.0.0.1" },
      },
      cancelled,
    );
    expect(cancelled.body).toEqual({ status: "cancelled" });
    expect(cliLinkStore.has(`cli_link_sessions/${deviceCode}`)).toBe(false);
  });

  it("issues only a sealed Firebase custom token for desktop auth without Remote MCP gates", async () => {
    const delivery = createECDH("prime256v1");
    delivery.generateKeys();
    seedDoc(cliLinkStore, "cli_link_sessions/desktop-session", {
      userCode: "ABCD-EFGH",
      purpose: "desktop_auth",
      deviceSecretVerifierHash: sha256Hex(sha256Hex("device-secret")),
      status: "pending",
      expiresAt: Timestamp.fromMillis(Date.now() + 60_000),
      clientType: "linux_desktop",
      displayName: "OpenBurnBar Linux desktop",
      credentialDelivery: {
        algorithm: DESKTOP_DELIVERY_ALGORITHM,
        publicKeyBase64: delivery.getPublicKey("base64", "uncompressed"),
        flowBinding: DESKTOP_FLOW_BINDING,
      },
    });

    const { completeCliLink } = await import("../callables/cliLink.js");
    const result = await callableRunner(completeCliLink)(
      callableRequest("alice-uid", {
        userCode: "abcdefgh",
        expectedPurpose: "desktop_auth",
        nonce: "nonce-desktop-auth",
      }),
    );

    expect(result).toMatchObject({ ok: true, purpose: "desktop_auth" });
    expect(createCustomTokenMock).toHaveBeenCalledWith("alice-uid");
    expect(assertActiveBurnBarProEntitlementMock).not.toHaveBeenCalled();
    expect(assertCloudFeatureNotSuspendedMock).not.toHaveBeenCalled();
    expect(issueGrantMock).not.toHaveBeenCalled();

    const stored = cliLinkStore.get("cli_link_sessions/desktop-session");
    expect(stored.status).toBe("approved");
    expect(JSON.stringify(stored)).not.toContain("firebase-custom-token");
    const envelope = stored.credentialEnvelope;
    expect(envelope.algorithm).toBe(DESKTOP_DELIVERY_ALGORITHM);
    expect(envelope.aad).toBe(`openburnbar:desktop-auth:credential-delivery:v2:${DESKTOP_FLOW_BINDING}`);
    expect(decryptEnvelope(delivery, envelope, DESKTOP_DELIVERY_KEY_CONTEXT)).toMatchObject({
      schemaVersion: 1,
      purpose: "desktop_auth",
      credentialKind: "firebase_custom_token",
      firebaseCustomToken: "firebase-custom-token",
      apiKey: expect.stringMatching(/^AIza/u),
      projectId: expect.any(String),
    });
  });

  it("keeps legacy Remote MCP completion on the v1 sealed wire contract", async () => {
    const delivery = createECDH("prime256v1");
    delivery.generateKeys();
    issueGrantMock.mockResolvedValue({
      accessToken: "remote-access-token",
      refreshToken: "remote-refresh-token",
      expiresIn: 900,
      clientId: "remote-client-id",
      scopes: ["search:read"],
      grantMode: "local_decrypt_shim",
      tokenSigningAlgorithm: "hmac-sha256",
    });
    seedDoc(cliLinkStore, "cli_link_sessions/legacy-remote-session", {
      userCode: "ABCD-EFGH",
      deviceSecretVerifierHash: sha256Hex(sha256Hex("device-secret")),
      status: "pending",
      expiresAt: Timestamp.fromMillis(Date.now() + 60_000),
      clientType: "cli",
      displayName: "Legacy CLI",
      credentialDelivery: {
        algorithm: DELIVERY_ALGORITHM,
        publicKeyBase64: delivery.getPublicKey("base64", "uncompressed"),
      },
    });

    const { completeCliLink } = await import("../callables/cliLink.js");
    const result = await callableRunner(completeCliLink)(
      callableRequest("alice-uid", { userCode: "abcdefgh", nonce: "nonce-legacy-remote" }),
    );

    expect(result).toMatchObject({ ok: true, purpose: "remote_mcp", scopes: ["search:read"] });
    expect(assertCloudFeatureNotSuspendedMock).toHaveBeenCalledWith(expect.anything(), "alice-uid", "remote_mcp");
    expect(assertActiveBurnBarProEntitlementMock).toHaveBeenCalledWith("alice-uid");
    expect(issueGrantMock).toHaveBeenCalledOnce();
    expect(createCustomTokenMock).not.toHaveBeenCalled();

    const stored = cliLinkStore.get("cli_link_sessions/legacy-remote-session");
    expect(stored).toMatchObject({ status: "approved", tokenSigningAlgorithm: "hmac-sha256" });
    expect(stored.purpose).toBeUndefined();
    expect(JSON.stringify(stored)).not.toContain("remote-access-token");
    expect(JSON.stringify(stored)).not.toContain("remote-refresh-token");
    expect(stored.credentialEnvelope.aad).toBe("openburnbar:cli-link:credential-delivery:v1");
    expect(decryptEnvelope(delivery, stored.credentialEnvelope, REMOTE_DELIVERY_KEY_CONTEXT)).toEqual({
      accessToken: "remote-access-token",
      refreshToken: "remote-refresh-token",
      expiresIn: 900,
      clientId: "remote-client-id",
      scopes: ["search:read"],
      grantMode: "local_decrypt_shim",
    });
  });

  it("allows a link session to be approved only once", async () => {
    const delivery = createECDH("prime256v1");
    delivery.generateKeys();
    seedDoc(cliLinkStore, "cli_link_sessions/single-writer-session", {
      userCode: "ABCD-EFGH",
      purpose: "desktop_auth",
      deviceSecretVerifierHash: sha256Hex(sha256Hex("device-secret")),
      status: "pending",
      expiresAt: Timestamp.fromMillis(Date.now() + 60_000),
      credentialDelivery: {
        algorithm: DESKTOP_DELIVERY_ALGORITHM,
        publicKeyBase64: delivery.getPublicKey("base64", "uncompressed"),
        flowBinding: DESKTOP_FLOW_BINDING,
      },
    });

    const { completeCliLink } = await import("../callables/cliLink.js");
    const run = callableRunner(completeCliLink);
    const request = callableRequest("alice-uid", {
      userCode: "ABCD-EFGH",
      expectedPurpose: "desktop_auth",
      nonce: "nonce-single-writer",
    });

    await expect(run(request)).resolves.toMatchObject({ ok: true, purpose: "desktop_auth" });
    await expect(run(request)).rejects.toMatchObject({ code: "not-found" });
    expect(createCustomTokenMock).toHaveBeenCalledOnce();
    expect(cliLinkStore.get("cli_link_sessions/single-writer-session")?.status).toBe("approved");
  });

  it("releases the single-writer claim when desktop credential minting fails", async () => {
    const delivery = createECDH("prime256v1");
    delivery.generateKeys();
    createCustomTokenMock.mockRejectedValue(new Error("token mint unavailable"));
    seedDoc(cliLinkStore, "cli_link_sessions/retryable-desktop-session", {
      userCode: "ABCD-EFGH",
      purpose: "desktop_auth",
      deviceSecretVerifierHash: sha256Hex(sha256Hex("device-secret")),
      status: "pending",
      expiresAt: Timestamp.fromMillis(Date.now() + 60_000),
      credentialDelivery: {
        algorithm: DESKTOP_DELIVERY_ALGORITHM,
        publicKeyBase64: delivery.getPublicKey("base64", "uncompressed"),
        flowBinding: DESKTOP_FLOW_BINDING,
      },
    });

    const { completeCliLink } = await import("../callables/cliLink.js");
    await expect(
      callableRunner(completeCliLink)(
        callableRequest("alice-uid", {
          userCode: "ABCD-EFGH",
          expectedPurpose: "desktop_auth",
          nonce: "nonce-retryable-desktop",
        }),
      ),
    ).rejects.toThrow("token mint unavailable");

    expect(cliLinkStore.get("cli_link_sessions/retryable-desktop-session")).toMatchObject({ status: "pending" });
    expect(cliLinkStore.get("cli_link_sessions/retryable-desktop-session")?.approvalClaimUid).toBeUndefined();
    expect(cliLinkStore.get("cli_link_sessions/retryable-desktop-session")?.approvalClaimID).toBeUndefined();
    expect(cliLinkStore.get("cli_link_sessions/retryable-desktop-session")?.approvalClaimedAt).toBeUndefined();
  });

  it("reclaims a crashed approval only after its claim lease expires", async () => {
    const delivery = createECDH("prime256v1");
    delivery.generateKeys();
    seedDoc(cliLinkStore, "cli_link_sessions/stale-approval-session", {
      userCode: "ABCD-EFGH",
      purpose: "desktop_auth",
      deviceSecretVerifierHash: sha256Hex(sha256Hex("device-secret")),
      status: "approving",
      approvalClaimUid: "crashed-invocation",
      approvalClaimID: "abandoned-claim",
      approvalClaimedAt: Timestamp.fromMillis(Date.now() - 61_000),
      expiresAt: Timestamp.fromMillis(Date.now() + 60_000),
      credentialDelivery: {
        algorithm: DESKTOP_DELIVERY_ALGORITHM,
        publicKeyBase64: delivery.getPublicKey("base64", "uncompressed"),
        flowBinding: DESKTOP_FLOW_BINDING,
      },
    });

    const { completeCliLink } = await import("../callables/cliLink.js");
    await expect(
      callableRunner(completeCliLink)(
        callableRequest("alice-uid", {
          userCode: "ABCD-EFGH",
          expectedPurpose: "desktop_auth",
          nonce: "nonce-stale-claim",
        }),
      ),
    ).resolves.toMatchObject({ ok: true, purpose: "desktop_auth" });

    const stored = cliLinkStore.get("cli_link_sessions/stale-approval-session");
    expect(stored).toMatchObject({ status: "approved" });
    expect(stored?.approvalClaimUid).toBeUndefined();
    expect(stored?.approvalClaimID).toBeUndefined();
    expect(createCustomTokenMock).toHaveBeenCalledOnce();
  });

  it("rejects a displayed purpose mismatch before minting credentials", async () => {
    const delivery = createECDH("prime256v1");
    delivery.generateKeys();
    seedDoc(cliLinkStore, "cli_link_sessions/purpose-session", {
      userCode: "ABCD-EFGH",
      purpose: "desktop_auth",
      deviceSecretVerifierHash: sha256Hex(sha256Hex("device-secret")),
      status: "pending",
      expiresAt: Timestamp.fromMillis(Date.now() + 60_000),
      credentialDelivery: {
        algorithm: DESKTOP_DELIVERY_ALGORITHM,
        publicKeyBase64: delivery.getPublicKey("base64", "uncompressed"),
        flowBinding: DESKTOP_FLOW_BINDING,
      },
    });

    const { completeCliLink } = await import("../callables/cliLink.js");
    await expect(
      callableRunner(completeCliLink)(
        callableRequest("alice-uid", {
          userCode: "ABCD-EFGH",
          expectedPurpose: "remote_mcp",
          nonce: "nonce-purpose-mismatch",
        }),
      ),
    ).rejects.toMatchObject({ code: "failed-precondition" });
    expect(createCustomTokenMock).not.toHaveBeenCalled();
    expect(issueGrantMock).not.toHaveBeenCalled();
  });

  it("rejects malformed delivery sessions before issuing a remote grant", async () => {
    const deviceSecretHash = sha256Hex("legacy-device-secret");

    seedDoc(cliLinkStore, "cli_link_sessions/legacy-session", {
      userCode: "ABCD-EFGH",
      deviceSecretVerifierHash: sha256Hex(deviceSecretHash),
      status: "pending",
      expiresAt: Timestamp.fromMillis(Date.now() + 60_000),
      clientType: "cli",
      displayName: "legacy-cli",
      credentialDelivery: {
        algorithm: DELIVERY_ALGORITHM,
        publicKeyBase64: "not-a-valid-p256-key",
      },
    });

    const { completeCliLink } = await import("../callables/cliLink.js");
    const run = callableRunner(completeCliLink);

    await expect(run(callableRequest("alice-uid", { userCode: "ABCD-EFGH", nonce: "nonce-1" }))).rejects.toMatchObject({
      code: "invalid-argument",
    });
    expect(issueGrantMock).not.toHaveBeenCalled();
    expect(cliLinkStore.get("cli_link_sessions/legacy-session")?.status).toBe("pending");
  });

  it("does not issue CLI-link remote MCP credentials while the feature is suspended", async () => {
    assertCloudFeatureNotSuspendedMock.mockRejectedValue(
      Object.assign(new Error("Cloud features are suspended for this account."), { code: "permission-denied" }),
    );
    const delivery = createECDH("prime256v1");
    delivery.generateKeys();
    const userCode = "SUSP-TEST";

    seedDoc(cliLinkStore, "cli_link_sessions/suspended-session", {
      userCode,
      deviceSecretVerifierHash: sha256Hex(sha256Hex("device-secret")),
      status: "pending",
      expiresAt: Timestamp.fromMillis(Date.now() + 60_000),
      clientType: "cli",
      displayName: "suspended-cli",
      credentialDelivery: {
        algorithm: DELIVERY_ALGORITHM,
        publicKeyBase64: delivery.getPublicKey("base64", "uncompressed"),
      },
    });

    const { completeCliLink } = await import("../callables/cliLink.js");
    const run = callableRunner(completeCliLink);

    await expect(run(callableRequest("alice-uid", { userCode, nonce: "nonce-2" }))).rejects.toMatchObject({
      code: "permission-denied",
    });
    expect(assertCloudFeatureNotSuspendedMock).toHaveBeenCalledWith(expect.anything(), "alice-uid", "remote_mcp");
    expect(issueGrantMock).not.toHaveBeenCalled();
  });
});

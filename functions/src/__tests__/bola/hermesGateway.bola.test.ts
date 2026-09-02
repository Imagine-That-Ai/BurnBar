/**
 * BOLA negative coverage — Hermes Gateway callables + HTTP dispatcher.
 */
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { describe, expect, it, vi } from "vitest";

import {
  ALICE_UID,
  BOB_UID,
  callableRunner,
  pathKeyedFirestore,
  seedDoc,
  tier2CallableProof,
} from "./callableBolaHarness.js";

const bolaStore: Map<string, Record<string, unknown>> = vi.hoisted(() => new Map());

process.env.ENFORCE_APP_CHECK = "false";

vi.mock("firebase-functions/logger", () => ({ info: vi.fn(), error: vi.fn(), warn: vi.fn(), debug: vi.fn() }));
vi.mock("../../sentry.js", () => ({ setSentryUser: vi.fn(), captureException: vi.fn() }));
vi.mock("../../auth.js", () => ({
  assertAuth: vi.fn(),
  enforceAuthAndAppCheck: vi.fn(),
  assertAppCheck: vi.fn(),
  assertOwnership: vi.fn(),
}));
vi.mock("../../callables/highRiskOwnerAction.js", () => ({
  enforceHighRiskOwnerAction: vi.fn(async () => undefined),
}));
vi.mock("../../callables/computerUseSecurity.js", async () => {
  const actual = await vi.importActual<typeof import("../../callables/computerUseSecurity.js")>(
    "../../callables/computerUseSecurity.js",
  );
  return {
    ...actual,
    requireTrustedDeviceActionProof: vi.fn(async () => undefined),
  };
});
vi.mock("../../callables/shared.js", async () => {
  const actual = await vi.importActual<typeof import("../../callables/shared.js")>("../../callables/shared.js");
  return {
    ...actual,
    isActiveHostedQuotaEntitlement: () => true,
    isActivePremiumEntitlement: () => true,
    isActiveBurnBarCloudProEntitlement: () => true,
  };
});
vi.mock("firebase-admin/firestore", () => ({
  FieldValue: { delete: () => ({ __delete: true }) },
  Timestamp: {
    now: () => ({ toMillis: () => Date.now() }),
    fromMillis: (ms: number) => ({ toMillis: () => ms }),
  },
}));
vi.mock("../../adminRuntime.js", () => ({ db: pathKeyedFirestore(bolaStore) }));

export const BOLA_MANIFEST = {
  getHermesGatewayAttachmentDownloadUrl: ["getHermesGatewayAttachmentDownloadUrl rejects cross-user object access"],
  approveHermesGatewayDeviceGrant: ["approveHermesGatewayDeviceGrant rejects cross-user object access"],
  revokeHermesGatewayClient: ["revokeHermesGatewayClient rejects cross-user object access"],
  rotateHermesGatewayClientToken: ["rotateHermesGatewayClientToken rejects cross-user object access"],
  enqueueHermesGatewayEvent: ["enqueueHermesGatewayEvent rejects cross-user object access"],
  setHermesGatewayOversightMode: ["setHermesGatewayOversightMode rejects cross-user object access"],
  respondHermesGatewayApproval: ["respondHermesGatewayApproval rejects cross-user object access"],
  burnBarHermesGateway: ["burnBarHermesGateway rejects cross-user object access"],
} as const;

describe("BOLA — hermesGateway callables", () => {
  it("getHermesGatewayAttachmentDownloadUrl rejects cross-user object access", async () => {
    const mod = await import("../../callables/hermesGateway.js");
    const run = callableRunner(mod.getHermesGatewayAttachmentDownloadUrl);

    await tier2CallableProof(bolaStore, {
      exportedName: "getHermesGatewayAttachmentDownloadUrl",
      run,
      expectedCode: "not-found",
      expectedOutcome: "throws",
      payload: { attachmentId: "bob-att", clientId: "bob-client", destinationId: "burnbar:home" },
    });
  });

  it("approveHermesGatewayDeviceGrant rejects cross-user object access", async () => {
    const mod = await import("../../callables/hermesGateway.js");
    const run = callableRunner(mod.approveHermesGatewayDeviceGrant);

    await tier2CallableProof(bolaStore, {
      exportedName: "approveHermesGatewayDeviceGrant",
      run,
      expectedCode: "not-found",
      expectedOutcome: "throws",
      payload: { clientId: "bob-client", userCode: "ABCDEFGH" },
    });
  });

  it("revokeHermesGatewayClient rejects cross-user object access", async () => {
    const mod = await import("../../callables/hermesGateway.js");
    const run = callableRunner(mod.revokeHermesGatewayClient);

    await tier2CallableProof(bolaStore, {
      exportedName: "revokeHermesGatewayClient",
      run,
      expectedCode: "not-found",
      expectedOutcome: "throws",
      payload: { clientId: "bob-client" },
    });
  });

  it("rotateHermesGatewayClientToken rejects cross-user object access", async () => {
    const mod = await import("../../callables/hermesGateway.js");
    const run = callableRunner(mod.rotateHermesGatewayClientToken);

    await tier2CallableProof(bolaStore, {
      exportedName: "rotateHermesGatewayClientToken",
      run,
      expectedCode: "not-found",
      expectedOutcome: "throws",
      payload: { clientId: "bob-client" },
    });
  });

  it("enqueueHermesGatewayEvent rejects cross-user object access", async () => {
    const mod = await import("../../callables/hermesGateway.js");
    const run = callableRunner(mod.enqueueHermesGatewayEvent);

    await tier2CallableProof(bolaStore, {
      exportedName: "enqueueHermesGatewayEvent",
      run,
      expectedCode: "failed-precondition",
      expectedOutcome: "throws",
      payload: {
        clientId: "bob-client",
        targetClientId: "bob-client",
        eventId: "bob-event",
        eventType: "message",
        payload: { sealed: true },
      },
    });
  });

  it("setHermesGatewayOversightMode rejects cross-user object access", async () => {
    const mod = await import("../../callables/hermesGateway.js");
    const run = callableRunner(mod.setHermesGatewayOversightMode);

    await tier2CallableProof(bolaStore, {
      exportedName: "setHermesGatewayOversightMode",
      run,
      expectedCode: "failed-precondition",
      expectedOutcome: "throws",
      payload: { clientId: "bob-client", mode: "supervised" },
    });
  });

  it("respondHermesGatewayApproval rejects cross-user object access", async () => {
    const mod = await import("../../callables/hermesGateway.js");
    const run = callableRunner(mod.respondHermesGatewayApproval);

    await tier2CallableProof(bolaStore, {
      exportedName: "respondHermesGatewayApproval",
      run,
      expectedCode: "not-found",
      expectedOutcome: "throws",
      payload: {
        clientId: "bob-client",
        deviceId: "bob-device",
        eventId: "bob-event",
        approvalId: "bob-approval",
        approve: true,
        nonce: "alice-nonce-for-bob-approval",
        actionProof: { signedAction: "bob-event" },
      },
    });
  });
});

describe("BOLA — burnBarHermesGateway HTTP", () => {
  it("burnBarHermesGateway rejects cross-user object access", async () => {
    const { hashHermesGatewayBearerToken } = await import("../../hermesGateway.js");
    const aliceClientId = "hgw_alice_client";
    const aliceToken = "obb_hgw_alice_token";
    const aliceTokenHash = hashHermesGatewayBearerToken(aliceToken);
    const keys = generateKeyPairSync("ed25519");
    const pubB64 = Buffer.from(keys.publicKey.export({ format: "der", type: "spki" }))
      .subarray(-32)
      .toString("base64");
    const keyId = createHash("sha256").update(pubB64).digest("hex").slice(0, 32);

    const stableJSONString = (value: unknown): string => {
      if (value === null || typeof value === "string" || typeof value === "number" || typeof value === "boolean") {
        return JSON.stringify(value);
      }
      if (Array.isArray(value)) return `[${value.map(stableJSONString).join(",")}]`;
      if (typeof value === "object") {
        return `{${Object.entries(value)
          .filter(([, item]) => item !== undefined)
          .sort(([left], [right]) => left.localeCompare(right))
          .map(([key, item]) => `${JSON.stringify(key)}:${stableJSONString(item)}`)
          .join(",")}}`;
      }
      return "{}";
    };

    bolaStore.clear();
    seedDoc(bolaStore, `hermes_gateway_token_index/${aliceTokenHash}`, {
      uid: ALICE_UID,
      clientId: aliceClientId,
      status: "active",
      expiresAt: new Date(Date.now() + 86_400_000).toISOString(),
    });
    const nowIso = new Date().toISOString();
    seedDoc(bolaStore, `users/${ALICE_UID}/hermes_gateway_clients/${aliceClientId}`, {
      id: aliceClientId,
      uid: ALICE_UID,
      displayName: "Alice Agent",
      status: "active",
      tokenHash: aliceTokenHash,
      tokenPreview: "obb_hgw_...alice",
      scopes: ["hermes.gateway.read", "hermes.gateway.write"],
      homeDestinationId: "burnbar:home",
      agentClientSigningPublicKeyBase64: pubB64,
      agentClientSigningKeyId: keyId,
      popRequired: true,
      expiresAt: new Date(Date.now() + 86_400_000).toISOString(),
      createdAt: nowIso,
      updatedAt: nowIso,
      schemaVersion: 2,
    });
    seedDoc(bolaStore, `users/${BOB_UID}/hermes_gateway_attachments/bob-att`, {
      id: "bob-att",
      clientId: "bob-client",
      status: "pending_upload",
      storagePath: `users/${BOB_UID}/hermes_gateway_attachments/bob-client/bob-att`,
      byteCount: 1,
      expiresAt: new Date(Date.now() + 86_400_000).toISOString(),
      schemaVersion: 2,
    });

    const body = { attachmentId: "bob-att", sha256: "a".repeat(64) };
    const timestamp = new Date().toISOString();
    const nonce = `bola-pop-${Date.now()}`;
    const bodyHash = createHash("sha256").update(stableJSONString(body)).digest("hex");
    const popPayload = Buffer.from(
      [
        "OpenBurnBar.HermesGatewayPoP.v1",
        aliceTokenHash,
        "POST",
        "/attachments/finalize",
        bodyHash,
        nonce,
        timestamp,
      ].join("\n"),
      "utf8",
    );
    const headers: Record<string, string> = {
      authorization: `Bearer ${aliceToken}`,
      "content-type": "application/json",
      "x-openburnbar-pop-nonce": nonce,
      "x-openburnbar-pop-timestamp": timestamp,
      "x-openburnbar-pop-body-sha256": bodyHash,
      "x-openburnbar-pop-signature-ed25519": sign(null, popPayload, keys.privateKey).toString("base64"),
    };
    const req = {
      method: "POST",
      path: "/attachments/finalize",
      url: "/attachments/finalize",
      body,
      headers,
      query: {},
      socket: { remoteAddress: "127.0.0.1" },
      get: (name: string) => headers[name.toLowerCase()],
    };
    const captured: { status: number; body: unknown } = { status: 0, body: undefined };
    const res = {
      status(code: number) {
        captured.status = code;
        return res;
      },
      json(payload: unknown) {
        captured.body = payload;
      },
      send(payload?: unknown) {
        captured.body = payload;
      },
      set() {},
    };

    const { dispatchHermesGatewayRequest } = await import("../../callables/hermesGateway.js");
    await dispatchHermesGatewayRequest(req, res);

    expect(captured.status).toBeGreaterThanOrEqual(400);
    expect(captured.status).not.toBe(200);
  });
});
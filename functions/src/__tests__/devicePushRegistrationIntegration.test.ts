/**
 * F-RR10-007 — registerDevicePushEndpoint must bind the push endpoint to a
 * trusted escrow device and reject arbitrary device IDs or revoked/pending
 * devices.
 */
import { describe, expect, it, vi, beforeEach } from "vitest";
import type { CallableRequest } from "firebase-functions/v2/https";

process.env.ENFORCE_APP_CHECK = "false";

type StoredDoc = { path: string; data: Record<string, unknown> };
type TestState = {
  escrowDevice: Record<string, unknown> | null;
  storedDocs: StoredDoc[];
};

const state = vi.hoisted<TestState>(() => ({
  escrowDevice: null,
  storedDocs: [],
}));

vi.mock("firebase-admin/firestore", async () => {
  const actual = await vi.importActual<typeof import("firebase-admin/firestore")>("firebase-admin/firestore");
  return {
    ...actual,
    getFirestore: () => ({
      settings: vi.fn(),
      doc: (path: string) => {
        const parts = path.split("/");
        if (parts.length === 4 && parts[0] === "users" && parts[2] === "escrow_devices") {
          return {
            get: async () => ({
              exists: state.escrowDevice !== null,
              data: () => state.escrowDevice,
              get: (field: string) => state.escrowDevice?.[field],
            }),
          };
        }
        if (parts.length === 4 && parts[0] === "users" && parts[2] === "devices") {
          return {
            get: async () => ({ exists: false }),
            set: async (data: Record<string, unknown>, _opts: unknown) => {
              state.storedDocs.push({ path, data });
            },
          };
        }
        return { get: async () => ({ exists: false }) };
      },
      collection: (name: string) => {
        if (name !== "users") return { doc: () => ({}) };
        return {
          doc: (uid: string) => ({
            collection: (sub: string) => ({
              doc: (docId: string) => {
                if (sub === "escrow_devices") {
                  return {
                    get: async () => ({
                      exists: state.escrowDevice !== null,
                      data: () => state.escrowDevice,
                      get: (field: string) => state.escrowDevice?.[field],
                    }),
                  };
                }
                if (sub === "devices") {
                  return {
                    set: async (data: Record<string, unknown>, _opts: unknown) => {
                      state.storedDocs.push({ path: `users/${uid}/devices/${docId}`, data });
                    },
                  };
                }
                return { get: async () => ({ exists: false }) };
              },
            }),
          }),
        };
      },
    }),
    FieldValue: {
      serverTimestamp: () => ({ _kind: "serverTimestamp" }),
    },
  };
});

vi.mock("firebase-functions/logger", () => ({
  info: vi.fn(),
  error: vi.fn(),
  warn: vi.fn(),
  debug: vi.fn(),
}));

vi.mock("../logging.js", () => ({
  logInfo: vi.fn(),
  logError: vi.fn(),
  wrapCallableHandler: (_name: string, handler: unknown) => handler,
}));

import { registerDevicePushEndpoint } from "../callables/devicePushRegistration.js";

type DevicePushRequest = Parameters<typeof registerDevicePushEndpoint.run>[0];

function decodedIdToken(uid: string) {
  return Object.assign(Object.create(null), {
    aud: "burnbar-test",
    auth_time: 1,
    exp: 2,
    firebase: { identities: {}, sign_in_provider: "custom" },
    iat: 1,
    iss: "https://securetoken.google.com/burnbar-test",
    sub: uid,
    uid,
  });
}

function callableRequest(data: Record<string, unknown>): CallableRequest<Record<string, unknown>> {
  const request: CallableRequest<Record<string, unknown>> = Object.create(null);
  request.auth = { uid: "u1", token: decodedIdToken("u1"), rawToken: "test-id-token" };
  request.app = { appId: "test-app", token: Object.create(null) };
  request.rawRequest = Object.assign(Object.create(null), { headers: {} });
  request.acceptsStreaming = false;
  request.data = data;
  return request;
}

function authedRequest(data: Record<string, unknown>): DevicePushRequest {
  return callableRequest(data);
}

const trustedIOSDevice = {
  deviceId: "iphone-1",
  deviceName: "iPhone",
  platform: "iOS",
  trustState: "trusted",
};

describe("registerDevicePushEndpoint — F-RR10-007 device binding", () => {
  beforeEach(() => {
    state.escrowDevice = trustedIOSDevice;
    state.storedDocs.length = 0;
  });

  it("registers an APNs token for a trusted device with matching platform", async () => {
    await registerDevicePushEndpoint.run(
      authedRequest({
        deviceId: "iphone-1",
        platform: "iOS",
        apnsToken: "a".repeat(64),
      }),
    );

    expect(state.storedDocs).toHaveLength(1);
    const written = state.storedDocs[0].data;
    expect(written.deviceId).toBe("iphone-1");
    expect(written.platform).toBe("iOS");
    expect(written.apnsToken).toBe("a".repeat(64));
  });

  it("rejects registration for a non-existent escrow device", async () => {
    state.escrowDevice = null;
    await expect(
      registerDevicePushEndpoint.run(
        authedRequest({ deviceId: "orphan-1", apnsToken: "a".repeat(64) }),
      ),
    ).rejects.toThrow(/registered escrow device/);
    expect(state.storedDocs).toHaveLength(0);
  });

  it("rejects registration for a revoked device", async () => {
    state.escrowDevice = { ...trustedIOSDevice, trustState: "revoked" };
    await expect(
      registerDevicePushEndpoint.run(
        authedRequest({ deviceId: "iphone-1", apnsToken: "a".repeat(64) }),
      ),
    ).rejects.toThrow(/trusted devices may register/);
    expect(state.storedDocs).toHaveLength(0);
  });

  it("rejects registration for a pending device", async () => {
    state.escrowDevice = { ...trustedIOSDevice, trustState: "pending" };
    await expect(
      registerDevicePushEndpoint.run(
        authedRequest({ deviceId: "iphone-1", apnsToken: "a".repeat(64) }),
      ),
    ).rejects.toThrow(/trusted devices may register/);
    expect(state.storedDocs).toHaveLength(0);
  });

  it("rejects registration when the platform does not match the escrow device", async () => {
    await expect(
      registerDevicePushEndpoint.run(
        authedRequest({ deviceId: "iphone-1", platform: "android", fcmToken: "token" }),
      ),
    ).rejects.toThrow(/does not match escrow device platform/);
    expect(state.storedDocs).toHaveLength(0);
  });

  it("infers the platform from the escrow device when not supplied", async () => {
    await registerDevicePushEndpoint.run(
      authedRequest({
        deviceId: "iphone-1",
        apnsToken: "a".repeat(64),
      }),
    );

    expect(state.storedDocs).toHaveLength(1);
    expect(state.storedDocs[0].data.platform).toBe("iOS");
  });
});

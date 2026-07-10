/**
 * F-RR10-007 — registerDevicePushEndpoint must bind the push endpoint to a
 * trusted escrow device and reject arbitrary device IDs or revoked/pending
 * devices.
 */
import { describe, expect, it, vi, beforeEach } from "vitest";

process.env.ENFORCE_APP_CHECK = "false";

const state = vi.hoisted(
  (): {
    escrowDevice: Record<string, unknown> | null;
    storedDocs: Array<{ path: string; data: Record<string, unknown> }>;
  } => ({
    escrowDevice: null,
    storedDocs: [],
  }),
);

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

vi.mock("../logging.js", async () => {
  const actual = await vi.importActual<typeof import("../logging.js")>("../logging.js");
  return {
    ...actual,
    logInfo: vi.fn(),
    logError: vi.fn(),
  };
});

import { registerDevicePushEndpoint } from "../callables/devicePushRegistration.js";

function callableRunner(candidate: unknown): (request: unknown) => Promise<unknown> {
  if (
    candidate === null ||
    (typeof candidate !== "object" && typeof candidate !== "function") ||
    !("run" in candidate)
  ) {
    throw new Error("callable test target is missing run()");
  }
  const { run } = candidate;
  if (typeof run !== "function") {
    throw new Error("callable test target run property is not callable");
  }
  return async (request: unknown) => run.call(candidate, request);
}

const runRegisterDevicePushEndpoint = callableRunner(registerDevicePushEndpoint);

function authedRequest(data: Record<string, unknown>) {
  return {
    auth: { uid: "u1", token: {} },
    app: { appId: "1:1234567890:ios:openburnbar-test" },
    rawRequest: { headers: {} },
    data,
  };
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
    await runRegisterDevicePushEndpoint(
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
      runRegisterDevicePushEndpoint(authedRequest({ deviceId: "orphan-1", apnsToken: "a".repeat(64) })),
    ).rejects.toThrow(/registered escrow device/);
    expect(state.storedDocs).toHaveLength(0);
  });

  it("rejects registration for a revoked device", async () => {
    state.escrowDevice = { ...trustedIOSDevice, trustState: "revoked" };
    await expect(
      runRegisterDevicePushEndpoint(authedRequest({ deviceId: "iphone-1", apnsToken: "a".repeat(64) })),
    ).rejects.toThrow(/trusted devices may register/);
    expect(state.storedDocs).toHaveLength(0);
  });

  it("rejects registration for a pending device", async () => {
    state.escrowDevice = { ...trustedIOSDevice, trustState: "pending" };
    await expect(
      runRegisterDevicePushEndpoint(authedRequest({ deviceId: "iphone-1", apnsToken: "a".repeat(64) })),
    ).rejects.toThrow(/trusted devices may register/);
    expect(state.storedDocs).toHaveLength(0);
  });

  it("rejects registration when the platform does not match the escrow device", async () => {
    await expect(
      runRegisterDevicePushEndpoint(authedRequest({ deviceId: "iphone-1", platform: "android", fcmToken: "token" })),
    ).rejects.toThrow(/does not match escrow device platform/);
    expect(state.storedDocs).toHaveLength(0);
  });

  it("infers the platform from the escrow device when not supplied", async () => {
    await runRegisterDevicePushEndpoint(
      authedRequest({
        deviceId: "iphone-1",
        apnsToken: "a".repeat(64),
      }),
    );

    expect(state.storedDocs).toHaveLength(1);
    expect(state.storedDocs[0].data.platform).toBe("iOS");
  });
});

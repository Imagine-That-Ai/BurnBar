import { describe, it, vi } from "vitest";

import { callableRunner, pathKeyedFirestore, tier2CallableProof } from "./callableBolaHarness.js";

process.env.ENFORCE_APP_CHECK = "false";

const bolaStore = vi.hoisted(() => new Map<string, Record<string, unknown>>());

vi.mock("../../adminRuntime.js", () => ({ db: pathKeyedFirestore(bolaStore) }));

export const BOLA_MANIFEST = {
  registerDevicePushEndpoint: ["registerDevicePushEndpoint rejects cross-user object access"],
} as const;

describe("BOLA - device push registration", () => {
  it("registerDevicePushEndpoint rejects cross-user object access", async () => {
    const { registerDevicePushEndpoint } = await import("../../callables/devicePushRegistration.js");
    const run = callableRunner(registerDevicePushEndpoint);

    await tier2CallableProof(bolaStore, {
      exportedName: "registerDevicePushEndpoint",
      run,
      payload: { deviceId: "bob-device", apnsToken: "a".repeat(64) },
      expectedCode: "permission-denied",
      expectedOutcome: "throws",
    });
  });
});

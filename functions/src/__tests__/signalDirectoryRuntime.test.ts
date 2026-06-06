import { describe, expect, it } from "vitest";

import { sessionInvolvesDevice } from "../signalDirectoryRuntime.js";

describe("sessionInvolvesDevice", () => {
  it("matches sessions the device owns", () => {
    expect(sessionInvolvesDevice({ deviceId: "device-a", peerDeviceId: "device-b" }, "device-a")).toBe(true);
  });
  it("matches sessions where the device is the peer", () => {
    expect(sessionInvolvesDevice({ deviceId: "device-a", peerDeviceId: "device-b" }, "device-b")).toBe(true);
  });
  it("does not match unrelated sessions", () => {
    expect(sessionInvolvesDevice({ deviceId: "device-a", peerDeviceId: "device-b" }, "device-c")).toBe(false);
  });
});

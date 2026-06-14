import { describe, expect, it } from "vitest";

import { __testing__ } from "../callables/devicePushRegistration.js";

describe("registerDevicePushEndpoint validators", () => {
  it("accepts bounded FCM tokens without logging or parsing token contents", () => {
    expect(__testing__.optionalPushToken("fcm-token", "fcmToken")).toBe("fcm-token");
    expect(__testing__.optionalPushToken("x".repeat(4096), "fcmToken")).toHaveLength(4096);
  });

  it("rejects oversized FCM tokens", () => {
    expect(() => __testing__.optionalPushToken("x".repeat(4097), "fcmToken")).toThrow(/fcmToken/u);
  });

  it("requires APNs/VoIP tokens to be bounded hex", () => {
    expect(__testing__.optionalHexPushToken("a".repeat(64), "voipDeviceToken")).toBe("a".repeat(64));
    expect(() => __testing__.optionalHexPushToken("not-hex", "voipDeviceToken")).toThrow(/hex APNs token/u);
    expect(() => __testing__.optionalHexPushToken("a".repeat(1024), "voipDeviceToken")).toThrow(/hex APNs token/u);
  });

  it("rejects unsupported platform labels", () => {
    expect(__testing__.platformOrUndefined("ios")).toBe("ios");
    expect(() => __testing__.platformOrUndefined("browser-extension")).toThrow(/Unsupported device platform/u);
  });
});

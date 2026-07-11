import type { CallableRequest } from "firebase-functions/v2/https";
import { describe, expect, it, vi } from "vitest";

const { config } = vi.hoisted(() => ({
  config: {
    enforceAppCheck: true,
    linuxAppCheckAppID: "1:123456:web:linux-app",
    windowsAppCheckAppID: "1:123456:web:windows-app",
    allowedAppCheckAppIDs: ["1:123456:web:linux-app", "1:123456:web:windows-app"],
    standardWebAppCheckAppIDs: ["1:123456:web:browser-app"],
  },
}));

vi.mock("../config.js", () => ({ getConfig: () => config }));

import { enforceAuthAndAppCheck } from "../auth.js";
import { enforceAppCheckAttestationBindingCallable, enforceLowRiskCloudSyncCallable } from "../appCheckAttestation.js";
import { appCheckTrustClassForAppId } from "../security/appCheckTrust.js";

function requestFor(appId: string, uid = "user-a"): CallableRequest {
  return {
    app: { appId },
    auth: { uid, token: {} },
    data: {},
    rawRequest: { headers: {} },
    acceptsStreaming: false,
  } as unknown as CallableRequest;
}

describe("lower-trust desktop callable authorization", () => {
  it("keeps the generic handler guard limited to auth, presence, and ownership", () => {
    expect(() => enforceAuthAndAppCheck(requestFor(config.linuxAppCheckAppID), "user-a")).not.toThrow();
    expect(() => enforceAuthAndAppCheck(requestFor(config.windowsAppCheckAppID), "user-a")).not.toThrow();
  });

  it("keeps standard Apple, Android, and Web App Check traffic compatible", () => {
    expect(() => enforceAuthAndAppCheck(requestFor("1:123456:ios:apple-app"), "user-a")).not.toThrow();
    expect(() => enforceAuthAndAppCheck(requestFor("1:123456:android:android-app"), "user-a")).not.toThrow();
    expect(() => enforceAuthAndAppCheck(requestFor("1:123456:web:browser-app"), "user-a")).not.toThrow();
  });

  it("admits Linux only on the explicit low-risk sync guard", () => {
    expect(enforceLowRiskCloudSyncCallable(requestFor(config.linuxAppCheckAppID), "user-a")).toMatchObject({
      trustClass: "linux_lower_trust",
    });
    expect(() => enforceLowRiskCloudSyncCallable(requestFor(config.windowsAppCheckAppID), "user-a")).toThrow(
      /not allowed for low-risk cloud sync/u,
    );
  });

  it("admits both lower-trust desktop IDs only for attestation binding bootstrap", () => {
    expect(enforceAppCheckAttestationBindingCallable(requestFor(config.linuxAppCheckAppID), "user-a")).toMatchObject({
      trustClass: "linux_lower_trust",
    });
    expect(enforceAppCheckAttestationBindingCallable(requestFor(config.windowsAppCheckAppID), "user-a")).toMatchObject({
      trustClass: "windows_lower_trust",
    });
  });

  it("preserves ownership enforcement on every explicit exception", () => {
    expect(() =>
      enforceAppCheckAttestationBindingCallable(requestFor(config.linuxAppCheckAppID, "user-b"), "user-a"),
    ).toThrow(/does not own namespace/u);
    expect(() => enforceLowRiskCloudSyncCallable(requestFor(config.linuxAppCheckAppID, "user-b"), "user-a")).toThrow(
      /does not own namespace/u,
    );
  });

  it("fails closed instead of throwing when an isolated config mock omits app-id arrays", () => {
    const partialConfig = {
      linuxAppCheckAppID: config.linuxAppCheckAppID,
      windowsAppCheckAppID: config.windowsAppCheckAppID,
    } as Parameters<typeof appCheckTrustClassForAppId>[1];

    expect(appCheckTrustClassForAppId(config.linuxAppCheckAppID, partialConfig)).toBe("retired_desktop");
    expect(appCheckTrustClassForAppId("test-app", partialConfig)).toBe("unknown");
  });
});

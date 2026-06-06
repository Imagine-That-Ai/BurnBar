import { describe, it, expect } from "vitest";

import { __testing__ } from "../callables/signalActivationReadiness.js";

const { computeSignalActivationReadiness } = __testing__;

const validIdentity = { algorithm: "signal-hpke-identity-seal-v1", publicKeyData: "cHVibGljLWtleQ==" };

describe("computeSignalActivationReadiness", () => {
  it("is ready only when every trusted device has a valid published identity", () => {
    const trusted = [
      { deviceId: "mac-1", keyVersion: 1 },
      { deviceId: "iphone-1", keyVersion: 1 },
    ];
    const identities = new Map([
      ["mac-1_1", validIdentity],
      ["iphone-1_1", validIdentity],
    ]);
    const result = computeSignalActivationReadiness(trusted, identities);
    expect(result.ready).toBe(true);
    expect(result.total).toBe(2);
    expect(result.published).toBe(2);
    expect(result.missing).toEqual([]);
  });

  it("is NOT ready and reports the device when one trusted peer never published", () => {
    const trusted = [
      { deviceId: "mac-1", keyVersion: 1 },
      { deviceId: "old-ipad", keyVersion: 1 },
    ];
    const identities = new Map([["mac-1_1", validIdentity]]);
    const result = computeSignalActivationReadiness(trusted, identities);
    expect(result.ready).toBe(false);
    expect(result.published).toBe(1);
    expect(result.missing).toEqual([{ deviceId: "old-ipad", keyVersion: 1, reason: "no-identity" }]);
  });

  it("flags an identity doc on the wrong scheme as invalid (not merely missing)", () => {
    const trusted = [{ deviceId: "mac-1", keyVersion: 1 }];
    const identities = new Map([["mac-1_1", { algorithm: "cloudvault-aesgcm-v2", publicKeyData: "x" }]]);
    const result = computeSignalActivationReadiness(trusted, identities);
    expect(result.ready).toBe(false);
    expect(result.missing[0].reason).toBe("invalid-identity");
  });

  it("flags a trusted device with no keyVersion", () => {
    const result = computeSignalActivationReadiness([{ deviceId: "mac-1", keyVersion: null }], new Map());
    expect(result.ready).toBe(false);
    expect(result.missing[0].reason).toBe("no-keyVersion");
  });

  it("treats a key version mismatch (device v2, identity only at v1) as no-identity", () => {
    const trusted = [{ deviceId: "mac-1", keyVersion: 2 }];
    const identities = new Map([["mac-1_1", validIdentity]]); // only v1 published
    const result = computeSignalActivationReadiness(trusted, identities);
    expect(result.ready).toBe(false);
    expect(result.missing[0]).toEqual({ deviceId: "mac-1", keyVersion: 2, reason: "no-identity" });
  });

  it("is NOT ready with zero trusted devices (nothing to seal to)", () => {
    const result = computeSignalActivationReadiness([], new Map());
    expect(result.ready).toBe(false);
    expect(result.total).toBe(0);
  });

  it("rejects an identity whose publicKeyData is not a non-empty string", () => {
    const trusted = [{ deviceId: "mac-1", keyVersion: 1 }];
    const identities = new Map([["mac-1_1", { algorithm: "signal-hpke-identity-seal-v1", publicKeyData: "" }]]);
    expect(computeSignalActivationReadiness(trusted, identities).missing[0].reason).toBe("invalid-identity");
  });
});

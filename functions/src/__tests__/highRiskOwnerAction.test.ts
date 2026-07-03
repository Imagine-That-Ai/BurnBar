import { describe, expect, it, beforeEach, vi } from "vitest";
import type { CallableRequest } from "firebase-functions/v2/https";

const { enforceHighRiskComputerUseCallableWithNonce, requireTrustedDeviceActionProof } = vi.hoisted(() => ({
  enforceHighRiskComputerUseCallableWithNonce: vi.fn(),
  requireTrustedDeviceActionProof: vi.fn(),
}));

vi.mock("../appCheckAttestation.js", () => ({
  enforceHighRiskComputerUseCallableWithNonce,
}));

vi.mock("../callables/computerUseSecurity.js", () => ({
  requireTrustedDeviceActionProof,
}));

import { enforceHighRiskOwnerAction } from "../callables/highRiskOwnerAction.js";

function inertRawRequest(): CallableRequest["rawRequest"] {
  return Object.create(null);
}

function request(data: Record<string, unknown>) {
  return {
    auth: { uid: "u1", token: Object.create(null), rawToken: "test-id-token" },
    app: { appId: "app-1", token: Object.create(null) },
    rawRequest: inertRawRequest(),
    acceptsStreaming: false,
    data,
  };
}

describe("enforceHighRiskOwnerAction", () => {
  beforeEach(() => {
    enforceHighRiskComputerUseCallableWithNonce.mockReset();
    requireTrustedDeviceActionProof.mockReset();
  });

  it("requires a consumed high-risk nonce even when the staged helper tolerates compatibility mode", async () => {
    enforceHighRiskComputerUseCallableWithNonce.mockResolvedValueOnce({ nonceConsumed: false });

    await expect(
      enforceHighRiskOwnerAction(request({ nonce: "nonce-1", trustedDeviceId: "phone-1", actionProof: {} }), "u1", {
        actionKind: "data_export",
        subjectId: "all",
      }),
    ).rejects.toThrow(/fresh high-risk nonce/);

    expect(requireTrustedDeviceActionProof).not.toHaveBeenCalled();
  });

  it("passes the exact action subject, nonce, and trusted device proof to the verifier", async () => {
    const actionProof = { signature: "proof" };
    const callableRequest = request({
      nonce: "nonce-2",
      sourceDeviceID: "phone-2",
      actionProof,
    });
    enforceHighRiskComputerUseCallableWithNonce.mockResolvedValueOnce({ nonceConsumed: true });
    requireTrustedDeviceActionProof.mockResolvedValueOnce({
      deviceId: "phone-2",
      platform: "iOS",
      signalIdentityKeyId: "identity-1",
    });

    await enforceHighRiskOwnerAction(callableRequest, "u1", {
      actionKind: "provider_account_delete",
      subjectId: "anthropic_default",
    });

    expect(enforceHighRiskComputerUseCallableWithNonce).toHaveBeenCalledWith(callableRequest, "u1", "nonce-2", {
      allowLowerTrustDesktop: true,
    });
    expect(requireTrustedDeviceActionProof).toHaveBeenCalledTimes(1);
    const args = requireTrustedDeviceActionProof.mock.calls[0][0];
    expect(args).toEqual(
      expect.objectContaining({
        uid: "u1",
        deviceId: "phone-2",
        actionKind: "provider_account_delete",
        subjectId: "anthropic_default",
        approve: true,
        nonce: "nonce-2",
        proofRaw: actionProof,
      }),
    );
    expect(args.allowedPlatforms.has("iOS")).toBe(true);
    expect(args.allowedPlatforms.has("Android")).toBe(true);
    expect(args.allowedPlatforms.has("Linux")).toBe(true);
    expect(args.allowedPlatforms.has("Web")).toBe(false);
  });
});

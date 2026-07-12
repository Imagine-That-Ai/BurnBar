import { describe, expect, it, beforeEach, vi } from "vitest";
import type { CallableRequest } from "firebase-functions/v2/https";

const { enforceHighRiskComputerUseCallableWithNonce, requireTrustedDeviceActionProof, appendAuditEventRequired, auditActorLabel } =
  vi.hoisted(() => ({
    enforceHighRiskComputerUseCallableWithNonce: vi.fn(),
    requireTrustedDeviceActionProof: vi.fn(),
    appendAuditEventRequired: vi.fn(),
    auditActorLabel: vi.fn(),
  }));

vi.mock("../appCheckAttestation.js", () => ({
  enforceHighRiskComputerUseCallableWithNonce,
}));

vi.mock("../callables/computerUseSecurity.js", () => ({
  requireTrustedDeviceActionProof,
}));

vi.mock("../callables/auditLog.js", () => ({
  appendAuditEventRequired,
  auditActorLabel,
  AUDIT_ACTIONS: {
    highRiskOwnerAction: "security.high_risk_owner_action",
  },
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
    appendAuditEventRequired.mockReset();
    auditActorLabel.mockReset();
    auditActorLabel.mockReturnValue("user:linux");
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
    expect(appendAuditEventRequired).not.toHaveBeenCalled();
  });

  it("passes the exact action subject, nonce, and trusted device proof to the verifier, then writes the audit event", async () => {
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
    appendAuditEventRequired.mockResolvedValueOnce({
      seq: 0,
      ts: "2026-07-04T00:00:00.000Z",
      actor: "user:linux",
      action: "security.high_risk_owner_action",
      domain: "provider_account_delete:anthropic_default",
      prevHash: "",
      hash: "a".repeat(64),
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
    expect(auditActorLabel).toHaveBeenCalledWith(callableRequest);
    expect(appendAuditEventRequired).toHaveBeenCalledWith("u1", {
      actor: "user:linux",
      action: "security.high_risk_owner_action",
      domain: "provider_account_delete:anthropic_default",
    });
  });

  it("fails closed when the high-risk audit write cannot be persisted", async () => {
    enforceHighRiskComputerUseCallableWithNonce.mockResolvedValueOnce({ nonceConsumed: true });
    requireTrustedDeviceActionProof.mockResolvedValueOnce({
      deviceId: "phone-3",
      platform: "Linux",
      signalIdentityKeyId: "identity-3",
    });
    appendAuditEventRequired.mockRejectedValueOnce(new Error("audit write unavailable"));

    await expect(
      enforceHighRiskOwnerAction(request({ nonce: "nonce-3", trustedDeviceId: "phone-3", actionProof: {} }), "u1", {
        actionKind: "revoke_all_access",
        subjectId: "all",
      }),
    ).rejects.toThrow(/audit write unavailable/);

    expect(requireTrustedDeviceActionProof).toHaveBeenCalledTimes(1);
    expect(appendAuditEventRequired).toHaveBeenCalledWith("u1", {
      actor: "user:linux",
      action: "security.high_risk_owner_action",
      domain: "revoke_all_access:all",
    });
  });
});

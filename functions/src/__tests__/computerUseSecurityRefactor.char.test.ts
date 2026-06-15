/**
 * Characterization pin for the U6 refactor of `computerUseSecurity.ts`.
 *
 * The two functions being refactored for cyclomatic complexity are the handler
 * closures of `approveEscrowDeviceTrust` and `queueAgentCapabilityGrantRequest`.
 * Their decision logic funnels through the pure, exported (`__testing__`)
 * helpers pinned below — the nearest stable observable surface of those
 * handlers. This test locks the CURRENT return values (and thrown HttpsError
 * code/message for the validating helpers) for representative inputs so the
 * relocation-only refactor cannot drift behavior.
 */

import { describe, expect, it } from "vitest";

import { __testing__ } from "../callables/computerUseSecurity.js";

const {
  queuedAgentGrantRequiresLocalAuthProof,
  queuedAgentGrantRequiresMacApproval,
  queuedAgentGrantDeliveryRequiresMacApproval,
  agentGrantRequestHashHex,
  canonicalAgentGrantRequestJSON,
  evaluateEscrowFingerprintBinding,
  parseTrustedDeviceActionProof,
} = __testing__ as unknown as {
  queuedAgentGrantRequiresLocalAuthProof: (capabilities: string[], trustMode: string) => boolean;
  queuedAgentGrantRequiresMacApproval: (capabilities: string[], trustMode: string) => boolean;
  queuedAgentGrantDeliveryRequiresMacApproval: (
    capabilities: string[],
    trustMode: string,
    deliveryMode: string,
  ) => boolean;
  agentGrantRequestHashHex: (request: Record<string, unknown>) => string;
  canonicalAgentGrantRequestJSON: (request: Record<string, unknown>) => string;
  evaluateEscrowFingerprintBinding: (
    storedFingerprint: unknown,
    publicKeyDataBase64: unknown,
  ) => { ok: boolean; reason: string };
  parseTrustedDeviceActionProof: (raw: unknown) => unknown;
};

// --- approveEscrowDeviceTrust decision surface --------------------------------

describe("evaluateEscrowFingerprintBinding (approveEscrowDeviceTrust gate)", () => {
  it("returns missing_public_key (ok) when no key bytes are on file", () => {
    expect(evaluateEscrowFingerprintBinding("anyFingerprint", undefined)).toEqual({
      ok: true,
      reason: "missing_public_key",
    });
    expect(evaluateEscrowFingerprintBinding("anyFingerprint", "   ")).toEqual({
      ok: true,
      reason: "missing_public_key",
    });
  });

  it("returns invalid_public_key (fail closed) when key bytes are malformed", () => {
    expect(evaluateEscrowFingerprintBinding("anyFingerprint", "not-a-real-key")).toEqual({
      ok: false,
      reason: "invalid_public_key",
    });
  });
});

describe("parseTrustedDeviceActionProof (respondMissionApproval / action-proof gate)", () => {
  it("throws invalid-argument with the documented message when the proof is absent", () => {
    try {
      parseTrustedDeviceActionProof(undefined);
      throw new Error("expected parseTrustedDeviceActionProof to throw");
    } catch (error) {
      expect((error as { code?: string }).code).toBe("invalid-argument");
      expect((error as { message?: string }).message).toBe("actionProof is required.");
    }
  });

  it("throws invalid-argument when the algorithm is unsupported", () => {
    try {
      parseTrustedDeviceActionProof({
        version: 1,
        algorithm: "totally-unsupported",
        deviceSignalIdentityKeyId: "dev_1",
        deviceSignalIdentityPublicKeyFingerprint: "fpr",
        issuedAtMillis: 1,
        signature: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==",
      });
      throw new Error("expected parseTrustedDeviceActionProof to throw");
    } catch (error) {
      expect((error as { code?: string }).code).toBe("invalid-argument");
      expect((error as { message?: string }).message).toBe("actionProof.algorithm is unsupported.");
    }
  });
});

// --- queueAgentCapabilityGrantRequest decision surface ------------------------

describe("grant preset / approval gates (queueAgentCapabilityGrantRequest)", () => {
  it("requires local-auth proof + Mac approval for risky capabilities, not for read-only", () => {
    expect(queuedAgentGrantRequiresLocalAuthProof(["workspace_read"], "manual")).toBe(false);
    expect(queuedAgentGrantRequiresLocalAuthProof(["shell"], "manual")).toBe(true);
    expect(queuedAgentGrantRequiresLocalAuthProof(["workspace_read"], "trusted")).toBe(true);
    expect(queuedAgentGrantRequiresMacApproval(["desktop_browser"], "manual")).toBe(true);
    // deliveryMode must NOT relax the Mac approval gate (F-RR04-004).
    expect(queuedAgentGrantDeliveryRequiresMacApproval(["shell"], "manual", "live")).toBe(true);
    expect(queuedAgentGrantDeliveryRequiresMacApproval(["workspace_read"], "manual", "live")).toBe(false);
  });

  it("produces a stable canonical hash for a representative grant request", () => {
    const request = {
      requestId: "req-1",
      runtime: "claude",
      threadId: "thread-1",
      preset: "workspace",
      capabilities: ["shell", "workspace_read", "workspace_write"],
      trustMode: "manual",
      deliveryMode: "queued",
      requestedAt: 1000,
      expiresAt: 2000,
      grantDurationSeconds: 600,
      sourceDeviceId: "device-1",
      clientIntentId: "intent-1",
      localAuthenticationSatisfied: true,
    };
    const canonical = canonicalAgentGrantRequestJSON(request);
    const hash = agentGrantRequestHashHex(request);
    // Capability ordering inside the canonical form is independent of input order.
    const shuffled = { ...request, capabilities: ["workspace_write", "shell", "workspace_read"] };
    expect(canonicalAgentGrantRequestJSON(shuffled)).toBe(canonical);
    expect(agentGrantRequestHashHex(shuffled)).toBe(hash);
    expect(hash).toMatch(/^[a-f0-9]{64}$/u);
  });
});

import { createHash, generateKeyPairSync, sign } from "node:crypto";

import { describe, expect, it } from "vitest";

import { __testing__ } from "../callables/computerUseSecurity.js";

const {
  canonicalAgentGrantRequestJSON,
  agentGrantRequestHashHex,
  agentGrantAuthoritySignablePayload,
  agentGrantLocalAuthProofSignablePayload,
  verifyAgentGrantLocalAuthProof,
  queuedAgentGrantRequiresLocalAuthProof,
  queuedAgentGrantRequiresMacApproval,
  queuedAgentGrantDeliveryRequiresMacApproval,
  verifyEd25519RawSignature,
} = __testing__;

const canonicalGrant = {
  requestId: "grant-1",
  runtime: "codex",
  threadId: "thread-1",
  preset: "workspace",
  capabilities: ["workspace_write", "shell", "workspace_read"],
  trustMode: "manual",
  deliveryMode: "live_then_queued",
  requestedAt: 789_000_000.25,
  expiresAt: 789_000_300.25,
  grantDurationSeconds: 300,
  sourceDeviceId: "iphone-1",
  clientIntentId: "intent-1",
  localAuthenticationSatisfied: false,
};

describe("agent grant authority validation", () => {
  it("canonicalizes grant requests exactly like the mobile signers", () => {
    const expected =
      '{"capabilities":["shell","workspace_read","workspace_write"],"clientIntentId":"intent-1","deliveryMode":"live_then_queued","expiresAt":789000300.25,"grantDurationSeconds":300,"localAuthenticationSatisfied":false,"preset":"workspace","requestedAt":789000000.25,"requestId":"grant-1","runtime":"codex","sourceDeviceId":"iphone-1","threadId":"thread-1","trustMode":"manual"}';

    expect(canonicalAgentGrantRequestJSON(canonicalGrant)).toBe(expected);
    expect(agentGrantRequestHashHex(canonicalGrant)).toBe(createHash("sha256").update(expected).digest("hex"));
  });

  it("builds the Ed25519 signable payload with Cocoa-reference timestamps converted to Unix milliseconds", () => {
    const payload = agentGrantAuthoritySignablePayload("a".repeat(64), 42, 0);

    expect(payload.subarray(0, 64).toString("utf8")).toBe("a".repeat(64));
    expect(payload.readBigUInt64BE(64)).toBe(42n);
    expect(payload.readBigInt64BE(72)).toBe(978_307_200_000n);
  });

  it("verifies real Ed25519 signatures over the canonical grant authority payload", () => {
    const { publicKey, privateKey } = generateKeyPairSync("ed25519");
    const publicDer = publicKey.export({ type: "spki", format: "der" });
    const rawPublicKey = publicDer.subarray(publicDer.length - 32);
    const intentHash = agentGrantRequestHashHex(canonicalGrant);
    const payload = agentGrantAuthoritySignablePayload(intentHash, 7, 789_000_000.25);
    const signature = sign(null, payload, privateKey).toString("base64");

    expect(verifyEd25519RawSignature(rawPublicKey, payload, signature)).toBe(true);
    expect(verifyEd25519RawSignature(rawPublicKey, Buffer.from("tampered"), signature)).toBe(false);
  });

  it("requires local-auth proof for high-risk capability-derived grants", () => {
    expect(queuedAgentGrantRequiresLocalAuthProof(["workspace_read"], "manual")).toBe(false);
    expect(queuedAgentGrantRequiresLocalAuthProof(["workspace_read", "workspace_write"], "manual")).toBe(true);
    expect(queuedAgentGrantRequiresLocalAuthProof(["workspace_read", "shell"], "manual")).toBe(true);
    expect(queuedAgentGrantRequiresLocalAuthProof(["desktop_screenshot"], "manual")).toBe(true);
    expect(queuedAgentGrantRequiresLocalAuthProof(["desktop_system_input"], "manual")).toBe(true);
    expect(queuedAgentGrantRequiresLocalAuthProof(["shell_unrestricted"], "manual")).toBe(true);
    expect(queuedAgentGrantRequiresLocalAuthProof(["workspace_read"], "trusted")).toBe(true);

    // Back-compat export for older tests/clients; policy now means "local proof".
    expect(queuedAgentGrantRequiresMacApproval(["workspace_read"], "manual")).toBe(false);
    expect(queuedAgentGrantRequiresMacApproval(["workspace_read", "workspace_write"], "manual")).toBe(true);
  });

  it("rejects queued high-risk grants so only live Mac approval can unlock them", () => {
    expect(queuedAgentGrantDeliveryRequiresMacApproval(["workspace_read"], "manual", "queued")).toBe(false);
    expect(queuedAgentGrantDeliveryRequiresMacApproval(["workspace_read"], "manual", "live_then_queued")).toBe(false);
    expect(queuedAgentGrantDeliveryRequiresMacApproval(["shell"], "manual", "live")).toBe(false);
    expect(queuedAgentGrantDeliveryRequiresMacApproval(["shell"], "manual", "queued")).toBe(true);
    expect(queuedAgentGrantDeliveryRequiresMacApproval(["shell"], "manual", "live_then_queued")).toBe(true);
    expect(queuedAgentGrantDeliveryRequiresMacApproval(["workspace_read"], "trusted", "queued")).toBe(true);
  });

  it("verifies a local-auth proof bound to one exact grant intent", () => {
    const { publicKey, privateKey } = generateKeyPairSync("ed25519");
    const publicDer = publicKey.export({ type: "spki", format: "der" });
    const rawPublicKey = publicDer.subarray(publicDer.length - 32);
    const intentHash = agentGrantRequestHashHex({ ...canonicalGrant, localAuthenticationSatisfied: true });
    const proof = {
      proofId: "proof-1",
      deviceId: "iphone-1",
      signedIntentHash: intentHash,
      authenticatedAt: 789_000_000.25,
      expiresAt: 789_000_240.25,
      signatureEd25519: "",
    };
    const payload = agentGrantLocalAuthProofSignablePayload(proof);
    proof.signatureEd25519 = sign(null, payload, privateKey).toString("base64");

    expect(
      verifyAgentGrantLocalAuthProof(proof, {
        sourceDeviceId: "iphone-1",
        observedIntentHashHex: intentHash,
        nowReferenceSeconds: 789_000_010.25,
        authorityPublicKey: rawPublicKey,
      }),
    ).toBe("ok");
    expect(
      verifyAgentGrantLocalAuthProof(proof, {
        sourceDeviceId: "iphone-2",
        observedIntentHashHex: intentHash,
        nowReferenceSeconds: 789_000_010.25,
        authorityPublicKey: rawPublicKey,
      }),
    ).toBe("wrong_device");
    expect(
      verifyAgentGrantLocalAuthProof(proof, {
        sourceDeviceId: "iphone-1",
        observedIntentHashHex: "f".repeat(64),
        nowReferenceSeconds: 789_000_010.25,
        authorityPublicKey: rawPublicKey,
      }),
    ).toBe("wrong_intent");
    expect(
      verifyAgentGrantLocalAuthProof(proof, {
        sourceDeviceId: "iphone-1",
        observedIntentHashHex: intentHash,
        nowReferenceSeconds: 789_000_300.25,
        authorityPublicKey: rawPublicKey,
      }),
    ).toBe("expired");
  });
});

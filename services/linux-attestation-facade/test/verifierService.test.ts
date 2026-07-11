import assert from "node:assert/strict";
import { verify as verifySignature } from "node:crypto";
import { describe, it } from "node:test";
import { canonicalVerdict } from "../src/contracts.js";
import { PublicError } from "../src/errors.js";
import { VerifierService } from "../src/verifierService.js";
import { CryptoSigner, FakeKeylime, fixture, MemoryEnrollments, MemoryObjects, MemoryState, policyStore } from "./helpers.js";

const NOW = 1_700_000_000_000;

function harness(now = NOW) {
  let currentNow = now;
  const data = fixture(now);
  const state = new MemoryState();
  state.records.set(data.record.uploadId, structuredClone(data.record));
  const objects = new MemoryObjects();
  objects.objects.set(data.record.objectName, { bytes: data.bytes, generation: "1" });
  const enrollments = new MemoryEnrollments();
  enrollments.records.push({
    uid: data.challenge.uid,
    deviceId: data.challenge.deviceId,
    agentId: "agent-1",
    akTpmBase64: Buffer.from("ak").toString("base64"),
    ekTpmBase64: Buffer.from("ek").toString("base64"),
    ekCertificateBase64: Buffer.from("certificate").toString("base64"),
    tpmEkPem: "-----BEGIN PUBLIC KEY-----\ntest\n-----END PUBLIC KEY-----\n",
    active: true,
  });
  const keylime = new FakeKeylime();
  const signer = new CryptoSigner();
  const service = new VerifierService(state, objects, enrollments, policyStore, keylime, signer, { nowMillis: () => currentNow }, {
    issuer: "https://attestation.openburnbar.com", audience: "openburnbar-functions", maxEvidenceBytes: 16 * 1024 * 1024,
    verdictTtlMillis: 60_000, verificationLeaseMillis: 15_000, maxClockSkewMillis: 5_000,
  });
  return { ...data, state, objects, enrollments, keylime, signer, service, setNow(value: number) { currentNow = value; } };
}

describe("VerifierService", () => {
  it("signs the Functions-compatible canonical verdict and caches an identical retry", async () => {
    const h = harness();
    const first = await h.service.verify(h.request);
    const second = await h.service.verify(h.request);
    assert.deepEqual(second, first);
    assert.equal(h.keylime.calls, 1);
    assert.equal(h.signer.calls, 1);
    assert.equal(first.verdict.trustClass, "linux_lower_trust");
    assert.equal(first.verdict.challengeHashSha256, (await import("../src/validation.js")).sha256(h.request.challenge.challenge));
    assert.notEqual(first.verdict.challengeHashSha256, (await import("../src/validation.js")).sha256(Buffer.from(h.request.challenge.challenge, "base64url")));
    assert.equal(first.verdict.expiresAtMillis, first.verdict.attestedAtMillis + 60_000);
    assert.equal(verifySignature(null, Buffer.from(canonicalVerdict(first.verdict)), h.signer.publicKey, Buffer.from(first.signatureBase64, "base64")), true);
  });

  it("rejects replay with a different binding", async () => {
    const h = harness();
    await h.service.verify(h.request);
    const changed = structuredClone(h.request);
    changed.challenge.appVersion = "1.0.1";
    await assert.rejects(h.service.verify(changed), (error: unknown) => error instanceof PublicError && error.code === "conflict");
  });

  it("permanently rejects an upload whose stored binding is wrong", async () => {
    const h = harness();
    h.state.records.get("upload-1")!.deviceId = "other-device";
    await assert.rejects(h.service.verify(h.request), (error: unknown) => error instanceof PublicError && error.code === "bad_request");
    assert.equal(h.state.records.get("upload-1")!.status, "rejected");
  });

  it("rejects digest and size mismatches before Keylime", async () => {
    const h = harness();
    h.objects.objects.get(h.record.objectName)!.bytes = Buffer.from("changed");
    await assert.rejects(h.service.verify(h.request), (error: unknown) => error instanceof PublicError && error.code === "bad_request");
    assert.equal(h.keylime.calls, 0);
  });

  it("rejects evidence with the wrong challenge nonce", async () => {
    const h = harness();
    h.request.evidence.quote.qualifyingDataSha256 = "b".repeat(64);
    await assert.rejects(h.service.verify(h.request), (error: unknown) => error instanceof PublicError && error.code === "bad_request");
    assert.equal(h.keylime.calls, 0);
  });

  it("consumes a Keylime-invalid result without forwarding failure detail", async () => {
    const h = harness();
    h.keylime.result = { valid: false, receipt: { privateFailure: "PCR 7 secret mismatch" } };
    await assert.rejects(h.service.verify(h.request), (error: unknown) => error instanceof PublicError && error.publicMessage === "Device attestation was not accepted");
    assert.equal(h.state.records.get("upload-1")!.status, "rejected");
  });

  it("rejects a revoked enrollment before calling Keylime or signing", async () => {
    const h = harness();
    h.enrollments.records[0]!.revokedAtMillis = NOW + 1;
    h.enrollments.records[0]!.revokedReason = "operator_revoke";
    await assert.rejects(h.service.verify(h.request), (error: unknown) =>
      error instanceof PublicError && error.publicMessage === "Device attestation was not accepted");
    assert.equal(h.keylime.calls, 0);
    assert.equal(h.signer.calls, 0);
    assert.equal(h.state.records.get("upload-1")!.status, "rejected");
  });

  it("rechecks revocation after Keylime before signing a verdict", async () => {
    const h = harness();
    h.keylime.onVerify = () => {
      h.enrollments.records[0]!.revokedAtMillis = NOW + 1;
      h.enrollments.records[0]!.revokedReason = "operator_revoke";
    };
    await assert.rejects(h.service.verify(h.request), (error: unknown) =>
      error instanceof PublicError && error.publicMessage === "Device attestation was not accepted");
    assert.equal(h.keylime.calls, 1);
    assert.equal(h.signer.calls, 0);
    assert.equal(h.state.records.get("upload-1")!.status, "rejected");
  });

  it("rechecks enrollment identity after Keylime before signing a verdict", async () => {
    const h = harness();
    h.keylime.onVerify = () => {
      h.enrollments.records[0]!.akTpmBase64 = Buffer.from("replacement-ak").toString("base64");
    };
    await assert.rejects(h.service.verify(h.request), (error: unknown) =>
      error instanceof PublicError && error.publicMessage === "Device attestation was not accepted");
    assert.equal(h.keylime.calls, 1);
    assert.equal(h.signer.calls, 0);
    assert.equal(h.state.records.get("upload-1")!.status, "rejected");
  });

  it("releases the lease after a Keylime timeout and permits the same retry", async () => {
    const h = harness();
    h.keylime.error = new PublicError(503, "dependency_unavailable", "Attestation verifier is temporarily unavailable", true);
    await assert.rejects(h.service.verify(h.request), (error: unknown) => error instanceof PublicError && error.retryable);
    assert.equal(h.state.records.get("upload-1")!.status, "uploaded");
    h.keylime.error = undefined;
    await h.service.verify(h.request);
    assert.equal(h.keylime.calls, 2);
  });

  it("releases the lease after a KMS outage and re-appraises on retry", async () => {
    const h = harness();
    h.signer.error = new Error("KMS private outage detail");
    await assert.rejects(h.service.verify(h.request), (error: unknown) => error instanceof PublicError && error.code === "dependency_unavailable");
    assert.equal(h.state.records.get("upload-1")!.status, "uploaded");
    h.signer.error = undefined;
    await h.service.verify(h.request);
    assert.equal(h.keylime.calls, 2);
  });

  it("rejects expired challenges before claiming evidence", async () => {
    const h = harness();
    h.request.challenge.expiresAtMillis = 1;
    await assert.rejects(h.service.verify(h.request), (error: unknown) => error instanceof PublicError && error.code === "bad_request");
    assert.equal(h.state.records.get("upload-1")!.status, "uploaded");
  });

  it("rechecks expiry after Keylime and never signs an already-expired verdict", async () => {
    const h = harness();
    h.keylime.onVerify = () => h.setNow(h.request.challenge.expiresAtMillis);
    await assert.rejects(h.service.verify(h.request), (error: unknown) => error instanceof PublicError && error.code === "bad_request");
    assert.equal(h.signer.calls, 0);
    assert.equal(h.state.records.get("upload-1")!.status, "rejected");
  });

  it("does not return an expired cached verdict", async () => {
    const h = harness();
    const envelope = await h.service.verify(h.request);
    h.setNow(envelope.verdict.expiresAtMillis);
    await assert.rejects(h.service.verify(h.request), (error: unknown) => error instanceof PublicError && error.code === "conflict");
  });

  it("fences an expired worker from transitioning a reclaimed same-fingerprint lease", async () => {
    const h = harness();
    const first = await h.state.claimVerification("upload-1", "fingerprint", 100, 10);
    assert.equal(first.kind, "acquired");
    const second = await h.state.claimVerification("upload-1", "fingerprint", 111, 10);
    assert.equal(second.kind, "acquired");
    if (first.kind !== "acquired" || second.kind !== "acquired") throw new Error("fixture did not acquire leases");
    const envelope = await harness().service.verify(harness().request);
    await assert.rejects(h.state.completeVerification("upload-1", "fingerprint", first.leaseToken, envelope), (error: unknown) => error instanceof PublicError && error.code === "conflict");
    assert.equal(h.state.records.get("upload-1")?.verificationLeaseToken, second.leaseToken);
  });
});

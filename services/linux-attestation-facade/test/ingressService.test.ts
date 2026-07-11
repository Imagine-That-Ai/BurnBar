import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { PublicError } from "../src/errors.js";
import { IngressService } from "../src/ingressService.js";
import type { RegistrarClient } from "../src/ports.js";
import { sha256 } from "../src/validation.js";
import { deterministicAgentId, deviceIdForAk } from "../src/enrollment.js";
import { ingressTicketCredential, MemoryEnrollments, MemoryObjects, MemoryState, MemoryTickets } from "./helpers.js";

class FakeRegistrar implements RegistrarClient {
  begins = 0;
  activations = 0;
  lastAgentId?: string;
  identity: Awaited<ReturnType<RegistrarClient["getActiveIdentity"]>>;
  pendingIdentity: NonNullable<Awaited<ReturnType<RegistrarClient["getActiveIdentity"]>>> | undefined;
  activationError: Error | undefined = undefined;
  activationResponseError: Error | undefined = undefined;
  activationGate: Promise<void> | undefined = undefined;
  async begin(agentId: string, ekCertificateBase64: string, ekTpmBase64: string, akTpmBase64: string): Promise<{ activationBlob: string }> {
    this.begins += 1;
    this.lastAgentId = agentId;
    this.pendingIdentity = { agentId, ekCertificateBase64, ekTpmBase64, akTpmBase64 };
    return { activationBlob: "blob" };
  }
  async activate(): Promise<void> {
    this.activations += 1;
    await this.activationGate;
    if (this.activationError !== undefined) throw this.activationError;
    this.identity = this.pendingIdentity;
    if (this.activationResponseError !== undefined) throw this.activationResponseError;
  }
  async getActiveIdentity() { return this.identity; }
}

const EK_CERTIFICATE_BASE64 = "MIIDBTCCAe2gAwIBAgIUeBipg/5bqecuA373NlIfjNxA3AAwDQYJKoZIhvcNAQELBQAwEjEQMA4GA1UEAwwHVGVzdCBFSzAeFw0yNjA3MTAyMjUwNTlaFw0zNjA3MDcyMjUwNTlaMBIxEDAOBgNVBAMMB1Rlc3QgRUswggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQC00JX1k5bb1jliJPsfShhAXwNSvLrqA1+MaomKJ5/Fs/cWLAjfaNSqen/UBGlHbHklKMwsK9iOq3fjC0DzBXefYQKY/OFulp6NNJJxEuKQ5BqeKBS6vgPpXsnI6vQJpkh1RdkimfTm2HESF9My/GaZtJ/zmalD2n928synYcoQk1nEVoZfuUyNZSvrFxFEEGzkEfbvTFTZUTQ+TFNcUbMKXlPa+jkfbrFXsqLv+TCgIs7JuNUxVWKWKwJL5EUptm+25KJvNoM2JkqVMkRS0f6BBVeLVYoubAPFxULcbGsBrc3lIC2Ed2HtjtnVrk/Qq9GyFnhawByE+3GjQOuzRPE1AgMBAAGjUzBRMB0GA1UdDgQWBBTZL+WrZf1chDVGaj37NGE1DpZtJzAfBgNVHSMEGDAWgBTZL+WrZf1chDVGaj37NGE1DpZtJzAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQBismoSR3h2E7qYx3MCKCT0jxtNPGz5kkALurLDWBFguKq32AfaXrGIEC8CjVUILWFQn8H9EK2uYAjm9IfGLByfSKcP0l/UiQ0u/NEHBJKWyIyHzUdBeGrr3ek1jtg64IFvdoNgIfFPqvB85rh450VjzHVj3L3Rtr0dzFZw/Lpr1P9CsA2rPOuBcl3SOhSwb8GzvXSaUHXPBXoTk8L6vsEeIjhxcjT/DQy4fsyEolwmgi36fi8uPT5vqSlA6kPp6He3fhk4Igz5mgRRC+gZXw36giO+UGW5v4Ji3FF2Nd95ClpnL9rrtkzOjR+fjwQgIZK/raetpnebukpg6YjonrHO";
const AK_TPM_BASE64 = Buffer.from("ak-tpm2b").toString("base64");
const EK_TPM_BASE64 = Buffer.from("ek-tpm2b").toString("base64");

function harness(now: () => number = () => 1_000) {
  const state = new MemoryState();
  const objects = new MemoryObjects();
  const enrollments = new MemoryEnrollments();
  const tickets = new MemoryTickets(state, enrollments, 121_000);
  const registrar = new FakeRegistrar();
  const service = new IngressService(state, objects, enrollments, tickets, registrar, { maxEvidenceBytes: 1024, uploadMaxAttempts: 3, enrollmentLeaseMillis: 75_000, activationLeaseMillis: 105_000, enrollmentMaxAttempts: 3 }, now);
  return { state, objects, enrollments, tickets, registrar, service };
}

describe("IngressService", () => {
  it("creates a bound upload and returns a generation-pinned receipt", async () => {
    const h = harness();
    const bytes = Buffer.from("evidence");
    const created = await h.service.createUpload("user-1", ingressTicketCredential, {
      appId: "app", deviceId: "device", challengeId: "challenge", releaseDigestSha256: "a".repeat(64), expectedSha256: sha256(bytes), expectedSize: bytes.byteLength,
    });
    assert.deepEqual(created, { uploadId: "upload-1", expiresAtMillis: 121_000 });
    const completed = await h.service.upload("user-1", created.uploadId, bytes);
    assert.deepEqual(completed.receipt, { uploadId: "upload-1", generation: "1", sha256: sha256(bytes), size: bytes.byteLength });
    assert.equal(h.state.records.get("upload-1")!.status, "uploaded");
  });

  it("rejects oversize declarations before creating state", async () => {
    const h = harness();
    await assert.rejects(h.service.createUpload("user-1", ingressTicketCredential, {
      appId: "app", deviceId: "device", challengeId: "challenge", releaseDigestSha256: "a".repeat(64), expectedSha256: "b".repeat(64), expectedSize: 1025,
    }), (error: unknown) => error instanceof PublicError && error.code === "payload_too_large");
    assert.equal(h.state.records.size, 0);
  });

  it("rejects upload ownership violations and byte mismatches", async () => {
    const h = harness();
    const bytes = Buffer.from("evidence");
    await h.service.createUpload("user-1", ingressTicketCredential, { appId: "app", deviceId: "device", challengeId: "challenge", releaseDigestSha256: "a".repeat(64), expectedSha256: sha256(bytes), expectedSize: bytes.byteLength });
    await assert.rejects(h.service.upload("user-2", "upload-1", bytes), (error: unknown) => error instanceof PublicError && error.code === "forbidden");
    await assert.rejects(h.service.upload("user-1", "upload-1", Buffer.from("wrong")), (error: unknown) => error instanceof PublicError && error.code === "bad_request");
    await h.service.upload("user-1", "upload-1", bytes);
  });

  it("recovers an identical generation-pinned receipt after response loss and rejects terminal reuse", async () => {
    const h = harness();
    const bytes = Buffer.from("evidence");
    await h.service.createUpload("user-1", ingressTicketCredential, { appId: "app", deviceId: "device", challengeId: "challenge", releaseDigestSha256: "a".repeat(64), expectedSha256: sha256(bytes), expectedSize: bytes.byteLength });
    const first = await h.service.upload("user-1", "upload-1", bytes);
    assert.deepEqual(await h.service.upload("user-1", "upload-1", bytes), first);
    assert.equal(h.objects.objects.size, 1);
    h.state.records.get("upload-1")!.status = "verifying";
    await assert.rejects(h.service.upload("user-1", "upload-1", bytes), (error: unknown) => error instanceof PublicError && error.code === "conflict");
  });

  it("recovers idempotently when object creation succeeds before state completion fails", async () => {
    class FlakyState extends MemoryState {
      failures = 1;
      override async completeUpload(uploadId: string, generation: string) {
        if (this.failures-- > 0) throw new Error("Firestore outage");
        return super.completeUpload(uploadId, generation);
      }
    }
    const state = new FlakyState();
    const objects = new MemoryObjects();
    const enrollments = new MemoryEnrollments();
    const service = new IngressService(state, objects, enrollments, new MemoryTickets(state, enrollments, 121_000), new FakeRegistrar(), { maxEvidenceBytes: 1024, uploadMaxAttempts: 3, enrollmentLeaseMillis: 75_000, activationLeaseMillis: 105_000, enrollmentMaxAttempts: 3 }, () => 1_000);
    const bytes = Buffer.from("evidence");
    await service.createUpload("user-1", ingressTicketCredential, { appId: "app", deviceId: "device", challengeId: "challenge", releaseDigestSha256: "a".repeat(64), expectedSha256: sha256(bytes), expectedSize: bytes.byteLength });
    await assert.rejects(service.upload("user-1", "upload-1", bytes), (error: unknown) =>
      error instanceof PublicError && error.status === 503 && error.code === "dependency_unavailable" && error.retryable);
    assert.equal(state.records.get("upload-1")?.status, "pending");
    assert.equal((await service.upload("user-1", "upload-1", bytes)).receipt.generation, "1");
    assert.equal(objects.objects.size, 1);
  });

  it("orchestrates registrar enrollment and activates only after proof", async () => {
    const h = harness();
    const deviceId = deviceIdForAk(AK_TPM_BASE64);
    const request = { deviceId, ekCertificateBase64: EK_CERTIFICATE_BASE64, ekTpmBase64: EK_TPM_BASE64, akTpmBase64: AK_TPM_BASE64 };
    assert.deepEqual(await h.service.beginEnrollment("user-1", ingressTicketCredential, request), { activationBlob: "blob" });
    assert.equal(h.enrollments.records[0]?.active, false);
    assert.match(h.enrollments.records[0]?.tpmEkPem ?? "", /^-----BEGIN PUBLIC KEY-----/);
    await h.service.completeEnrollment("user-1", { deviceId, activationProof: "cHJvb2Y=" });
    assert.equal(h.enrollments.records[0]?.active, true);
    assert.equal(h.registrar.begins, 1);
    assert.equal(h.registrar.activations, 1);
    assert.equal(h.registrar.lastAgentId, deterministicAgentId("user-1", deviceId));
    await h.service.completeEnrollment("user-1", { deviceId, activationProof: "cHJvb2Y=" });
    assert.equal(h.registrar.activations, 1);
  });

  it("fences concurrent activation and performs one registrar mutation", async () => {
    const h = harness();
    const deviceId = deviceIdForAk(AK_TPM_BASE64);
    await h.service.beginEnrollment("user-1", ingressTicketCredential, { deviceId, ekCertificateBase64: EK_CERTIFICATE_BASE64, ekTpmBase64: EK_TPM_BASE64, akTpmBase64: AK_TPM_BASE64 });
    let release: (() => void) | undefined;
    h.registrar.activationGate = new Promise<void>(resolve => { release = resolve; });
    const first = h.service.completeEnrollment("user-1", { deviceId, activationProof: "cHJvb2Y=" });
    await new Promise(resolve => setImmediate(resolve));
    await assert.rejects(
      h.service.completeEnrollment("user-1", { deviceId, activationProof: "cHJvb2Y=" }),
      (error: unknown) => error instanceof PublicError && error.code === "conflict" && error.retryable,
    );
    release?.();
    await first;
    assert.equal(h.registrar.activations, 1);
    assert.equal(h.enrollments.records[0]?.active, true);
  });

  it("reconciles registrar response loss and an already-active remote identity", async () => {
    const h = harness();
    const deviceId = deviceIdForAk(AK_TPM_BASE64);
    const request = { deviceId, ekCertificateBase64: EK_CERTIFICATE_BASE64, ekTpmBase64: EK_TPM_BASE64, akTpmBase64: AK_TPM_BASE64 };
    await h.service.beginEnrollment("user-1", ingressTicketCredential, request);
    h.registrar.activationResponseError = new PublicError(503, "dependency_unavailable", "response lost", true);
    await h.service.completeEnrollment("user-1", { deviceId, activationProof: "cHJvb2Y=" });
    assert.equal(h.enrollments.records[0]?.active, true);
    assert.equal(h.registrar.activations, 1);

    const second = harness();
    await second.service.beginEnrollment("user-1", ingressTicketCredential, request);
    second.registrar.identity = second.registrar.pendingIdentity;
    await second.service.completeEnrollment("user-1", { deviceId, activationProof: "cHJvb2Y=" });
    assert.equal(second.registrar.activations, 0);
    assert.equal(second.enrollments.records[0]?.active, true);
  });

  it("rejects a mismatched active registrar identity without activating local state", async () => {
    const h = harness();
    const deviceId = deviceIdForAk(AK_TPM_BASE64);
    await h.service.beginEnrollment("user-1", ingressTicketCredential, { deviceId, ekCertificateBase64: EK_CERTIFICATE_BASE64, ekTpmBase64: EK_TPM_BASE64, akTpmBase64: AK_TPM_BASE64 });
    h.registrar.identity = { ...h.registrar.pendingIdentity!, akTpmBase64: Buffer.from("other-ak").toString("base64") };
    await assert.rejects(
      h.service.completeEnrollment("user-1", { deviceId, activationProof: "cHJvb2Y=" }),
      (error: unknown) => error instanceof PublicError && error.code === "conflict",
    );
    assert.equal(h.enrollments.records.length, 0);
    assert.equal(h.registrar.activations, 0);
  });

  it("reconciles local activation commit response loss", async () => {
    class ResponseLossEnrollments extends MemoryEnrollments {
      override async activate(uid: string, deviceId: string, agentId: string, leaseToken: string): Promise<void> {
        await super.activate(uid, deviceId, agentId, leaseToken);
        throw new Error("Firestore response lost");
      }
    }
    const state = new MemoryState();
    const enrollments = new ResponseLossEnrollments();
    const registrar = new FakeRegistrar();
    const service = new IngressService(
      state,
      new MemoryObjects(),
      enrollments,
      new MemoryTickets(state, enrollments, 121_000),
      registrar,
      { maxEvidenceBytes: 1024, uploadMaxAttempts: 3, enrollmentLeaseMillis: 75_000, activationLeaseMillis: 105_000, enrollmentMaxAttempts: 3 },
      () => 1_000,
    );
    const deviceId = deviceIdForAk(AK_TPM_BASE64);
    await service.beginEnrollment("user-1", ingressTicketCredential, { deviceId, ekCertificateBase64: EK_CERTIFICATE_BASE64, ekTpmBase64: EK_TPM_BASE64, akTpmBase64: AK_TPM_BASE64 });
    await service.completeEnrollment("user-1", { deviceId, activationProof: "cHJvb2Y=" });
    assert.equal(enrollments.records[0]?.active, true);
  });

  it("idempotently returns one pending enrollment and never overwrites active identity", async () => {
    const h = harness();
    const deviceId = deviceIdForAk(AK_TPM_BASE64);
    const request = { deviceId, ekCertificateBase64: EK_CERTIFICATE_BASE64, ekTpmBase64: EK_TPM_BASE64, akTpmBase64: AK_TPM_BASE64 };
    const first = await h.service.beginEnrollment("user-1", ingressTicketCredential, request);
    const second = await h.service.beginEnrollment("user-1", ingressTicketCredential, request);
    assert.deepEqual(second, first);
    assert.equal(h.registrar.begins, 1);
    await h.service.completeEnrollment("user-1", { deviceId, activationProof: "cHJvb2Y=" });
    await assert.rejects(h.service.beginEnrollment("user-1", ingressTicketCredential, request), (error: unknown) => error instanceof PublicError && error.code === "conflict");
    assert.equal(h.registrar.begins, 1);
  });

  it("fences concurrent registration and reclaims a crashed reservation after expiry", async () => {
    const store = new MemoryEnrollments();
    const deviceId = deviceIdForAk(AK_TPM_BASE64);
    const record = {
      uid: "user-1", deviceId, agentId: "00000000-0000-8000-8000-000000000000", akTpmBase64: AK_TPM_BASE64,
      ekTpmBase64: EK_TPM_BASE64, ekCertificateBase64: EK_CERTIFICATE_BASE64, tpmEkPem: "pem", active: false,
    };
    const first = await store.claimRegistration(record, 100, 10);
    assert.equal(first.kind, "acquired");
    assert.deepEqual(await store.claimRegistration(record, 105, 10), { kind: "busy" });
    const reclaimed = await store.claimRegistration(record, 111, 10);
    assert.equal(reclaimed.kind, "acquired");
    if (first.kind !== "acquired" || reclaimed.kind !== "acquired") throw new Error("fixture did not acquire reservation");
    await assert.rejects(store.completeRegistration("user-1", deviceId, first.leaseToken, "stale"), PublicError);
    assert.equal((await store.completeRegistration("user-1", deviceId, reclaimed.leaseToken, "current")).activationBlob, "current");
  });

  it("does not reclaim registration while the Keylime dependency timeout is still running", async () => {
    let now = 1_000;
    let resolveBegin: ((value: { activationBlob: string }) => void) | undefined;
    const registrar: RegistrarClient = {
      begin: async () => new Promise(resolve => { resolveBegin = resolve; }),
      async activate() {},
      async getActiveIdentity() { return undefined; },
    };
    const store = new MemoryEnrollments();
    const state = new MemoryState();
    const service = new IngressService(
      state,
      new MemoryObjects(),
      store,
      new MemoryTickets(state, store),
      registrar,
      { maxEvidenceBytes: 1024, uploadMaxAttempts: 3, enrollmentLeaseMillis: 75_000, activationLeaseMillis: 105_000, enrollmentMaxAttempts: 3 },
      () => now,
    );
    const deviceId = deviceIdForAk(AK_TPM_BASE64);
    const request = { deviceId, ekCertificateBase64: EK_CERTIFICATE_BASE64, ekTpmBase64: EK_TPM_BASE64, akTpmBase64: AK_TPM_BASE64 };
    const first = service.beginEnrollment("user-1", ingressTicketCredential, request);
    await new Promise(resolve => setImmediate(resolve));
    now += 45_000;
    await assert.rejects(service.beginEnrollment("user-1", ingressTicketCredential, request), (error: unknown) =>
      error instanceof PublicError && error.code === "conflict" && error.retryable);
    resolveBegin?.({ activationBlob: "blob" });
    assert.deepEqual(await first, { activationBlob: "blob" });
  });

  it("maps malformed or oversized Keylime responses to a retryable dependency error", async () => {
    const h = harness();
    const deviceId = deviceIdForAk(AK_TPM_BASE64);
    h.registrar.begin = async () => { throw new Error("Invalid Keylime JSON"); };
    await assert.rejects(h.service.beginEnrollment("user-1", ingressTicketCredential, {
      deviceId, ekCertificateBase64: EK_CERTIFICATE_BASE64, ekTpmBase64: EK_TPM_BASE64, akTpmBase64: AK_TPM_BASE64,
    }), (error: unknown) => error instanceof PublicError
      && error.status === 503
      && error.code === "dependency_unavailable"
      && error.retryable
      && !error.publicMessage.includes("Keylime"));
  });

  it("keeps a pending enrollment retryable after invalid activation proof", async () => {
    const h = harness();
    const deviceId = deviceIdForAk(AK_TPM_BASE64);
    await h.service.beginEnrollment("user-1", ingressTicketCredential, { deviceId, ekCertificateBase64: EK_CERTIFICATE_BASE64, ekTpmBase64: EK_TPM_BASE64, akTpmBase64: AK_TPM_BASE64 });
    h.registrar.activationError = new PublicError(400, "bad_request", "Keylime rejected the enrollment request");
    await assert.rejects(h.service.completeEnrollment("user-1", { deviceId, activationProof: "YmFk" }), PublicError);
    assert.equal(h.enrollments.records.length, 0);
    h.registrar.activationError = undefined;
    await h.service.beginEnrollment("user-1", ingressTicketCredential, { deviceId, ekCertificateBase64: EK_CERTIFICATE_BASE64, ekTpmBase64: EK_TPM_BASE64, akTpmBase64: AK_TPM_BASE64 });
    await h.service.completeEnrollment("user-1", { deviceId, activationProof: "Z29vZA==" });
    assert.equal(h.enrollments.records[0]?.active, true);
  });

  it("retains the activation fence after an ambiguous registrar mutation until lease expiry", async () => {
    let now = 1_000;
    const h = harness(() => now);
    const deviceId = deviceIdForAk(AK_TPM_BASE64);
    await h.service.beginEnrollment("user-1", ingressTicketCredential, { deviceId, ekCertificateBase64: EK_CERTIFICATE_BASE64, ekTpmBase64: EK_TPM_BASE64, akTpmBase64: AK_TPM_BASE64 });
    h.registrar.activationError = new PublicError(503, "dependency_unavailable", "Registrar unavailable", true);
    await assert.rejects(h.service.completeEnrollment("user-1", { deviceId, activationProof: "cHJvb2Y=" }), (error: unknown) => error instanceof PublicError && error.retryable);
    assert.equal(h.enrollments.records[0]?.activationBlob, "blob");
    assert.equal(h.registrar.activations, 1);
    await assert.rejects(
      h.service.completeEnrollment("user-1", { deviceId, activationProof: "cHJvb2Y=" }),
      (error: unknown) => error instanceof PublicError && error.code === "conflict" && error.retryable,
    );
    assert.equal(h.registrar.activations, 1);
    now += 105_001;
    h.registrar.activationError = undefined;
    await h.service.completeEnrollment("user-1", { deviceId, activationProof: "cHJvb2Y=" });
    assert.equal(h.registrar.activations, 2);
    assert.equal(h.enrollments.records[0]?.active, true);
  });

  it("retains the activation fence when post-mutation reconciliation fails nonretryably", async () => {
    const h = harness();
    const deviceId = deviceIdForAk(AK_TPM_BASE64);
    await h.service.beginEnrollment("user-1", ingressTicketCredential, { deviceId, ekCertificateBase64: EK_CERTIFICATE_BASE64, ekTpmBase64: EK_TPM_BASE64, akTpmBase64: AK_TPM_BASE64 });
    h.registrar.activationError = new PublicError(503, "dependency_unavailable", "Registrar mutation outcome is unknown", true);
    let identityReads = 0;
    h.registrar.getActiveIdentity = async () => {
      identityReads += 1;
      if (identityReads === 1) return undefined;
      throw new PublicError(400, "bad_request", "Registrar reconciliation failed");
    };

    await assert.rejects(
      h.service.completeEnrollment("user-1", { deviceId, activationProof: "cHJvb2Y=" }),
      (error: unknown) => error instanceof PublicError && error.status === 400,
    );
    await assert.rejects(
      h.service.completeEnrollment("user-1", { deviceId, activationProof: "cHJvb2Y=" }),
      (error: unknown) => error instanceof PublicError && error.code === "conflict" && error.retryable,
    );
    assert.equal(h.registrar.activations, 1);
  });

  it("rejects client device or pending identity changes before registrar mutation", async () => {
    const h = harness();
    await assert.rejects(h.service.beginEnrollment("user-1", ingressTicketCredential, { deviceId: "device", ekCertificateBase64: EK_CERTIFICATE_BASE64, ekTpmBase64: EK_TPM_BASE64, akTpmBase64: AK_TPM_BASE64 }), PublicError);
    assert.equal(h.registrar.begins, 0);
    const deviceId = deviceIdForAk(AK_TPM_BASE64);
    await h.service.beginEnrollment("user-1", ingressTicketCredential, { deviceId, ekCertificateBase64: EK_CERTIFICATE_BASE64, ekTpmBase64: EK_TPM_BASE64, akTpmBase64: AK_TPM_BASE64 });
    await assert.rejects(h.service.beginEnrollment("user-1", ingressTicketCredential, { deviceId, ekCertificateBase64: Buffer.from("not-a-cert").toString("base64"), ekTpmBase64: EK_TPM_BASE64, akTpmBase64: AK_TPM_BASE64 }), PublicError);
    assert.equal(h.registrar.begins, 1);
  });
});

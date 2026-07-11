import assert from "node:assert/strict";
import type { AddressInfo } from "node:net";
import type { Server } from "node:http";
import { afterEach, describe, it } from "node:test";
import { createIngressServer } from "../src/ingressServer.js";
import { IngressService } from "../src/ingressService.js";
import type { RegistrarClient, ServiceAuthenticator, UserAuthenticator } from "../src/ports.js";
import { createVerifierServer } from "../src/verifierServer.js";
import type { VerifierService } from "../src/verifierService.js";
import { PublicError } from "../src/errors.js";
import { fixture, ingressTicketCredential, MemoryEnrollments, MemoryObjects, MemoryState, MemoryTickets } from "./helpers.js";

const servers: Server[] = [];
afterEach(async () => Promise.all(servers.splice(0).map(server => new Promise<void>(resolve => server.close(() => resolve())))));

async function start(server: Server): Promise<string> {
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  servers.push(server);
  return `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
}

const userAuth: UserAuthenticator = {
  async authenticate(token) {
    if (token !== "valid-user-token") throw new PublicError(401, "unauthorized", "Authentication is required");
    return { uid: "user-1" };
  },
};

const registrar: RegistrarClient = {
  async begin() { return { activationBlob: "blob" }; },
  async activate() {},
  async getActiveIdentity() { return undefined; },
};
const ticketHeader = `obbat1_${ingressTicketCredential.ticketId}.${ingressTicketCredential.secret.toString("base64url")}`;

function ingressService(state = new MemoryState(), objects = new MemoryObjects()): IngressService {
  const enrollments = new MemoryEnrollments();
  return new IngressService(
    state,
    objects,
    enrollments,
    new MemoryTickets(state, enrollments, Date.now() + 300_000),
    registrar,
    { maxEvidenceBytes: 32, uploadMaxAttempts: 3, enrollmentLeaseMillis: 75_000, activationLeaseMillis: 105_000, enrollmentMaxAttempts: 3 },
  );
}

describe("HTTP boundaries", () => {
  it("requires a Firebase bearer token before public request parsing", async () => {
    const service = ingressService();
    const base = await start(createIngressServer(service, userAuth, { jsonBodyLimit: 256, evidenceBodyLimit: 32 }));
    const response = await fetch(`${base}/v1/evidence-uploads`, { method: "POST", headers: { "content-type": "application/json" }, body: "not json" });
    assert.equal(response.status, 401);
    assert.deepEqual(await response.json(), { error: { code: "unauthorized", message: "Authentication is required", retryable: false } });
    const missingTicket = await fetch(`${base}/v1/evidence-uploads`, {
      method: "POST",
      headers: { authorization: "Bearer valid-user-token", "content-type": "application/json" },
      body: "not json",
    });
    assert.equal(missingTicket.status, 403);
    assert.deepEqual(await missingTicket.json(), { error: { code: "forbidden", message: "Attestation ticket is not authorized", retryable: false } });
  });

  it("rejects unknown public JSON fields and bodies that exceed their upload declaration", async () => {
    const service = ingressService();
    const base = await start(createIngressServer(service, userAuth, { jsonBodyLimit: 256, evidenceBodyLimit: 32 }));
    const response = await fetch(`${base}/v1/evidence-uploads`, {
      method: "POST", headers: { authorization: "Bearer valid-user-token", "content-type": "application/json", "x-openburnbar-attestation-ticket": ticketHeader },
      body: JSON.stringify({ protocolVersion: 1, attestationKind: "tpm2_ima_signed_verdict_v1", extra: true }),
    });
    assert.equal(response.status, 400);
    await service.createUpload("user-1", ingressTicketCredential, {
      appId: "app", deviceId: "device", challengeId: "challenge", releaseDigestSha256: "a".repeat(64), expectedSha256: "b".repeat(64), expectedSize: 32,
    });
    const oversized = await fetch(`${base}/v1/evidence-uploads/upload-1`, { method: "PUT", headers: { authorization: "Bearer valid-user-token" }, body: Buffer.alloc(33) });
    assert.equal(oversized.status, 400);
  });

  it("charges malformed evidence bodies before reading them and caps total PUT attempts", async () => {
    const state = new MemoryState();
    const service = ingressService(state);
    const bytes = Buffer.from("evidence");
    await service.createUpload("user-1", ingressTicketCredential, {
      appId: "app", deviceId: "device", challengeId: "challenge", releaseDigestSha256: "a".repeat(64), expectedSha256: "ee8250fb76e094b34b471f13a73dbbe51d1ae142e9df59d7c0d31ec20f0a0a8e", expectedSize: bytes.byteLength,
    });
    const base = await start(createIngressServer(service, userAuth, { jsonBodyLimit: 256, evidenceBodyLimit: 32 }));
    for (const body of [Buffer.alloc(7), Buffer.alloc(9), Buffer.alloc(8)]) {
      const response = await fetch(`${base}/v1/evidence-uploads/upload-1`, { method: "PUT", headers: { authorization: "Bearer valid-user-token" }, body });
      assert.equal(response.status, 400);
    }
    const exhausted = await fetch(`${base}/v1/evidence-uploads/upload-1`, { method: "PUT", headers: { authorization: "Bearer valid-user-token" }, body: bytes });
    assert.equal(exhausted.status, 429);
    assert.equal(state.records.get("upload-1")?.uploadAttemptCount, 3);
  });

  it("bounds successful response-loss retries to the same three PUT attempts", async () => {
    const service = ingressService();
    const bytes = Buffer.from("evidence");
    await service.createUpload("user-1", ingressTicketCredential, {
      appId: "app", deviceId: "device", challengeId: "challenge", releaseDigestSha256: "a".repeat(64), expectedSha256: "ee8250fb76e094b34b471f13a73dbbe51d1ae142e9df59d7c0d31ec20f0a0a8e", expectedSize: bytes.byteLength,
    });
    const base = await start(createIngressServer(service, userAuth, { jsonBodyLimit: 256, evidenceBodyLimit: 32 }));
    for (let attempt = 0; attempt < 3; attempt += 1) {
      const response = await fetch(`${base}/v1/evidence-uploads/upload-1`, { method: "PUT", headers: { authorization: "Bearer valid-user-token" }, body: bytes });
      assert.equal(response.status, 200);
    }
    const exhausted = await fetch(`${base}/v1/evidence-uploads/upload-1`, { method: "PUT", headers: { authorization: "Bearer valid-user-token" }, body: bytes });
    assert.equal(exhausted.status, 429);
  });

  it("returns retryable sanitized errors for Firestore and GCS outages", async () => {
    class UnavailableState extends MemoryState {
      override async create(): Promise<void> { throw new Error("Firestore credentials leaked here"); }
    }
    const createService = ingressService(new UnavailableState());
    const createBase = await start(createIngressServer(createService, userAuth, { jsonBodyLimit: 512, evidenceBodyLimit: 32 }));
    const createResponse = await fetch(`${createBase}/v1/evidence-uploads`, {
      method: "POST",
      headers: { authorization: "Bearer valid-user-token", "content-type": "application/json", "x-openburnbar-attestation-ticket": ticketHeader },
      body: JSON.stringify({
        protocolVersion: 1,
        attestationKind: "tpm2_ima_signed_verdict_v1",
        appId: "app",
        deviceId: "device",
        challengeId: "challenge",
        releaseDigestSha256: "a".repeat(64),
        expectedSha256: "b".repeat(64),
        expectedSize: 8,
      }),
    });
    assert.equal(createResponse.status, 503);
    assert.deepEqual(await createResponse.json(), { error: { code: "dependency_unavailable", message: "Attestation service is temporarily unavailable", retryable: true } });

    class UnavailableObjects extends MemoryObjects {
      override async create(): Promise<string> { throw new Error("GCS credentials leaked here"); }
    }
    const state = new MemoryState();
    const enrollments = new MemoryEnrollments();
    const uploadService = new IngressService(state, new UnavailableObjects(), enrollments, new MemoryTickets(state, enrollments, 301_000), registrar, { maxEvidenceBytes: 32, uploadMaxAttempts: 3, enrollmentLeaseMillis: 75_000, activationLeaseMillis: 105_000, enrollmentMaxAttempts: 3 }, () => 1_000);
    await uploadService.createUpload("user-1", ingressTicketCredential, { appId: "app", deviceId: "device", challengeId: "challenge", releaseDigestSha256: "a".repeat(64), expectedSha256: "ee8250fb76e094b34b471f13a73dbbe51d1ae142e9df59d7c0d31ec20f0a0a8e", expectedSize: 8 });
    const uploadBase = await start(createIngressServer(uploadService, userAuth, { jsonBodyLimit: 512, evidenceBodyLimit: 32 }));
    const uploadResponse = await fetch(`${uploadBase}/v1/evidence-uploads/upload-1`, { method: "PUT", headers: { authorization: "Bearer valid-user-token" }, body: "evidence" });
    assert.equal(uploadResponse.status, 503);
    assert.deepEqual(await uploadResponse.json(), { error: { code: "dependency_unavailable", message: "Attestation service is temporarily unavailable", retryable: true } });
  });

  it("requires private service authentication and never forwards verifier detail", async () => {
    const service = { async verify() { throw new PublicError(403, "verification_failed", "Device attestation was not accepted"); } } as unknown as VerifierService;
    const auth: ServiceAuthenticator = { async authenticate(token) { if (token !== "valid-service-token") throw new PublicError(401, "unauthorized", "Authentication is required"); } };
    const base = await start(createVerifierServer(service, auth, 512 * 1024));
    const unauthorized = await fetch(`${base}/v1/verify`, { method: "POST", headers: { "content-type": "application/json" }, body: "{}" });
    assert.equal(unauthorized.status, 401);
    const rejected = await fetch(`${base}/v1/verify`, { method: "POST", headers: { authorization: "Bearer valid-service-token", "content-type": "application/json" }, body: JSON.stringify(fixture().request) });
    assert.equal(rejected.status, 403);
    assert.deepEqual(await rejected.json(), { error: { code: "verification_failed", message: "Device attestation was not accepted", retryable: false } });
  });
});

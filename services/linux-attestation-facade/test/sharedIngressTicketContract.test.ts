import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, it } from "node:test";
import { Ajv2020 } from "ajv/dist/2020.js";

import {
  ingressTicketClaimFingerprint,
  ingressTicketSecretHash,
  parseIngressTicket,
} from "../src/ingressTicket.js";

const repo = (path: string): string => fileURLToPath(new URL(`../../../${path}`, import.meta.url));
const schema = JSON.parse(
  readFileSync(repo("schemas/linux-attestation-ingress-ticket-v1.schema.json"), "utf8"),
) as object;
const golden = JSON.parse(
  readFileSync(repo("tests/fixtures/linux-attestation/ingress-ticket-v1-golden.json"), "utf8"),
) as {
  upload: {
    ticketWire: string;
    issueRequest: Record<string, unknown>;
    issueResponse: Record<string, unknown>;
    ticketRecord: Record<string, string | number>;
  };
  enrollment: {
    ticketWire: string;
    issueRequest: Record<string, unknown>;
    issueResponse: Record<string, unknown>;
    ticketRecord: Record<string, string | number>;
  };
};

const validate = new Ajv2020({ allErrors: true, strict: true }).compile(schema);

function assertSchema(value: unknown): void {
  assert.equal(validate(value), true, JSON.stringify(validate.errors));
}

describe("shared ingress ticket contract", () => {
  it("accepts the exact Functions issue requests, callable responses, and immutable Firestore records", () => {
    assertSchema(golden.upload.issueRequest);
    assertSchema(golden.upload.issueResponse);
    assertSchema(golden.upload.ticketRecord);
    assertSchema(golden.enrollment.issueRequest);
    assertSchema(golden.enrollment.issueResponse);
    assertSchema(golden.enrollment.ticketRecord);
    assert.deepEqual(golden.upload.issueResponse, {
      ok: true,
      ticketId: golden.upload.ticketRecord.ticketId,
      expiresAtMillis: golden.upload.ticketRecord.expiresAtMillis,
    });
    assert.deepEqual(golden.enrollment.issueResponse, {
      ok: true,
      ticketId: golden.enrollment.ticketRecord.ticketId,
      expiresAtMillis: golden.enrollment.ticketRecord.expiresAtMillis,
    });
  });

  it("recomputes the golden upload secret hash and claim fingerprint exactly", () => {
    const credential = parseIngressTicket(golden.upload.ticketWire);
    const record = golden.upload.ticketRecord;
    assert.equal(credential.ticketId, record.ticketId);
    assert.equal(ingressTicketSecretHash(credential.secret), record.ticketSecretHashSha256);
    assert.equal(ingressTicketClaimFingerprint("evidence_upload", [
      String(record.protocolVersion),
      String(record.attestationKind),
      String(record.uid),
      String(record.appId),
      String(record.deviceId),
      String(record.challengeId),
      String(record.challengeHashSha256),
      String(record.releaseDigestSha256),
      String(record.expectedSha256),
      String(record.expectedSize),
    ]), record.claimFingerprintSha256);
  });

  it("recomputes the challenge-free enrollment claim fingerprint exactly", () => {
    const credential = parseIngressTicket(golden.enrollment.ticketWire);
    const record = golden.enrollment.ticketRecord;
    assert.equal(ingressTicketSecretHash(credential.secret), record.ticketSecretHashSha256);
    assert.equal(ingressTicketClaimFingerprint("enrollment_begin", [
      String(record.protocolVersion),
      String(record.attestationKind),
      String(record.uid),
      String(record.deviceId),
      String(record.akTpmSha256),
      String(record.ekTpmSha256),
      String(record.ekCertificateSha256),
    ]), record.claimFingerprintSha256);
    assert.equal(Object.hasOwn(record, "challengeId"), false);
  });

  it("binds the stored upload challenge hash to the raw challenge nonce", () => {
    const request = golden.upload.issueRequest;
    assert.equal(
      createHash("sha256").update(String(request.challenge), "utf8").digest("hex"),
      golden.upload.ticketRecord.challengeHashSha256,
    );
  });
});

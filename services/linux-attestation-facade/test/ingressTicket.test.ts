import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  ingressTicketClaimFingerprint,
  ingressTicketSecretHash,
  enrollmentMaterialHashes,
  parseIngressTicket,
  ticketHashesEqual,
} from "../src/ingressTicket.js";
import { PublicError } from "../src/errors.js";

const ticketId = Buffer.alloc(16, 7).toString("base64url");
const secret = Buffer.alloc(32, 9);
const wireTicket = `obbat1_${ticketId}.${secret.toString("base64url")}`;

describe("ingress ticket wire contract", () => {
  it("accepts only the exact canonical 16-byte id and 32-byte secret", () => {
    assert.deepEqual(parseIngressTicket(wireTicket), { ticketId, secret });
    for (const malformed of [
      wireTicket.replace("obbat1_", "obbat2_"),
      `${wireTicket}=`,
      `${wireTicket}.extra`,
      `obbat1_${Buffer.alloc(15).toString("base64url")}.${secret.toString("base64url")}`,
      `obbat1_${ticketId}.${Buffer.alloc(31).toString("base64url")}`,
      [wireTicket],
      undefined,
    ]) {
      assert.throws(() => parseIngressTicket(malformed), (error: unknown) =>
        error instanceof PublicError && error.status === 403 && error.code === "forbidden");
    }
  });

  it("uses domain-separated secret hashes and constant-time equality", () => {
    const digest = ingressTicketSecretHash(secret);
    assert.match(digest, /^[a-f0-9]{64}$/u);
    assert.equal(ticketHashesEqual(digest, digest), true);
    assert.equal(ticketHashesEqual(digest, "0".repeat(64)), false);
    assert.equal(ticketHashesEqual(digest, "invalid"), false);
  });

  it("binds claim fingerprints to purpose, order, and every field", () => {
    const upload = ingressTicketClaimFingerprint("evidence_upload", ["uid", "device", "challenge", "digest", "8"]);
    assert.notEqual(upload, ingressTicketClaimFingerprint("enrollment_begin", ["uid", "device", "challenge", "digest", "8"]));
    assert.notEqual(upload, ingressTicketClaimFingerprint("evidence_upload", ["uid", "device", "challenge", "8", "digest"]));
    assert.notEqual(upload, ingressTicketClaimFingerprint("evidence_upload", ["uid", "device", "challenge", "digest", "9"]));
  });

  it("hashes decoded enrollment material rather than its base64 spelling", () => {
    const material = Buffer.from("tpm-material");
    const expected = "e68e27091d415fc15375c0dfac0ee6215e25d30651d2617d10629d2c8e4e5ed2";
    const hashes = enrollmentMaterialHashes({
      akTpmBase64: material.toString("base64"),
      ekTpmBase64: material.toString("base64"),
      ekCertificateBase64: material.toString("base64"),
    });
    assert.deepEqual(hashes, { akTpmSha256: expected, ekTpmSha256: expected, ekCertificateSha256: expected });
  });
});

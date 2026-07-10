import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { parseVerifyRequest, quoteQualifyingDataSha256 } from "../src/contracts.js";
import { PublicError } from "../src/errors.js";
import { fixture } from "./helpers.js";

describe("strict verifier contract", () => {
  it("accepts the exact protocol contract", () => assert.deepEqual(parseVerifyRequest(fixture().request), fixture().request));
  it("rejects additional properties at every boundary", () => {
    const request = fixture().request as unknown as Record<string, unknown>;
    request.extra = true;
    assert.throws(() => parseVerifyRequest(request), (error: unknown) => error instanceof PublicError && error.code === "bad_request");
  });
  it("rejects uppercase digests instead of normalizing them", () => {
    const request = fixture().request;
    request.evidence.upload.sha256 = request.evidence.upload.sha256.toUpperCase();
    assert.throws(() => parseVerifyRequest(request), (error: unknown) => error instanceof PublicError && error.code === "bad_request");
  });
  it("accepts canonical unpadded base64url challenges and rejects standard base64 padding", () => {
    const request = fixture().request;
    assert.match(request.challenge.challenge, /[_-]/);
    assert.doesNotThrow(() => parseVerifyRequest(request));
    request.challenge.challenge = "YQ==";
    assert.throws(() => parseVerifyRequest(request), PublicError);
  });
  it("restricts architecture to the two packaged targets", () => {
    const request = fixture().request;
    request.challenge.architecture = "amd64";
    assert.throws(() => parseVerifyRequest(request), PublicError);
  });
  it("derives quote qualifying data from the exact nine-field NUL-delimited contract", async () => {
    const challenge = fixture().challenge;
    const fields = [
      Buffer.from("openburnbar.linux.tpm-quote.v1"), Buffer.from(challenge.challenge, "base64url"), Buffer.from(challenge.appId),
      Buffer.from(challenge.deviceId), Buffer.from(challenge.appVersion), Buffer.from(challenge.architecture), Buffer.from(challenge.releaseDigestSha256),
      Buffer.from(challenge.policyId), Buffer.from(challenge.attestationKind),
    ];
    const expected = Buffer.concat(fields.flatMap((field, index) => index === fields.length - 1 ? [field] : [field, Buffer.from([0])]));
    assert.equal(quoteQualifyingDataSha256(challenge), (await import("../src/validation.js")).sha256(expected));
    assert.notEqual(expected.at(-1), 0);
  });
  it("mirrors Packet A broker labels and quote PCR fields", () => {
    const request = fixture().request;
    request.challenge.challengeId = `${"a".repeat(156)}+/=`;
    request.challenge.policyId = "policy:+/=";
    request.challenge.deviceId = "device:+/=";
    request.evidence.quote.deviceId = "device:+/=";
    assert.equal(parseVerifyRequest(request).evidence.quote.quotePcrValuesBase64, request.evidence.quote.quotePcrValuesBase64);
    request.challenge.challengeId = "a".repeat(161);
    assert.throws(() => parseVerifyRequest(request), PublicError);
  });

  it("rejects noncanonical and broker-oversized standard base64 quote fields", () => {
    const noncanonical = fixture().request;
    noncanonical.evidence.quote.quotePcrValuesBase64 = "AB==";
    assert.throws(() => parseVerifyRequest(noncanonical), PublicError);

    const oversized = fixture().request;
    oversized.evidence.quote.quotePcrValuesBase64 = Buffer.alloc(12_289).toString("base64");
    assert.ok(oversized.evidence.quote.quotePcrValuesBase64.length > 16_384);
    assert.throws(() => parseVerifyRequest(oversized), PublicError);
  });
});

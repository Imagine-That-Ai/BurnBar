import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, it } from "node:test";
import { Ajv2020 } from "ajv/dist/2020.js";

import { parseVerifyRequest, quoteQualifyingDataSha256 } from "../src/contracts.js";
import { fixture } from "./helpers.js";

const repo = (path: string): string => fileURLToPath(new URL(`../../../${path}`, import.meta.url));
const golden = JSON.parse(readFileSync(repo("tests/fixtures/linux-attestation/broker-v2-golden.json"), "utf8")) as {
  attestRequest: { challenge: Record<string, unknown>; binding: Record<string, unknown> };
  attestResponse: { attestation: { evidence: Record<string, unknown>; evidenceBundle: Record<string, unknown> } };
};
const headerSchema = JSON.parse(
  readFileSync(repo("schemas/linux-attestation-evidence-bundle-header-v1.schema.json"), "utf8"),
) as object;

describe("shared Packet A contract", () => {
  it("accepts the exact broker golden challenge, binding, quote, and bundle metadata", () => {
    const challenge = {
      uid: "user-1",
      ...golden.attestRequest.binding,
      ...golden.attestRequest.challenge,
    };
    const evidenceBundle = golden.attestResponse.attestation.evidenceBundle;
    const request = parseVerifyRequest({
      challenge,
      evidence: {
        schemaVersion: 1,
        quote: golden.attestResponse.attestation.evidence,
        evidenceBundle,
        upload: {
          uploadId: "upload-1",
          generation: "1",
          sha256: evidenceBundle.sha256,
          size: evidenceBundle.byteLength,
        },
      },
    });

    assert.equal(
      quoteQualifyingDataSha256(request.challenge),
      golden.attestResponse.attestation.evidence.qualifyingDataSha256,
    );
    assert.deepEqual(request.evidence.quote, golden.attestResponse.attestation.evidence);
    assert.deepEqual(request.evidence.evidenceBundle, evidenceBundle);
  });

  it("emits a bundle header accepted by the shared Draft 2020-12 schema", () => {
    const bytes = fixture().bytes;
    const headerLength = bytes.readUInt32BE(8);
    const header = JSON.parse(bytes.subarray(12, 12 + headerLength).toString("utf8")) as unknown;
    const validate = new Ajv2020({ allErrors: true, strict: true }).compile(headerSchema);
    assert.equal(validate(header), true, JSON.stringify(validate.errors));
  });
});

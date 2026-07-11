import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, it } from "node:test";
import { Ajv2020 } from "ajv/dist/2020.js";

import { parseEvidenceReceipt, parseVerifyRequest } from "../src/contracts.js";
import { parseCreateUpload } from "../src/requestParsers.js";
import { fixture } from "./helpers.js";

const MAX_EVIDENCE_BYTES = 16 * 1024 * 1024;
const repo = (path: string): string =>
  fileURLToPath(new URL(`../../../${path}`, import.meta.url));
const schema = JSON.parse(
  readFileSync(
    repo("schemas/linux-attestation-client-bridge-v1.schema.json"),
    "utf8",
  ),
) as object;

interface Golden {
  uploadTicketCallableRequest: { data: Record<string, unknown> };
  uploadTicketCallableResponse: { result: Record<string, unknown> };
  ingressCreateRequest: Record<string, unknown>;
  ingressCreateResponse: Record<string, unknown>;
  uploadReceiptResponse: { receipt: Record<string, unknown> };
  mintCallableRequest: {
    data: {
      attestation: {
        challengeId: string;
        challenge: string;
        kind: string;
        evidence: {
          schemaVersion: number;
          quote: Record<string, unknown>;
          evidenceBundle: Record<string, unknown>;
          upload: Record<string, unknown>;
        };
      };
    };
  };
}

const golden = JSON.parse(
  readFileSync(
    repo("tests/fixtures/linux-attestation/client-bridge-v1-golden.json"),
    "utf8",
  ),
) as Golden;
const validate = new Ajv2020({ allErrors: true, strict: true }).compile(schema);

function assertSchema(value: unknown): void {
  assert.equal(validate(value), true, JSON.stringify(validate.errors));
}

function assertNotSchema(value: unknown): void {
  assert.equal(
    validate(value),
    false,
    "unexpectedly accepted a non-contract object",
  );
}

describe("shared Linux attestation client bridge contract", () => {
  it("accepts every exact client-visible wire boundary", () => {
    assertSchema(golden.uploadTicketCallableRequest);
    assertSchema(golden.uploadTicketCallableResponse);
    assertSchema(golden.ingressCreateRequest);
    assertSchema(golden.ingressCreateResponse);
    assertSchema(golden.uploadReceiptResponse);
    assertSchema(golden.mintCallableRequest);
  });

  it("matches the facade ingress and verifier parsers", () => {
    const create = parseCreateUpload(golden.ingressCreateRequest);
    assert.deepEqual(create, {
      appId: golden.ingressCreateRequest.appId,
      deviceId: golden.ingressCreateRequest.deviceId,
      challengeId: golden.ingressCreateRequest.challengeId,
      releaseDigestSha256: golden.ingressCreateRequest.releaseDigestSha256,
      expectedSha256: golden.ingressCreateRequest.expectedSha256,
      expectedSize: golden.ingressCreateRequest.expectedSize,
    });
    assert.deepEqual(
      parseEvidenceReceipt(golden.uploadReceiptResponse.receipt),
      golden.uploadReceiptResponse.receipt,
    );

    const parsed = parseVerifyRequest({
      challenge: fixture().challenge,
      evidence: golden.mintCallableRequest.data.attestation.evidence,
    });
    assert.deepEqual(
      parsed.evidence,
      golden.mintCallableRequest.data.attestation.evidence,
    );
  });

  it("keeps ticket, reservation, receipt, and mint evidence on one immutable upload binding", () => {
    const ticket = golden.uploadTicketCallableRequest.data;
    const create = golden.ingressCreateRequest;
    const reservation = golden.ingressCreateResponse;
    const receipt = golden.uploadReceiptResponse.receipt;
    const attestation = golden.mintCallableRequest.data.attestation;
    const bundle = attestation.evidence.evidenceBundle;

    assert.equal(ticket.challengeId, create.challengeId);
    assert.equal(ticket.challengeId, attestation.challengeId);
    assert.equal(ticket.challenge, attestation.challenge);
    assert.equal(ticket.expectedSha256, create.expectedSha256);
    assert.equal(ticket.expectedSha256, receipt.sha256);
    assert.equal(ticket.expectedSha256, bundle.sha256);
    assert.equal(ticket.expectedSize, create.expectedSize);
    assert.equal(ticket.expectedSize, receipt.size);
    assert.equal(ticket.expectedSize, bundle.byteLength);
    assert.equal(reservation.uploadId, receipt.uploadId);
    assert.equal(reservation.uploadId, attestation.evidence.upload.uploadId);
  });

  it("rejects unknown fields at every bridge boundary", () => {
    const values: unknown[] = [];

    const ticketRequest = structuredClone(golden.uploadTicketCallableRequest);
    Object.assign(ticketRequest.data, { unknown: true });
    values.push(ticketRequest);

    const ticketResponse = structuredClone(golden.uploadTicketCallableResponse);
    Object.assign(ticketResponse.result, { unknown: true });
    values.push(ticketResponse);

    values.push({ ...golden.ingressCreateRequest, unknown: true });
    values.push({ ...golden.ingressCreateResponse, unknown: true });

    const receipt = structuredClone(golden.uploadReceiptResponse);
    Object.assign(receipt.receipt, { unknown: true });
    values.push(receipt);

    const mint = structuredClone(golden.mintCallableRequest);
    Object.assign(mint.data.attestation.evidence.quote, { unknown: true });
    values.push(mint);

    for (const value of values) assertNotSchema(value);
  });

  it("accepts exactly 16 MiB and rejects every larger evidence declaration", () => {
    const fields = [
      [golden.uploadTicketCallableRequest, ["data", "expectedSize"]],
      [golden.ingressCreateRequest, ["expectedSize"]],
      [golden.uploadReceiptResponse, ["receipt", "size"]],
      [
        golden.mintCallableRequest,
        ["data", "attestation", "evidence", "evidenceBundle", "byteLength"],
      ],
      [
        golden.mintCallableRequest,
        ["data", "attestation", "evidence", "upload", "size"],
      ],
    ] as const;

    for (const [source, path] of fields) {
      const maximum = structuredClone(source) as Record<string, unknown>;
      let target = maximum;
      for (const key of path.slice(0, -1))
        target = target[key] as Record<string, unknown>;
      const leaf = path.at(-1);
      assert.ok(leaf !== undefined);
      target[leaf] = MAX_EVIDENCE_BYTES;
      assertSchema(maximum);
      target[leaf] = MAX_EVIDENCE_BYTES + 1;
      assertNotSchema(maximum);
    }
  });
});

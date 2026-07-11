import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import test from 'node:test';
import Ajv2020 from 'ajv/dist/2020.js';

const brokerSchema = JSON.parse(fs.readFileSync('schemas/linux-attestation-broker-v2.schema.json', 'utf8'));
const headerSchema = JSON.parse(fs.readFileSync('schemas/linux-attestation-evidence-bundle-header-v1.schema.json', 'utf8'));
const golden = JSON.parse(fs.readFileSync('tests/fixtures/linux-attestation/broker-v2-golden.json', 'utf8'));
const ajv = new Ajv2020({ allErrors: true, strict: true });
const validateBroker = ajv.compile(brokerSchema);
const validateHeader = ajv.compile(headerSchema);
const maximumEvidenceBytes = 16 * 1024 * 1024;

function clone(value) {
  return structuredClone(value);
}

function assertInvalid(validate, value, label) {
  assert.equal(validate(value), false, label);
  assert.notEqual(validate.errors, null, label);
}

test('every broker golden message satisfies the Draft 2020-12 wire schema', () => {
  for (const key of [
    'describeBindingRequest',
    'describeBindingResponse',
    'attestRequest',
    'attestResponse',
    'unsupportedResponse'
  ]) {
    assert.equal(validateBroker(golden[key]), true, `${key}: ${ajv.errorsText(validateBroker.errors)}`);
  }
});

test('broker schema rejects unknown fields, noncanonical challenge, and PCR drift', () => {
  const extra = clone(golden.describeBindingRequest);
  extra.unexpected = true;
  assertInvalid(validateBroker, extra, 'unknown request field');

  const padded = clone(golden.attestRequest);
  padded.challenge.challenge += '=';
  assertInvalid(validateBroker, padded, 'padded challenge');

  const noncanonicalChallenge = clone(golden.attestRequest);
  noncanonicalChallenge.challenge.challenge = `${noncanonicalChallenge.challenge.challenge.slice(0, -1)}B`;
  assert.equal(noncanonicalChallenge.challenge.challenge.length, 43);
  assertInvalid(validateBroker, noncanonicalChallenge, 'nonzero base64url pad bits');

  const unsafeExpiry = clone(golden.attestRequest);
  unsafeExpiry.challenge.expiresAtMillis = Number.MAX_SAFE_INTEGER + 1;
  assertInvalid(validateBroker, unsafeExpiry, 'unsafe integer expiry');

  const pcrDrift = clone(golden.attestResponse);
  pcrDrift.attestation.evidence.pcrSelection = [0, 2, 4, 7];
  assertInvalid(validateBroker, pcrDrift, 'PCR selection drift');

  const missingPcrBlob = clone(golden.attestResponse);
  delete missingPcrBlob.attestation.evidence.quotePcrValuesBase64;
  assertInvalid(validateBroker, missingPcrBlob, 'missing quote PCR values');

  for (const invalidBase64 of ['A', 'AA', 'AAA', 'AAAA=', 'A===']) {
    const malformedQuote = clone(golden.attestResponse);
    malformedQuote.attestation.evidence.quotePcrValuesBase64 = invalidBase64;
    assertInvalid(validateBroker, malformedQuote, `invalid standard base64: ${invalidBase64}`);
  }

  const descriptorDrift = clone(golden.attestResponse);
  descriptorDrift.attestation.evidenceBundle.descriptorIndex = 1;
  assertInvalid(validateBroker, descriptorDrift, 'descriptor index drift');
});

test('broker and ingress evidence limits accept exactly 16 MiB and reject one byte over', () => {
  const boundary = clone(golden.attestResponse);
  boundary.attestation.evidenceBundle.byteLength = maximumEvidenceBytes;
  assert.equal(validateBroker(boundary), true, ajv.errorsText(validateBroker.errors));

  const oversized = clone(boundary);
  oversized.attestation.evidenceBundle.byteLength = maximumEvidenceBytes + 1;
  assertInvalid(validateBroker, oversized, 'broker evidence bundle exceeds 16 MiB');

  assert.equal(
    brokerSchema.$defs.evidenceBundle.properties.byteLength.maximum,
    maximumEvidenceBytes,
    'broker schema evidence limit drifted'
  );
  assert.equal(
    headerSchema.$defs.recordBase.properties.byteLength.maximum,
    maximumEvidenceBytes,
    'bundle header record limit drifted'
  );
  assert.equal(
    headerSchema.$defs.recordBase.properties.offset.maximum,
    maximumEvidenceBytes - 1,
    'bundle header offset limit drifted'
  );

  const ticketSource = fs.readFileSync('functions/src/security/linuxAttestationIngressTickets.ts', 'utf8');
  assert.match(
    ticketSource,
    /LINUX_ATTESTATION_MAX_EVIDENCE_BYTES\s*=\s*16\s*\*\s*1024\s*\*\s*1024/u,
    'Functions upload-ticket evidence limit drifted'
  );
  const facadeConfig = fs.readFileSync('services/linux-attestation-facade/src/config.ts', 'utf8');
  assert.match(
    facadeConfig,
    /evidenceMaxBytes:\s*positive\(\s*"EVIDENCE_MAX_BYTES",\s*16\s*\*\s*1024\s*\*\s*1024,\s*16\s*\*\s*1024\s*\*\s*1024,\s*\)/u,
    'public ingress evidence limit drifted'
  );
  assert.match(
    facadeConfig,
    /evidenceMaxBytes\s*>\s*16\s*\*\s*1024\s*\*\s*1024/u,
    'verifier hard evidence limit drifted'
  );
});

test('golden quote blobs are canonical standard base64 with zero pad bits', () => {
  const evidence = golden.attestResponse.attestation.evidence;
  for (const field of [
    'quoteAttestationBase64',
    'quoteSignatureBase64',
    'quotePcrValuesBase64'
  ]) {
    const encoded = evidence[field];
    assert.equal(Buffer.from(encoded, 'base64').toString('base64'), encoded, field);
  }

  const noncanonicalPadBits = clone(golden.attestResponse);
  noncanonicalPadBits.attestation.evidence.quotePcrValuesBase64 = 'AB==';
  assertInvalid(validateBroker, noncanonicalPadBits, 'nonzero standard-base64 pad bits');
});

test('evidence header schema fixes record order, bounds, hashes, and exact keys', () => {
  const valid = {
    records: [
      { byteLength: 3, kind: 'ima_ascii_runtime_measurements', offset: 256, sha256: '1'.repeat(64) },
      { byteLength: 4, kind: 'uefi_binary_bios_measurements', offset: 259, sha256: '2'.repeat(64) },
      { byteLength: 5, kind: 'installed_manifest', offset: 263, sha256: '3'.repeat(64) },
      { byteLength: 64, kind: 'installed_manifest_signature', offset: 268, sha256: '4'.repeat(64) }
    ],
    schemaVersion: 1
  };
  assert.equal(validateHeader(valid), true, ajv.errorsText(validateHeader.errors));

  const boundaryLength = clone(valid);
  boundaryLength.records[0].byteLength = maximumEvidenceBytes;
  assert.equal(validateHeader(boundaryLength), true, ajv.errorsText(validateHeader.errors));
  const oversizedLength = clone(boundaryLength);
  oversizedLength.records[0].byteLength = maximumEvidenceBytes + 1;
  assertInvalid(validateHeader, oversizedLength, 'record byte length exceeds 16 MiB');

  const boundaryOffset = clone(valid);
  boundaryOffset.records[0].offset = maximumEvidenceBytes - 1;
  assert.equal(validateHeader(boundaryOffset), true, ajv.errorsText(validateHeader.errors));
  const oversizedOffset = clone(boundaryOffset);
  oversizedOffset.records[0].offset = maximumEvidenceBytes;
  assertInvalid(validateHeader, oversizedOffset, 'record offset reaches 16 MiB');

  for (const [label, mutate] of [
    ['unknown field', value => { value.records[0].unexpected = true; }],
    ['record order', value => { value.records[0].kind = 'uefi_binary_bios_measurements'; }],
    ['zero length', value => { value.records[1].byteLength = 0; }],
    ['uppercase digest', value => { value.records[2].sha256 = 'A'.repeat(64); }],
    ['extra record', value => { value.records.push(clone(value.records[3])); }]
  ]) {
    const changed = clone(valid);
    mutate(changed);
    assertInvalid(validateHeader, changed, label);
  }
});

test('golden quote qualifying data binds the decoded challenge and authoritative release identity', () => {
  const { challenge, binding } = golden.attestRequest;
  const challengeBytes = Buffer.from(challenge.challenge, 'base64url');
  assert.equal(challengeBytes.byteLength, 32);
  assert.equal(challengeBytes.toString('base64url'), challenge.challenge);
  const fields = [
    Buffer.from('openburnbar.linux.tpm-quote.v1', 'utf8'),
    challengeBytes,
    ...[
      binding.appId,
      binding.deviceId,
      binding.appVersion,
      binding.architecture,
      binding.releaseDigestSha256,
      binding.policyId,
      binding.attestationKind
    ].map(value => Buffer.from(value, 'utf8'))
  ];
  const separated = Buffer.concat(fields.flatMap((value, index) => index === 0 ? [value] : [Buffer.from([0]), value]));
  const digest = crypto.createHash('sha256').update(separated).digest('hex');
  assert.equal(digest, golden.attestResponse.attestation.evidence.qualifyingDataSha256);
});

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

// SPDX-License-Identifier: AGPL-3.0-only
//
// Real end-to-end tests for the @openburnbar/libsignal-protocol facade, exercised
// against the actual @signalapp/libsignal-client native library (no mocks).
//
// Coverage:
//   (1) full Alice<->Bob X3DH+PQXDH establishment + send/receive BOTH directions
//   (2) out-of-order / skipped message keys still decrypt
//   (3) replay of a consumed ciphertext is REJECTED
//   (4) safety-number derivation matches between the two parties
//   (5) at-rest seal -> open round-trips (structured v4 SignalBinding)
//   (6) at-rest open FAILS CLOSED when info/associatedData (binding) is tampered
//   (7) at-rest seal/open FAIL CLOSED when a binding segment injects '|'/CR/LF

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  ProtocolAddress,
  generateIdentity,
  generatePreKeys,
  buildPreKeyBundle,
  createInMemoryStores,
  establishSession,
  encrypt,
  decrypt,
  safetyNumber,
  atRestSeal,
  atRestOpen,
  PrivateKey,
  CiphertextMessageType,
  type GeneratedIdentity,
  type SessionStores,
  type SignalBinding,
} from './index.js';

const enc = new TextEncoder();
const dec = new TextDecoder();

// A valid structured at-rest (cloudvault) binding for the seal/open tests. The
// at-rest seal/open path now derives BOTH the HPKE info and the AEAD associated
// data from `bindingToAAD(binding)`, so this object is the v4 context that pins
// the ciphertext to a specific uid/collection/doc/field.
function atRestBinding(overrides: Partial<SignalBinding> = {}): SignalBinding {
  return {
    uid: 'uid-1',
    scope: 'cloudvault',
    collection: 'pensieve_notes',
    docId: 'abc-123',
    field: 'body',
    mode: 'at-rest',
    formatVersion: 1,
    ...overrides,
  };
}

interface Party {
  identity: GeneratedIdentity;
  stores: SessionStores;
  address: ProtocolAddress;
}

function makeParty(name: string, deviceId = 1): Party {
  const identity = generateIdentity();
  const stores = createInMemoryStores(identity);
  const address = ProtocolAddress.new(name, deviceId);
  return { identity, stores, address };
}

/**
 * Spin up Alice + Bob, publish Bob's prekeys, and have Alice establish a session
 * toward Bob. Returns both parties (and Bob's prekey ids for assertions).
 */
async function establishAliceToBob(): Promise<{
  alice: Party;
  bob: Party;
  bobKyberPreKeyId: number;
}> {
  const alice = makeParty('alice-aci', 1);
  const bob = makeParty('bob-aci', 1);

  const bobIds = { preKeyId: 31337, signedPreKeyId: 22, kyberPreKeyId: 7 };
  const bobPreKeys = await generatePreKeys(bob.identity, bob.stores, bobIds);
  const bobBundle = buildPreKeyBundle(bob.identity, bob.address.deviceId(), bobPreKeys);

  // Alice processes Bob's bundle (X3DH + PQXDH).
  await establishSession(bob.address, bobBundle, alice.stores);

  return { alice, bob, bobKyberPreKeyId: bobIds.kyberPreKeyId };
}

test('(1) full X3DH+PQXDH establishment and bidirectional round-trip', async () => {
  const { alice, bob, bobKyberPreKeyId } = await establishAliceToBob();

  // Alice -> Bob (first message is a PreKey message).
  const m1 = enc.encode('hello bob, this is alice');
  const c1 = await encrypt(m1, bob.address, alice.address, alice.stores);
  assert.equal(
    c1.type,
    CiphertextMessageType.PreKey,
    'first message from initiator must be a PreKey message',
  );

  const p1 = await decrypt(c1, alice.address, bob.address, bob.stores);
  assert.equal(dec.decode(p1), 'hello bob, this is alice');

  // Decrypting the PreKey message must have consumed Bob's Kyber prekey.
  assert.equal(
    bob.stores.kyberPreKeyStore.wasUsed(bobKyberPreKeyId),
    true,
    'Kyber (PQXDH) prekey should be marked used after PreKey decrypt',
  );

  // Bob -> Alice (reply; now both sides have a session, type is Whisper).
  const m2 = enc.encode('hi alice, bob here');
  const c2 = await encrypt(m2, alice.address, bob.address, bob.stores);
  assert.equal(c2.type, CiphertextMessageType.Whisper);

  const p2 = await decrypt(c2, bob.address, alice.address, alice.stores);
  assert.equal(dec.decode(p2), 'hi alice, bob here');

  // Another Alice -> Bob, now steady-state Whisper.
  const m3 = enc.encode('great, ratchet is turning');
  const c3 = await encrypt(m3, bob.address, alice.address, alice.stores);
  assert.equal(c3.type, CiphertextMessageType.Whisper);
  const p3 = await decrypt(c3, alice.address, bob.address, bob.stores);
  assert.equal(dec.decode(p3), 'great, ratchet is turning');
});

test('(2) out-of-order / skipped message keys still decrypt', async () => {
  const { alice, bob } = await establishAliceToBob();

  // Prime the session both directions so we are in steady-state Whisper.
  const primer = await encrypt(enc.encode('primer'), bob.address, alice.address, alice.stores);
  await decrypt(primer, alice.address, bob.address, bob.stores);

  // Alice encrypts three messages in order, but Bob receives them out of order.
  const cA = await encrypt(enc.encode('A'), bob.address, alice.address, alice.stores);
  const cB = await encrypt(enc.encode('B'), bob.address, alice.address, alice.stores);
  const cC = await encrypt(enc.encode('C'), bob.address, alice.address, alice.stores);

  // Bob decrypts C first (skips A and B), then A, then B.
  const pC = await decrypt(cC, alice.address, bob.address, bob.stores);
  assert.equal(dec.decode(pC), 'C');

  const pA = await decrypt(cA, alice.address, bob.address, bob.stores);
  assert.equal(dec.decode(pA), 'A', 'skipped message key A must still decrypt');

  const pB = await decrypt(cB, alice.address, bob.address, bob.stores);
  assert.equal(dec.decode(pB), 'B', 'skipped message key B must still decrypt');
});

test('(3) replay of a consumed ciphertext is rejected', async () => {
  const { alice, bob } = await establishAliceToBob();

  // The initiator keeps sending PreKey messages until the recipient replies.
  // First exercise replay rejection on a consumed PreKey message...
  const cPre = await encrypt(enc.encode('prekey msg'), bob.address, alice.address, alice.stores);
  assert.equal(cPre.type, CiphertextMessageType.PreKey);
  const pPre = await decrypt(cPre, alice.address, bob.address, bob.stores);
  assert.equal(dec.decode(pPre), 'prekey msg');
  await assert.rejects(
    () => decrypt(cPre, alice.address, bob.address, bob.stores),
    /duplicate|already|message with old counter|invalid/i,
    'replay of a consumed PreKey ciphertext must be rejected',
  );

  // ...now have Bob reply so Alice's ratchet advances to steady-state Whisper.
  const reply = await encrypt(enc.encode('bob reply'), alice.address, bob.address, bob.stores);
  await decrypt(reply, bob.address, alice.address, alice.stores);

  const c = await encrypt(enc.encode('once only'), bob.address, alice.address, alice.stores);
  assert.equal(
    c.type,
    CiphertextMessageType.Whisper,
    'after the recipient replies, the initiator sends steady-state Whisper messages',
  );

  // First decrypt succeeds and consumes the message key.
  const p = await decrypt(c, alice.address, bob.address, bob.stores);
  assert.equal(dec.decode(p), 'once only');

  // Replaying the exact same Whisper ciphertext must be rejected (consumed
  // message key). libsignal surfaces this as a thrown error.
  await assert.rejects(
    () => decrypt(c, alice.address, bob.address, bob.stores),
    /duplicate|already|message with old counter|invalid/i,
    'replay of a consumed Whisper ciphertext must be rejected',
  );
});

test('(4) safety number matches between the two parties', async () => {
  const alice = makeParty('alice-aci', 1);
  const bob = makeParty('bob-aci', 1);

  const aliceId = 'alice-aci';
  const bobId = 'bob-aci';

  // Each party computes from THEIR perspective (local first, remote second).
  const aliceView = safetyNumber(
    aliceId,
    alice.identity.identityKeyPair.publicKey,
    bobId,
    bob.identity.identityKeyPair.publicKey,
  );
  const bobView = safetyNumber(
    bobId,
    bob.identity.identityKeyPair.publicKey,
    aliceId,
    alice.identity.identityKeyPair.publicKey,
  );

  assert.equal(aliceView, bobView, 'both parties must derive the same safety number');
  assert.match(aliceView, /^\d+$/, 'displayable fingerprint is a numeric string');
  // Signal displayable safety numbers are 60 digits.
  assert.equal(aliceView.length, 60, 'safety number must be 60 digits');

  // A different remote key must produce a DIFFERENT safety number.
  const mallory = makeParty('mallory-aci', 1);
  const aliceWithMallory = safetyNumber(
    aliceId,
    alice.identity.identityKeyPair.publicKey,
    bobId,
    mallory.identity.identityKeyPair.publicKey,
  );
  assert.notEqual(
    aliceView,
    aliceWithMallory,
    'a substituted identity key must change the safety number',
  );
});

test('(5) at-rest seal -> open round-trips', async () => {
  const recipient = PrivateKey.generate();
  const recipientPub = recipient.getPublicKey();

  const plaintext = enc.encode('secret at-rest payload \u{1F510}');
  const binding = atRestBinding();

  const sealed = atRestSeal(plaintext, recipientPub, binding);
  assert.ok(sealed.byteLength > plaintext.byteLength, 'ciphertext should be larger than plaintext');
  assert.notDeepEqual(
    Array.from(sealed.subarray(0, plaintext.byteLength)),
    Array.from(plaintext),
    'ciphertext must not start with the plaintext',
  );

  const opened = atRestOpen(sealed, recipient, binding);
  assert.equal(dec.decode(opened), 'secret at-rest payload \u{1F510}');
});

test('(6) at-rest open fails closed when the binding is tampered', async () => {
  const recipient = PrivateKey.generate();
  const recipientPub = recipient.getPublicKey();

  const plaintext = enc.encode('do not leak me');
  const binding = atRestBinding();
  const sealed = atRestSeal(plaintext, recipientPub, binding);

  // Wrong binding (changes BOTH info and associatedData via bindingToAAD) must
  // fail closed — here a single field (docId) differs.
  await assert.rejects(
    async () => atRestOpen(sealed, recipient, atRestBinding({ docId: 'WRONG' })),
    'opening with a different binding must throw',
  );

  // A different optional position (field) also re-canonicalizes and fails closed.
  await assert.rejects(
    async () => atRestOpen(sealed, recipient, atRestBinding({ field: 'title' })),
    'opening with a different binding field must throw',
  );

  // Tampered ciphertext (flip a byte) must also fail closed.
  const corrupted = Uint8Array.from(sealed);
  const lastIndex = corrupted.length - 1;
  corrupted[lastIndex] = corrupted[lastIndex]! ^ 0xff;
  await assert.rejects(
    async () => atRestOpen(corrupted, recipient, binding),
    'opening tampered ciphertext must throw',
  );

  // Wrong recipient private key must fail closed.
  const wrongKey = PrivateKey.generate();
  await assert.rejects(
    async () => atRestOpen(sealed, wrongKey, binding),
    'opening with the wrong private key must throw',
  );

  // Sanity: the correct binding + key still opens (so failures above are real).
  const opened = atRestOpen(sealed, recipient, binding);
  assert.equal(dec.decode(opened), 'do not leak me');
});

test('(7) at-rest seal/open fail closed on a pipe/CRLF-injected binding segment', () => {
  const recipient = PrivateKey.generate();
  const recipientPub = recipient.getPublicKey();
  const plaintext = enc.encode('never sealed');

  // bindingToAAD throws before any HPKE seal/open happens, so a binding that
  // could otherwise smuggle an extra AAD segment is rejected outright.
  assert.throws(
    () => atRestSeal(plaintext, recipientPub, atRestBinding({ docId: 'a|b' })),
    /reserved '\|' or CR\/LF/,
    'seal must reject a pipe-injected binding segment',
  );
  assert.throws(
    () => atRestOpen(new Uint8Array([0, 1, 2]), recipient, atRestBinding({ field: 'x\ny' })),
    /reserved '\|' or CR\/LF/,
    'open must reject a CRLF-injected binding segment before touching the AEAD',
  );
});

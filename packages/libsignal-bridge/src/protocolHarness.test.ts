import assert from "node:assert/strict";
import test from "node:test";

import * as Signal from "@signalapp/libsignal-client";

import {
  decryptWhisper,
  encryptWhisper,
  establishLibsignalSession,
  makeHarnessDevice,
  publishPreKeyBundle,
  safetyNumber,
} from "./protocolHarness.js";

test("establishes an official libsignal session and consumes one-time prekeys once", async () => {
  const session = await establishLibsignalSession();

  assert.equal(session.initialCiphertextType, Signal.CiphertextMessageType.PreKey);
  assert.equal(session.initialMessage.preKeyId(), 101);
  assert.equal(session.replyCiphertextType, Signal.CiphertextMessageType.Whisper);
  assert.deepEqual(session.bob.preKeyStore.removedPreKeyIds, [101]);
  assert.equal(session.bob.kyberPreKeyStore.usedKyberPreKeys.length, 1);
  assert.equal(session.bob.kyberPreKeyStore.usedKyberPreKeys[0]?.kyberPreKeyId, 301);
  assert.equal(session.bob.kyberPreKeyStore.usedKyberPreKeys[0]?.signedPreKeyId, 201);

  await assert.rejects(
    session.bob.preKeyStore.getPreKey(101),
    /missing prekey 101/,
    "consumed one-time prekey must not remain available",
  );
});

test("opens out-of-order Whisper messages within skip limits and rejects replay", async () => {
  const { alice, bob } = await establishLibsignalSession();
  const second = await encryptWhisper("second", alice, bob);
  const third = await encryptWhisper("third", alice, bob);

  assert.equal(await decryptWhisper(third, alice, bob), "third");
  assert.equal(await decryptWhisper(second, alice, bob), "second");

  await assert.rejects(
    decryptWhisper(second, alice, bob),
    /old counter|duplicate|message/i,
    "replayed message must fail closed after first successful decrypt",
  );
});

test("safety numbers change when a remote identity key changes", async () => {
  const alice = makeHarnessDevice("safety-alice", 1, 1111);
  const bob = makeHarnessDevice("safety-bob", 1, 2222);
  await publishPreKeyBundle(bob);

  const original = safetyNumber(
    alice.address.toString(),
    alice.identityKeyPair.publicKey,
    bob.address.toString(),
    bob.identityKeyPair.publicKey,
  );
  const replacementIdentity = Signal.IdentityKeyPair.generate();
  const replacement = safetyNumber(
    alice.address.toString(),
    alice.identityKeyPair.publicKey,
    bob.address.toString(),
    replacementIdentity.publicKey,
  );

  assert.notEqual(original, replacement);
  assert.equal(
    await alice.identityStore.saveIdentity(bob.address, bob.identityKeyPair.publicKey),
    Signal.IdentityChange.NewOrUnchanged,
  );
  assert.equal(
    await alice.identityStore.saveIdentity(bob.address, replacementIdentity.publicKey),
    Signal.IdentityChange.ReplacedExisting,
  );
  assert.equal(
    await alice.identityStore.isTrustedIdentity(
      bob.address,
      bob.identityKeyPair.publicKey,
      Signal.Direction.Sending,
    ),
    false,
  );
});

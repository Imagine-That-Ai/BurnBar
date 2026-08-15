#!/usr/bin/env node
/**
 * BurnBar's Hermes Agent official-libsignal sidecar.
 *
 * JSON-lines protocol, deliberately no plaintext logging. Private Signal state is
 * encrypted with a 256-bit local key and committed atomically under a 0700 state
 * directory. The only wire outputs are public prekey material and Signal
 * ciphertext/envelopes.
 */
import { createCipheriv, createDecipheriv, createHash, randomBytes, randomInt } from 'node:crypto';
import { createInterface } from 'node:readline';
import { mkdir, readFile, rename, writeFile, chmod } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import {
  IdentityKeyPair,
  ProtocolAddress,
  createInMemoryStores,
  generateIdentity,
  generatePreKeys,
  publishedPreKeyBundle,
  preKeyBundleFromPublished,
  establishSession,
  encrypt,
  decrypt,
} from '@openburnbar/libsignal-protocol';

const uid = process.env.BURNBAR_SIGNAL_UID ?? '';
const identityKeyId = process.env.BURNBAR_SIGNAL_IDENTITY_KEY_ID ?? 'hermes-agent_1';
const stateRoot = process.env.BURNBAR_SIGNAL_STATE_DIR ?? join(homedir(), '.hermes', 'burnbar-signal');
const stateFile = join(stateRoot, 'state.enc');
const stateKeyFile = join(stateRoot, 'state.key');
const localDeviceString = process.env.BURNBAR_SIGNAL_DEVICE_ID ?? identityKeyId;

function fail(message) { throw new Error(message); }
function safeSegment(value) {
  const normalized = String(value ?? '').trim().replace(/[^A-Za-z0-9_-]/g, '_').replace(/^_+|_+$/g, '');
  return normalized || 'unknown';
}
function addressName(peerUid, peerIdentityKeyId) {
  return `openburnbar.${safeSegment(peerUid)}.${safeSegment(peerIdentityKeyId)}.${safeSegment(peerIdentityKeyId)}`;
}
function stableUInt32(seed, min, max) {
  const digest = createHash('sha256').update(seed).digest();
  const raw = digest.readUInt32BE(0);
  return min + (raw % (max - min + 1));
}
function localAddress() {
  return ProtocolAddress.new(addressName(uid, identityKeyId), stableUInt32(`device|${uid}|${localDeviceString}|${identityKeyId}|1`, 1, 127));
}
function peerAddress(peerUid, peerBundle) {
  return ProtocolAddress.new(addressName(peerUid, peerBundle.identityKeyId), peerBundle.deviceId);
}
function b64(value) { return Buffer.from(value).toString('base64'); }
function unb64(value) { return Buffer.from(value, 'base64'); }

async function ensureStateDir() {
  await mkdir(stateRoot, { recursive: true, mode: 0o700 });
  await chmod(stateRoot, 0o700);
}
async function loadStateKey() {
  await ensureStateDir();
  try {
    const key = await readFile(stateKeyFile);
    if (key.length !== 32) fail('invalid Signal state key length');
    return key;
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    const key = randomBytes(32);
    await writeFile(stateKeyFile, key, { mode: 0o600 });
    await chmod(stateKeyFile, 0o600);
    return key;
  }
}
async function readEncryptedState() {
  try {
    const raw = await readFile(stateFile, 'utf8');
    const bytes = Buffer.from(raw, 'base64');
    if (bytes.length < 12 + 16) fail('truncated Signal state');
    const decipher = createDecipheriv('aes-256-gcm', await loadStateKey(), bytes.subarray(0, 12));
    decipher.setAuthTag(bytes.subarray(12, 28));
    return JSON.parse(Buffer.concat([decipher.update(bytes.subarray(28)), decipher.final()]).toString('utf8'));
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
}
async function writeEncryptedState(state) {
  await ensureStateDir();
  const key = await loadStateKey();
  const iv = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', key, iv);
  const ciphertext = Buffer.concat([cipher.update(JSON.stringify(state), 'utf8'), cipher.final()]);
  const packed = Buffer.concat([iv, cipher.getAuthTag(), ciphertext]).toString('base64');
  const temporary = `${stateFile}.${process.pid}.${randomInt(1, 1_000_000)}.tmp`;
  await writeFile(temporary, packed, { mode: 0o600 });
  await chmod(temporary, 0o600);
  await rename(temporary, stateFile);
}

async function createRuntime() {
  const saved = await readEncryptedState();
  const identity = saved
    ? { identityKeyPair: IdentityKeyPair.deserialize(unb64(saved.identityKeyPairB64)), registrationId: saved.registrationId }
    : generateIdentity();
  const stores = createInMemoryStores(identity);
  if (saved) {
    stores.identityStore.restoreTrustedIdentities(saved.trustedIdentities ?? []);
    stores.sessionStore.restore(saved.sessions ?? []);
    stores.preKeyStore.restore(saved.preKeys ?? []);
    stores.signedPreKeyStore.restore(saved.signedPreKeys ?? []);
    stores.kyberPreKeyStore.restore(saved.kyberPreKeys ?? []);
  }
  let prekeys;
  if (saved?.preKeyIds) {
    prekeys = {
      preKey: await stores.preKeyStore.getPreKey(saved.preKeyIds.preKeyId),
      signedPreKey: await stores.signedPreKeyStore.getSignedPreKey(saved.preKeyIds.signedPreKeyId),
      kyberPreKey: await stores.kyberPreKeyStore.getKyberPreKey(saved.preKeyIds.kyberPreKeyId),
    };
  } else {
    const ids = { preKeyId: randomInt(1, 0x7fffffff), signedPreKeyId: randomInt(1, 0x7fffffff), kyberPreKeyId: randomInt(1, 0x7fffffff) };
    prekeys = await generatePreKeys(identity, stores, ids);
  }
  const state = saved ?? { peerPins: {} };
  state.peerPins ??= {};
  state.identityKeyPairB64 = b64(identity.identityKeyPair.serialize());
  state.registrationId = identity.registrationId;
  state.preKeyIds = { preKeyId: prekeys.preKey.id(), signedPreKeyId: prekeys.signedPreKey.id(), kyberPreKeyId: prekeys.kyberPreKey.id() };
  const bundle = publishedPreKeyBundle(identity, stableUInt32(`bundle|${uid}|${identityKeyId}`, 1, 127), identityKeyId, state.bundleId ?? `${identityKeyId}-1`, prekeys);
  state.bundleId = bundle.bundleId;
  return { identity, stores, prekeys, state, bundle };
}

async function persist(runtime) {
  runtime.state.trustedIdentities = runtime.stores.identityStore.snapshotTrustedIdentities();
  runtime.state.sessions = runtime.stores.sessionStore.snapshot();
  runtime.state.preKeys = runtime.stores.preKeyStore.snapshot();
  runtime.state.signedPreKeys = runtime.stores.signedPreKeyStore.snapshot();
  runtime.state.kyberPreKeys = runtime.stores.kyberPreKeyStore.snapshot();
  await writeEncryptedState(runtime.state);
}
function peerPinKey(peerUid, bundle) { return `${peerUid}|${bundle.identityKeyId}`; }
function assertPinned(runtime, peerUid, bundle) {
  const logical = `${peerUid}|${bundle.identityKeyId}`;
  const existing = runtime.state.peerPins[logical];
  if (existing && existing !== bundle.identityKeyB64) fail('Signal peer identity pin mismatch');
  runtime.state.peerPins[logical] = bundle.identityKeyB64;
}
function envelopeFromCiphertext(ciphertext, binding, senderIdentityKeyId) {
  const bodyB64 = b64(ciphertext.body);
  return {
    signalEnvelopeFormatVersion: 1,
    mode: 'transport',
    // The shared sanitizer (SIGNAL_RELAY_KEY_VERSION) hard-requires 4 on every
    // transport envelope; omitting it makes requireProductionGatewaySignalEnvelope
    // reject agent replies and attachment manifests.
    relayKeyVersion: 4,
    relayEncryption: 'signal-doubleratchet-pqxdh-v1',
    ciphertextLayer: { payloadCiphertextB64: bodyB64, payloadAADLabel: 'hermes-gateway-v4', schemaVersion: 1 },
    keyDelivery: { scheme: 'signal-doubleratchet-pqxdh-v1', signalMessageType: ciphertext.type, signalMessageB64: bodyB64, senderIdentityKeyId },
    binding: { ...binding, mode: 'transport', formatVersion: 1 },
  };
}
async function seal(runtime, request) {
  const peer = request.peerBundle;
  if (!peer || peer.version !== 1 || request.peerUid !== uid) fail('invalid or cross-user Signal peer bundle');
  assertPinned(runtime, request.peerUid, peer);
  const remote = peerAddress(request.peerUid, peer);
  const local = localAddress();
  const remoteBundle = preKeyBundleFromPublished(peer);
  if (!(await runtime.stores.sessionStore.getSession(remote))) await establishSession(remote, remoteBundle, runtime.stores);
  const ciphertext = await encrypt(unb64(request.plaintextB64), remote, local, runtime.stores);
  await persist(runtime);
  return envelopeFromCiphertext(ciphertext, { uid, scope: 'gateway', clientId: request.clientId, slotId: request.slotId }, identityKeyId);
}
async function open(runtime, request) {
  const peer = request.peerBundle;
  if (!peer || request.peerUid !== uid) fail('invalid or cross-user Signal peer bundle');
  assertPinned(runtime, request.peerUid, peer);
  const remote = peerAddress(request.peerUid, peer);
  const plaintext = await decrypt({ type: request.signalMessageType, body: unb64(request.signalMessageB64) }, remote, localAddress(), runtime.stores);
  await persist(runtime);
  return { plaintextB64: b64(plaintext) };
}

const runtime = await createRuntime();
await persist(runtime);
const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });
for await (const line of rl) {
  if (!line.trim()) continue;
  try {
    const request = JSON.parse(line);
    let result;
    if (request.op === 'status' || request.op === 'bundle') result = { identityKeyId, bundle: runtime.bundle };
    else if (request.op === 'seal') result = { envelope: await seal(runtime, request) };
    else if (request.op === 'open') result = await open(runtime, request);
    else fail(`unsupported Signal sidecar operation: ${request.op}`);
    process.stdout.write(`${JSON.stringify({ ok: true, ...result })}\n`);
  } catch (error) {
    process.stdout.write(`${JSON.stringify({ ok: false, error: error instanceof Error ? error.message : 'Signal sidecar failure' })}\n`);
  }
}

// SPDX-License-Identifier: AGPL-3.0-only
//
// @openburnbar/libsignal-protocol
//
// This package is the *single* BurnBar crypto boundary over the official Signal
// library. Every BurnBar consumer of Signal-protocol primitives (X3DH + PQXDH
// session setup, the Double Ratchet, safety numbers, and HPKE at-rest sealing)
// is intended to go through this facade rather than reaching for
// `@signalapp/libsignal-client` directly. Centralising the boundary keeps the
// crypto surface auditable and lets us swap the underlying provider in one place.
//
// PROVENANCE (AGPL re-point — DONE):
//   The in-repo AGPL wrapper `packages/libsignal-bridge/` (published as
//   `@openburnbar/libsignal-bridge`) is the single place allowed to import the
//   upstream `@signalapp/libsignal-client@0.94.4` directly. This package imports
//   the same Signal-protocol symbols from the bridge, so the AGPL boundary stays
//   intact (enforced by scripts/ci/check_burnbar_license_posture.py's
//   "Signal bridge boundary" check).
//
// STATUS: inert / flag-off. Nothing in the existing app imports this module, so
// introducing it changes no production behavior.

import {
  // EC / identity keys (EcKeys.d.ts)
  IdentityKeyPair,
  PrivateKey,
  PublicKey,
  // KEM (Kyber) types (index.d.ts / ProtocolTypes.d.ts)
  KEMKeyPair,
  KEMPublicKey,
  // Records
  PreKeyRecord,
  SignedPreKeyRecord,
  KyberPreKeyRecord,
  SessionRecord,
  // Bundle + addressing
  PreKeyBundle,
  ProtocolAddress,
  // Store abstract bases
  IdentityKeyStore,
  SessionStore,
  PreKeyStore,
  SignedPreKeyStore,
  KyberPreKeyStore,
  IdentityChange,
  Direction,
  // Messages
  CiphertextMessage,
  CiphertextMessageType,
  SignalMessage,
  PreKeySignalMessage,
  // Session protocol functions
  processPreKeyBundle,
  signalEncrypt,
  signalDecrypt,
  signalDecryptPreKey,
  // Safety number
  Fingerprint,
} from '@openburnbar/libsignal-bridge';
import { bindingToAAD, type SignalBinding } from '@openburnbar/signal-envelope-contracts';
import { randomInt } from 'node:crypto';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/**
 * Default safety-number fingerprint iteration count. 5200 matches the value used
 * by the Signal apps for displayable fingerprints; both parties MUST use the
 * same value or the derived numbers will not match.
 */
export const SAFETY_NUMBER_ITERATIONS = 5200;

/** Fingerprint format version. Version 2 is the current Signal displayable format. */
export const FINGERPRINT_VERSION = 2;

/**
 * Domain-separation prefix for the HPKE at-rest primitive. The full `info` value
 * passed to seal/open is `AT_REST_INFO_PREFIX + bindingToAAD(binding)`, where the
 * binding canonicalization is the shared, cross-language v4 grammar defined in
 * `@openburnbar/signal-envelope-contracts`. Bumping the `v1` suffix is a hard
 * fork of all sealed-at-rest material.
 */
export const AT_REST_INFO_PREFIX = 'OpenBurnBar-Signal-AtRest-v1|';

const utf8 = new TextEncoder();

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/** A locally generated long-term identity plus its registration id. */
export interface GeneratedIdentity {
  readonly identityKeyPair: IdentityKeyPair;
  readonly registrationId: number;
}

/**
 * One-time + signed + Kyber prekeys generated for a single registration.
 * In 0.94.4 the Kyber prekey is MANDATORY (PreKeyBundle.new requires a
 * non-nullable kyber prekey id/key/signature), so we always generate one.
 */
export interface GeneratedPreKeys {
  readonly preKey: PreKeyRecord;
  readonly signedPreKey: SignedPreKeyRecord;
  readonly kyberPreKey: KyberPreKeyRecord;
}

/** A fully addressed, established session endpoint stored in memory. */
export interface SessionStores {
  readonly identityStore: InMemoryIdentityKeyStore;
  readonly sessionStore: InMemorySessionStore;
  readonly preKeyStore: InMemoryPreKeyStore;
  readonly signedPreKeyStore: InMemorySignedPreKeyStore;
  readonly kyberPreKeyStore: InMemoryKyberPreKeyStore;
}

// ---------------------------------------------------------------------------
// In-memory store implementations
//
// These are the abstract-class implementations libsignal calls back into during
// session setup / encrypt / decrypt. They are deliberately ephemeral; persistent
// consumers will provide their own durable stores fronting this facade.
// ---------------------------------------------------------------------------

function addressKey(address: ProtocolAddress): string {
  return `${address.name()}::${address.deviceId()}`;
}

export class InMemoryIdentityKeyStore extends IdentityKeyStore {
  private readonly idKeyPair: IdentityKeyPair;
  private readonly localRegistrationId: number;
  private readonly trustedIdentities = new Map<string, PublicKey>();

  constructor(idKeyPair: IdentityKeyPair, localRegistrationId: number) {
    super();
    this.idKeyPair = idKeyPair;
    this.localRegistrationId = localRegistrationId;
  }

  // NOTE (0.94.4): the abstract member is getIdentityKey() returning the
  // *PrivateKey*, while getIdentityKeyPair() is a concrete helper on the base
  // class. We satisfy the abstract member here.
  override async getIdentityKey(): Promise<PrivateKey> {
    return this.idKeyPair.privateKey;
  }

  override async getLocalRegistrationId(): Promise<number> {
    return this.localRegistrationId;
  }

  override async saveIdentity(
    name: ProtocolAddress,
    key: PublicKey,
  ): Promise<IdentityChange> {
    const k = addressKey(name);
    const existing = this.trustedIdentities.get(k);
    this.trustedIdentities.set(k, key);
    if (existing && !existing.equals(key)) {
      return IdentityChange.ReplacedExisting;
    }
    return IdentityChange.NewOrUnchanged;
  }

  override async isTrustedIdentity(
    name: ProtocolAddress,
    key: PublicKey,
    _direction: Direction,
  ): Promise<boolean> {
    const existing = this.trustedIdentities.get(addressKey(name));
    if (!existing) {
      // Trust on first use: an unknown identity is accepted, then pinned.
      return true;
    }
    return existing.equals(key);
  }

  override async getIdentity(name: ProtocolAddress): Promise<PublicKey | null> {
    return this.trustedIdentities.get(addressKey(name)) ?? null;
  }
}

export class InMemorySessionStore extends SessionStore {
  private readonly sessions = new Map<string, SessionRecord>();

  override async saveSession(
    name: ProtocolAddress,
    record: SessionRecord,
  ): Promise<void> {
    this.sessions.set(addressKey(name), record);
  }

  override async getSession(
    name: ProtocolAddress,
  ): Promise<SessionRecord | null> {
    return this.sessions.get(addressKey(name)) ?? null;
  }

  override async getExistingSessions(
    addresses: ProtocolAddress[],
  ): Promise<SessionRecord[]> {
    return addresses.map((addr) => {
      const record = this.sessions.get(addressKey(addr));
      if (!record) {
        throw new Error(`no session for ${addressKey(addr)}`);
      }
      return record;
    });
  }
}

export class InMemoryPreKeyStore extends PreKeyStore {
  private readonly preKeys = new Map<number, PreKeyRecord>();

  override async savePreKey(id: number, record: PreKeyRecord): Promise<void> {
    this.preKeys.set(id, record);
  }

  override async getPreKey(id: number): Promise<PreKeyRecord> {
    const record = this.preKeys.get(id);
    if (!record) {
      throw new Error(`no prekey for id ${id}`);
    }
    return record;
  }

  override async removePreKey(id: number): Promise<void> {
    this.preKeys.delete(id);
  }
}

export class InMemorySignedPreKeyStore extends SignedPreKeyStore {
  private readonly signedPreKeys = new Map<number, SignedPreKeyRecord>();

  override async saveSignedPreKey(
    id: number,
    record: SignedPreKeyRecord,
  ): Promise<void> {
    this.signedPreKeys.set(id, record);
  }

  override async getSignedPreKey(id: number): Promise<SignedPreKeyRecord> {
    const record = this.signedPreKeys.get(id);
    if (!record) {
      throw new Error(`no signed prekey for id ${id}`);
    }
    return record;
  }
}

export class InMemoryKyberPreKeyStore extends KyberPreKeyStore {
  private readonly kyberPreKeys = new Map<number, KyberPreKeyRecord>();
  private readonly used = new Set<number>();

  override async saveKyberPreKey(
    kyberPreKeyId: number,
    record: KyberPreKeyRecord,
  ): Promise<void> {
    this.kyberPreKeys.set(kyberPreKeyId, record);
  }

  override async getKyberPreKey(
    kyberPreKeyId: number,
  ): Promise<KyberPreKeyRecord> {
    const record = this.kyberPreKeys.get(kyberPreKeyId);
    if (!record) {
      throw new Error(`no kyber prekey for id ${kyberPreKeyId}`);
    }
    return record;
  }

  // NOTE (0.94.4): signature is (kyberPreKeyId, signedPreKeyId, baseKey).
  override async markKyberPreKeyUsed(
    kyberPreKeyId: number,
    _signedPreKeyId: number,
    _baseKey: PublicKey,
  ): Promise<void> {
    this.used.add(kyberPreKeyId);
  }

  /** Test/diagnostic helper: was this Kyber prekey marked used? */
  wasUsed(kyberPreKeyId: number): boolean {
    return this.used.has(kyberPreKeyId);
  }
}

/** Convenience factory for a complete fresh set of in-memory stores. */
export function createInMemoryStores(identity: GeneratedIdentity): SessionStores {
  return {
    identityStore: new InMemoryIdentityKeyStore(
      identity.identityKeyPair,
      identity.registrationId,
    ),
    sessionStore: new InMemorySessionStore(),
    preKeyStore: new InMemoryPreKeyStore(),
    signedPreKeyStore: new InMemorySignedPreKeyStore(),
    kyberPreKeyStore: new InMemoryKyberPreKeyStore(),
  };
}

// ---------------------------------------------------------------------------
// Identity + prekey generation
// ---------------------------------------------------------------------------

/**
 * Signal registration ids are 14-bit values whose canonical valid range is
 * 1..16383 (0x3FFF). The registration id is NOT a secret — it is a
 * collision-avoidance identifier — but this package is the single BurnBar crypto
 * boundary, so all randomness here comes from a CSPRNG (node:crypto) rather than
 * Math.random() to keep the surface uniformly auditable. randomInt's upper bound
 * is exclusive, so (1, 16384) yields 1..16383 inclusive, uniformly.
 */
function randomRegistrationId(): number {
  return randomInt(1, 16384);
}

/** Generate a fresh long-term identity key pair and registration id. */
export function generateIdentity(): GeneratedIdentity {
  return {
    identityKeyPair: IdentityKeyPair.generate(),
    registrationId: randomRegistrationId(),
  };
}

/**
 * Generate the prekeys needed to publish a PreKeyBundle:
 *   - a one-time EC prekey,
 *   - a signed EC prekey (signed by the identity key),
 *   - a signed Kyber (PQXDH) prekey (signed by the identity key).
 *
 * The Kyber prekey is MANDATORY in 0.94.4: PreKeyBundle.new requires non-null
 * kyber id/key/signature, and signalDecryptPreKey routes through the Kyber
 * prekey store.
 *
 * The records are written into the provided stores (so a later
 * signalDecryptPreKey can find them) and returned for buildPreKeyBundle().
 */
export async function generatePreKeys(
  identity: GeneratedIdentity,
  stores: SessionStores,
  ids: { preKeyId: number; signedPreKeyId: number; kyberPreKeyId: number },
  now: number = Date.now(),
): Promise<GeneratedPreKeys> {
  const idPriv = identity.identityKeyPair.privateKey;

  // One-time EC prekey.
  const preKeyPriv = PrivateKey.generate();
  const preKeyPub = preKeyPriv.getPublicKey();
  const preKey = PreKeyRecord.new(ids.preKeyId, preKeyPub, preKeyPriv);

  // Signed EC prekey: signature over the serialized public key, by the identity.
  const signedPriv = PrivateKey.generate();
  const signedPub = signedPriv.getPublicKey();
  const signedSig = idPriv.sign(signedPub.serialize());
  const signedPreKey = SignedPreKeyRecord.new(
    ids.signedPreKeyId,
    now,
    signedPub,
    signedPriv,
    signedSig,
  );

  // Signed Kyber prekey (PQXDH): signature over the serialized KEM public key.
  const kemPair = KEMKeyPair.generate();
  const kyberSig = idPriv.sign(kemPair.getPublicKey().serialize());
  const kyberPreKey = KyberPreKeyRecord.new(
    ids.kyberPreKeyId,
    now,
    kemPair,
    kyberSig,
  );

  await stores.preKeyStore.savePreKey(ids.preKeyId, preKey);
  await stores.signedPreKeyStore.saveSignedPreKey(ids.signedPreKeyId, signedPreKey);
  await stores.kyberPreKeyStore.saveKyberPreKey(ids.kyberPreKeyId, kyberPreKey);

  return { preKey, signedPreKey, kyberPreKey };
}

/**
 * Assemble a PreKeyBundle from a peer's published prekey material. This is what
 * the *initiator* fetches for the *recipient* and feeds to establishSession().
 */
export function buildPreKeyBundle(
  identity: GeneratedIdentity,
  deviceId: number,
  prekeys: GeneratedPreKeys,
): PreKeyBundle {
  return PreKeyBundle.new(
    identity.registrationId,
    deviceId,
    prekeys.preKey.id(),
    prekeys.preKey.publicKey(),
    prekeys.signedPreKey.id(),
    prekeys.signedPreKey.publicKey(),
    prekeys.signedPreKey.signature(),
    identity.identityKeyPair.publicKey,
    // Kyber (mandatory, non-nullable in 0.94.4):
    prekeys.kyberPreKey.id(),
    prekeys.kyberPreKey.publicKey(),
    prekeys.kyberPreKey.signature(),
  );
}

// ---------------------------------------------------------------------------
// Session establishment + message encrypt/decrypt
// ---------------------------------------------------------------------------

/**
 * Establish a session toward `remoteAddress` by processing their PreKeyBundle.
 * This performs the X3DH + PQXDH key agreement and writes the session into
 * `localStores.sessionStore`. After this, encrypt() can send to that address.
 */
export async function establishSession(
  remoteAddress: ProtocolAddress,
  bundle: PreKeyBundle,
  localStores: SessionStores,
  now: Date = new Date(),
): Promise<void> {
  await processPreKeyBundle(
    bundle,
    remoteAddress,
    /* localAddress is unused by processPreKeyBundle but kept for symmetry: */
    remoteAddress,
    localStores.sessionStore,
    localStores.identityStore,
    now,
  );
}

/**
 * Encrypt `plaintext` for `remoteAddress` using the Double Ratchet. Returns the
 * serialized ciphertext plus its type byte so the receiver can route to the
 * correct decryptor (PreKey vs Whisper). The type is a `CiphertextMessageType`.
 */
export async function encrypt(
  plaintext: Uint8Array,
  remoteAddress: ProtocolAddress,
  localAddress: ProtocolAddress,
  localStores: SessionStores,
  now: Date = new Date(),
): Promise<{ type: number; body: Uint8Array }> {
  const message: CiphertextMessage = await signalEncrypt(
    asArrayBufferBacked(plaintext),
    remoteAddress,
    localAddress,
    localStores.sessionStore,
    localStores.identityStore,
    now,
  );
  return { type: message.type(), body: message.serialize() };
}

/**
 * Decrypt a ciphertext produced by encrypt(). Routes on the type byte:
 *   - PreKey (3)  -> signalDecryptPreKey (consumes one-time + kyber prekeys)
 *   - Whisper (2) -> signalDecrypt (steady-state Double Ratchet)
 *
 * Replay of an already-consumed PreKey ciphertext, or of a ratchet message whose
 * message key has already been used, is rejected by libsignal (this surfaces as
 * a thrown error from the underlying decryptor — see the tests).
 */
export async function decrypt(
  ciphertext: { type: number; body: Uint8Array },
  remoteAddress: ProtocolAddress,
  localAddress: ProtocolAddress,
  localStores: SessionStores,
): Promise<Uint8Array> {
  const body = asArrayBufferBacked(ciphertext.body);
  if (ciphertext.type === CiphertextMessageType.PreKey) {
    const msg = PreKeySignalMessage.deserialize(body);
    return signalDecryptPreKey(
      msg,
      remoteAddress,
      localAddress,
      localStores.sessionStore,
      localStores.identityStore,
      localStores.preKeyStore,
      localStores.signedPreKeyStore,
      localStores.kyberPreKeyStore,
    );
  }
  if (ciphertext.type === CiphertextMessageType.Whisper) {
    const msg = SignalMessage.deserialize(body);
    return signalDecrypt(
      msg,
      remoteAddress,
      localAddress,
      localStores.sessionStore,
      localStores.identityStore,
    );
  }
  throw new Error(`unsupported ciphertext type ${ciphertext.type}`);
}

// ---------------------------------------------------------------------------
// Safety numbers
// ---------------------------------------------------------------------------

/**
 * Derive the displayable safety number between a local and remote identity.
 *
 * `localIdentifier` / `remoteIdentifier` are stable per-party identifiers (e.g.
 * the UTF-8 of an ACI/username). Both parties compute the SAME displayable
 * string by swapping local/remote — see the test.
 */
export function safetyNumber(
  localIdentifier: string | Uint8Array,
  localIdentityKey: PublicKey,
  remoteIdentifier: string | Uint8Array,
  remoteIdentityKey: PublicKey,
  iterations: number = SAFETY_NUMBER_ITERATIONS,
): string {
  const fp = Fingerprint.new(
    iterations,
    FINGERPRINT_VERSION,
    toArrayBufferBytes(localIdentifier),
    localIdentityKey,
    toArrayBufferBytes(remoteIdentifier),
    remoteIdentityKey,
  );
  return fp.displayableFingerprint().toString();
}

// ---------------------------------------------------------------------------
// At-rest HPKE sealing (RFC 9180 single-shot to a long-term identity key)
// ---------------------------------------------------------------------------

/**
 * Seal `plaintext` so only the holder of the private half of `recipientIdentity`
 * can open it. Single-shot HPKE (RFC 9180) via PublicKey#seal.
 *
 * `binding` is the structured v4 {@link SignalBinding} (uid/scope/collection/…).
 * It is canonicalized via {@link bindingToAAD} — the shared cross-language
 * serializer — and the resulting string is woven into BOTH the HPKE `info`
 * (`AT_REST_INFO_PREFIX + bindingToAAD(binding)`) AND the AEAD `associatedData`
 * (`utf8(bindingToAAD(binding))`). Opening with a different binding fails closed
 * (see the at-rest tamper test). `bindingToAAD` is itself fail-closed: it THROWS
 * before any seal happens if a segment carries a reserved `|`/CR/LF.
 */
export function atRestSeal(
  plaintext: Uint8Array,
  recipientIdentity: PublicKey,
  binding: SignalBinding,
): Uint8Array {
  const canonical = bindingToAAD(binding);
  const info = AT_REST_INFO_PREFIX + canonical;
  const aad = utf8.encode(canonical);
  return recipientIdentity.seal(
    asArrayBufferBacked(plaintext),
    info,
    asArrayBufferBacked(aad),
  );
}

/**
 * Open a ciphertext produced by atRestSeal. The structured `binding` MUST
 * canonicalize (via {@link bindingToAAD}) to exactly the one used at seal time;
 * any mismatch in `info` or `associatedData` causes the underlying AEAD to fail
 * and this throws (fail-closed).
 */
export function atRestOpen(
  ciphertext: Uint8Array,
  recipientPrivate: PrivateKey,
  binding: SignalBinding,
): Uint8Array {
  const canonical = bindingToAAD(binding);
  const info = AT_REST_INFO_PREFIX + canonical;
  const aad = utf8.encode(canonical);
  return recipientPrivate.open(
    asArrayBufferBacked(ciphertext),
    info,
    asArrayBufferBacked(aad),
  );
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/**
 * libsignal's typings annotate byte parameters as `Uint8Array<ArrayBuffer>`
 * (i.e. backed by a plain ArrayBuffer, not a SharedArrayBuffer). A Uint8Array
 * constructed normally already satisfies this at runtime; this helper makes the
 * intent explicit and copies only if the view is offset/shared so the native
 * layer always sees the exact bytes.
 */
function asArrayBufferBacked(bytes: Uint8Array): Uint8Array<ArrayBuffer> {
  if (
    bytes.byteOffset === 0 &&
    bytes.byteLength === bytes.buffer.byteLength &&
    bytes.buffer instanceof ArrayBuffer
  ) {
    return bytes as Uint8Array<ArrayBuffer>;
  }
  const copy = new Uint8Array(bytes.byteLength);
  copy.set(bytes);
  return copy as Uint8Array<ArrayBuffer>;
}

function toArrayBufferBytes(
  value: string | Uint8Array,
): Uint8Array<ArrayBuffer> {
  if (typeof value === 'string') {
    return utf8.encode(value) as Uint8Array<ArrayBuffer>;
  }
  return asArrayBufferBacked(value);
}

// Re-export the underlying types consumers will need to hold references to,
// so they never have to import @signalapp/libsignal-client directly.
export {
  IdentityKeyPair,
  PrivateKey,
  PublicKey,
  KEMKeyPair,
  KEMPublicKey,
  PreKeyBundle,
  ProtocolAddress,
  PreKeyRecord,
  SignedPreKeyRecord,
  KyberPreKeyRecord,
  SessionRecord,
  CiphertextMessageType,
};

// Re-export the structured binding type so consumers of the at-rest seal/open
// API can construct bindings without importing the contracts package directly.
export type { SignalBinding } from '@openburnbar/signal-envelope-contracts';

import * as Signal from "@signalapp/libsignal-client";

export const LIBSIGNAL_PROTOCOL_HARNESS_VERSION = 1;

export class InMemorySessionStore extends Signal.SessionStore {
  private readonly sessions = new Map<string, Uint8Array<ArrayBuffer>>();

  async saveSession(name: Signal.ProtocolAddress, record: Signal.SessionRecord): Promise<void> {
    this.sessions.set(addressKey(name), record.serialize());
  }

  async getSession(name: Signal.ProtocolAddress): Promise<Signal.SessionRecord | null> {
    const serialized = this.sessions.get(addressKey(name));
    return serialized ? Signal.SessionRecord.deserialize(serialized) : null;
  }

  async getExistingSessions(addresses: Signal.ProtocolAddress[]): Promise<Signal.SessionRecord[]> {
    const records: Signal.SessionRecord[] = [];
    for (const address of addresses) {
      const record = await this.getSession(address);
      if (record) records.push(record);
    }
    return records;
  }
}

export class InMemoryIdentityKeyStore extends Signal.IdentityKeyStore {
  private readonly identities = new Map<string, Uint8Array<ArrayBuffer>>();

  constructor(
    private readonly localIdentity: Signal.IdentityKeyPair,
    private readonly localRegistrationId: number,
  ) {
    super();
  }

  async getIdentityKey(): Promise<Signal.PrivateKey> {
    return this.localIdentity.privateKey;
  }

  async getLocalRegistrationId(): Promise<number> {
    return this.localRegistrationId;
  }

  async saveIdentity(
    name: Signal.ProtocolAddress,
    key: Signal.PublicKey,
  ): Promise<Signal.IdentityChange> {
    const storageKey = addressKey(name);
    const previous = this.identities.get(storageKey);
    this.identities.set(storageKey, key.serialize());
    if (previous && !Signal.PublicKey.deserialize(previous).equals(key)) {
      return Signal.IdentityChange.ReplacedExisting;
    }
    return Signal.IdentityChange.NewOrUnchanged;
  }

  async isTrustedIdentity(
    name: Signal.ProtocolAddress,
    key: Signal.PublicKey,
    _direction: Signal.Direction,
  ): Promise<boolean> {
    const previous = this.identities.get(addressKey(name));
    return !previous || Signal.PublicKey.deserialize(previous).equals(key);
  }

  async getIdentity(name: Signal.ProtocolAddress): Promise<Signal.PublicKey | null> {
    const previous = this.identities.get(addressKey(name));
    return previous ? Signal.PublicKey.deserialize(previous) : null;
  }
}

export class InMemoryPreKeyStore extends Signal.PreKeyStore {
  readonly removedPreKeyIds: number[] = [];

  private readonly preKeys = new Map<number, Uint8Array<ArrayBuffer>>();

  async savePreKey(id: number, record: Signal.PreKeyRecord): Promise<void> {
    this.preKeys.set(id, record.serialize());
  }

  async getPreKey(id: number): Promise<Signal.PreKeyRecord> {
    const serialized = this.preKeys.get(id);
    if (!serialized) throw new Error(`missing prekey ${id}`);
    return Signal.PreKeyRecord.deserialize(serialized);
  }

  async removePreKey(id: number): Promise<void> {
    this.removedPreKeyIds.push(id);
    this.preKeys.delete(id);
  }
}

export class InMemorySignedPreKeyStore extends Signal.SignedPreKeyStore {
  private readonly signedPreKeys = new Map<number, Uint8Array<ArrayBuffer>>();

  async saveSignedPreKey(id: number, record: Signal.SignedPreKeyRecord): Promise<void> {
    this.signedPreKeys.set(id, record.serialize());
  }

  async getSignedPreKey(id: number): Promise<Signal.SignedPreKeyRecord> {
    const serialized = this.signedPreKeys.get(id);
    if (!serialized) throw new Error(`missing signed prekey ${id}`);
    return Signal.SignedPreKeyRecord.deserialize(serialized);
  }
}

export interface UsedKyberPreKey {
  readonly kyberPreKeyId: number;
  readonly signedPreKeyId: number;
  readonly baseKeyBase64: string;
}

export class InMemoryKyberPreKeyStore extends Signal.KyberPreKeyStore {
  readonly usedKyberPreKeys: UsedKyberPreKey[] = [];

  private readonly kyberPreKeys = new Map<number, Uint8Array<ArrayBuffer>>();

  async saveKyberPreKey(kyberPreKeyId: number, record: Signal.KyberPreKeyRecord): Promise<void> {
    this.kyberPreKeys.set(kyberPreKeyId, record.serialize());
  }

  async getKyberPreKey(kyberPreKeyId: number): Promise<Signal.KyberPreKeyRecord> {
    const serialized = this.kyberPreKeys.get(kyberPreKeyId);
    if (!serialized) throw new Error(`missing Kyber prekey ${kyberPreKeyId}`);
    return Signal.KyberPreKeyRecord.deserialize(serialized);
  }

  async markKyberPreKeyUsed(
    kyberPreKeyId: number,
    signedPreKeyId: number,
    baseKey: Signal.PublicKey,
  ): Promise<void> {
    this.usedKyberPreKeys.push({
      kyberPreKeyId,
      signedPreKeyId,
      baseKeyBase64: Buffer.from(baseKey.serialize()).toString("base64"),
    });
  }
}

export interface LibsignalHarnessDevice {
  readonly address: Signal.ProtocolAddress;
  readonly identityKeyPair: Signal.IdentityKeyPair;
  readonly identityStore: InMemoryIdentityKeyStore;
  readonly sessionStore: InMemorySessionStore;
  readonly preKeyStore: InMemoryPreKeyStore;
  readonly signedPreKeyStore: InMemorySignedPreKeyStore;
  readonly kyberPreKeyStore: InMemoryKyberPreKeyStore;
}

export interface LibsignalPreKeyBundleFixture {
  readonly bundle: Signal.PreKeyBundle;
  readonly preKeyId: number;
  readonly signedPreKeyId: number;
  readonly kyberPreKeyId: number;
}

export interface EstablishedLibsignalSession {
  readonly alice: LibsignalHarnessDevice;
  readonly bob: LibsignalHarnessDevice;
  readonly initialMessage: Signal.PreKeySignalMessage;
  readonly initialCiphertextType: number;
  readonly replyCiphertextType: number;
}

export function makeHarnessDevice(
  name: string,
  deviceId: number,
  registrationId: number,
): LibsignalHarnessDevice {
  const identityKeyPair = Signal.IdentityKeyPair.generate();
  return {
    address: Signal.ProtocolAddress.new(name, deviceId),
    identityKeyPair,
    identityStore: new InMemoryIdentityKeyStore(identityKeyPair, registrationId),
    sessionStore: new InMemorySessionStore(),
    preKeyStore: new InMemoryPreKeyStore(),
    signedPreKeyStore: new InMemorySignedPreKeyStore(),
    kyberPreKeyStore: new InMemoryKyberPreKeyStore(),
  };
}

export async function publishPreKeyBundle(
  device: LibsignalHarnessDevice,
  options: {
    preKeyId?: number;
    signedPreKeyId?: number;
    kyberPreKeyId?: number;
    timestamp?: number;
  } = {},
): Promise<LibsignalPreKeyBundleFixture> {
  const preKeyId = options.preKeyId ?? 101;
  const signedPreKeyId = options.signedPreKeyId ?? 201;
  const kyberPreKeyId = options.kyberPreKeyId ?? 301;
  const timestamp = options.timestamp ?? Date.now();

  const preKeyPrivate = Signal.PrivateKey.generate();
  const signedPreKeyPrivate = Signal.PrivateKey.generate();
  const kyberKeyPair = Signal.KEMKeyPair.generate();

  const preKeyRecord = Signal.PreKeyRecord.new(
    preKeyId,
    preKeyPrivate.getPublicKey(),
    preKeyPrivate,
  );
  const signedPreKeySignature = device.identityKeyPair.privateKey.sign(
    signedPreKeyPrivate.getPublicKey().serialize(),
  );
  const signedPreKeyRecord = Signal.SignedPreKeyRecord.new(
    signedPreKeyId,
    timestamp,
    signedPreKeyPrivate.getPublicKey(),
    signedPreKeyPrivate,
    signedPreKeySignature,
  );
  const kyberPreKeySignature = device.identityKeyPair.privateKey.sign(
    kyberKeyPair.getPublicKey().serialize(),
  );
  const kyberPreKeyRecord = Signal.KyberPreKeyRecord.new(
    kyberPreKeyId,
    timestamp,
    kyberKeyPair,
    kyberPreKeySignature,
  );

  await device.preKeyStore.savePreKey(preKeyId, preKeyRecord);
  await device.signedPreKeyStore.saveSignedPreKey(signedPreKeyId, signedPreKeyRecord);
  await device.kyberPreKeyStore.saveKyberPreKey(kyberPreKeyId, kyberPreKeyRecord);

  return {
    preKeyId,
    signedPreKeyId,
    kyberPreKeyId,
    bundle: Signal.PreKeyBundle.new(
      await device.identityStore.getLocalRegistrationId(),
      device.address.deviceId(),
      preKeyRecord.id(),
      preKeyRecord.publicKey(),
      signedPreKeyRecord.id(),
      signedPreKeyRecord.publicKey(),
      signedPreKeyRecord.signature(),
      device.identityKeyPair.publicKey,
      kyberPreKeyRecord.id(),
      kyberPreKeyRecord.publicKey(),
      kyberPreKeyRecord.signature(),
    ),
  };
}

export async function establishLibsignalSession(): Promise<EstablishedLibsignalSession> {
  const alice = makeHarnessDevice("openburnbar-alice", 1, 1111);
  const bob = makeHarnessDevice("openburnbar-bob", 1, 2222);
  const bobBundle = await publishPreKeyBundle(bob);

  await Signal.processPreKeyBundle(
    bobBundle.bundle,
    bob.address,
    alice.address,
    alice.sessionStore,
    alice.identityStore,
  );

  const initialCiphertext = await Signal.signalEncrypt(
    utf8("initial"),
    bob.address,
    alice.address,
    alice.sessionStore,
    alice.identityStore,
  );
  const initialMessage = Signal.PreKeySignalMessage.deserialize(initialCiphertext.serialize());
  const initialPlaintext = await Signal.signalDecryptPreKey(
    initialMessage,
    alice.address,
    bob.address,
    bob.sessionStore,
    bob.identityStore,
    bob.preKeyStore,
    bob.signedPreKeyStore,
    bob.kyberPreKeyStore,
  );
  assertText(initialPlaintext, "initial");

  const replyCiphertext = await Signal.signalEncrypt(
    utf8("reply"),
    alice.address,
    bob.address,
    bob.sessionStore,
    bob.identityStore,
  );
  const replyMessage = Signal.SignalMessage.deserialize(replyCiphertext.serialize());
  const replyPlaintext = await Signal.signalDecrypt(
    replyMessage,
    bob.address,
    alice.address,
    alice.sessionStore,
    alice.identityStore,
  );
  assertText(replyPlaintext, "reply");

  return {
    alice,
    bob,
    initialMessage,
    initialCiphertextType: initialCiphertext.type(),
    replyCiphertextType: replyCiphertext.type(),
  };
}

export async function encryptWhisper(
  plaintext: string,
  sender: LibsignalHarnessDevice,
  recipient: LibsignalHarnessDevice,
): Promise<Signal.SignalMessage> {
  const ciphertext = await Signal.signalEncrypt(
    utf8(plaintext),
    recipient.address,
    sender.address,
    sender.sessionStore,
    sender.identityStore,
  );
  if (ciphertext.type() !== Signal.CiphertextMessageType.Whisper) {
    throw new Error(`expected Whisper message, got type ${ciphertext.type()}`);
  }
  return Signal.SignalMessage.deserialize(ciphertext.serialize());
}

export async function decryptWhisper(
  message: Signal.SignalMessage,
  sender: LibsignalHarnessDevice,
  recipient: LibsignalHarnessDevice,
): Promise<string> {
  const plaintext = await Signal.signalDecrypt(
    message,
    sender.address,
    recipient.address,
    recipient.sessionStore,
    recipient.identityStore,
  );
  return new TextDecoder().decode(plaintext);
}

export function safetyNumber(
  localIdentifier: string,
  localKey: Signal.PublicKey,
  remoteIdentifier: string,
  remoteKey: Signal.PublicKey,
): string {
  return Signal.Fingerprint.new(
    5200,
    1,
    utf8(localIdentifier),
    localKey,
    utf8(remoteIdentifier),
    remoteKey,
  )
    .displayableFingerprint()
    .toString();
}

function addressKey(address: Signal.ProtocolAddress): string {
  return address.toString();
}

function utf8(value: string): Uint8Array<ArrayBuffer> {
  return new TextEncoder().encode(value) as Uint8Array<ArrayBuffer>;
}

function assertText(value: Uint8Array<ArrayBuffer>, expected: string): void {
  const actual = new TextDecoder().decode(value);
  if (actual !== expected) {
    throw new Error(`expected ${expected}, got ${actual}`);
  }
}

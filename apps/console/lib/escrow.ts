/**
 * Browser escrow crypto for app.burnbar.ai — the in-browser half of BurnBar's
 * zero-knowledge model. P-256 ECDH + HKDF-SHA256 + AES-256-GCM, wire-compatible
 * with OpenBurnBarCore/.../CloudVaultCrypto.swift so a vault key wrapped by a
 * trusted native device unwraps here, and content sealed here opens natively.
 *
 * The server NEVER sees the vault key or plaintext. The browser device key pair
 * is a NON-EXTRACTABLE CryptoKey persisted in IndexedDB; the unwrapped vault key
 * lives only in memory (CryptoKey), never serialised. WebAuthn PRF optionally
 * binds device-key usage to a passkey gesture.
 *
 * ── Wire format (must match Swift) ──────────────────────────────────────────
 *  wrapVaultKey output bytes  = ephemeralPub.x963 (65) ‖ aesgcmCombined
 *  aesgcmCombined             = nonce (12) ‖ ciphertext ‖ tag (16)
 *  HKDF                       = SHA-256, salt = ∅, info = "OpenBurnBar-Escrow-v1", 32 bytes
 *  blob envelope              = { schemaVersion, algorithm:"AES-256-GCM", keyVersion,
 *                                 plaintextSHA256(hex), sealedBoxBase64(combined), createdAt }
 *  sealed text                = { algorithm, keyVersion, nonce(b64), ciphertext(b64), tag(b64) }
 */

export const AESGCM_ALGORITHM = "AES-256-GCM";
export const CURRENT_KEY_VERSION = 1;
const ESCROW_HKDF_INFO = "OpenBurnBar-Escrow-v1";
const P256_X963_PUBKEY_LEN = 65; // 0x04 ‖ X(32) ‖ Y(32)
const GCM_NONCE_LEN = 12;
const GCM_TAG_LEN = 16;

const subtle = (): SubtleCrypto => {
  const c = globalThis.crypto;
  if (!c || !c.subtle) {
    throw new EscrowError("unsupported", "WebCrypto SubtleCrypto is unavailable in this context.");
  }
  return c.subtle;
};

export class EscrowError extends Error {
  constructor(
    public readonly code:
      | "unsupported"
      | "invalid_envelope"
      | "invalid_public_key"
      | "invalid_key_length"
      | "hash_mismatch"
      | "indexeddb",
    message: string,
  ) {
    super(message);
    this.name = "EscrowError";
  }
}

// ── Mirror types of the Swift envelopes ─────────────────────────────────────
export interface CloudVaultBlobEnvelope {
  schemaVersion: number;
  algorithm: string;
  keyVersion: number;
  plaintextSHA256: string;
  sealedBoxBase64: string;
  createdAt: string; // ISO
}

export interface CloudVaultSealedText {
  algorithm: string;
  keyVersion: number;
  nonce: string;
  ciphertext: string;
  tag: string;
}

// ── base64 / hex helpers (browser-safe, no Node Buffer) ─────────────────────
export function bytesToBase64(bytes: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}
export function base64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
function bytesToHex(bytes: Uint8Array): string {
  let hex = "";
  for (let i = 0; i < bytes.length; i++) hex += bytes[i].toString(16).padStart(2, "0");
  return hex;
}
function concat(...parts: Uint8Array[]): Uint8Array {
  const total = parts.reduce((n, p) => n + p.length, 0);
  const out = new Uint8Array(total);
  let off = 0;
  for (const p of parts) {
    out.set(p, off);
    off += p.length;
  }
  return out;
}
async function sha256Hex(data: Uint8Array): Promise<string> {
  const digest = await subtle().digest("SHA-256", bufferOf(data));
  return bytesToHex(new Uint8Array(digest));
}

/**
 * Return a tightly-bound, NON-shared ArrayBuffer holding exactly this view's
 * bytes. Copying guarantees a plain `ArrayBuffer` (not `SharedArrayBuffer`) and
 * avoids passing a larger backing buffer to WebCrypto, which would hash/encrypt
 * trailing bytes. Used for every BufferSource handed to SubtleCrypto.
 */
function bufferOf(view: Uint8Array): ArrayBuffer {
  const out = new ArrayBuffer(view.byteLength);
  new Uint8Array(out).set(view);
  return out;
}

/**
 * Like bufferOf but returns a Uint8Array backed by a plain ArrayBuffer, typed as
 * Uint8Array<ArrayBuffer> so it satisfies the strict BufferSource overloads of
 * SubtleCrypto in current lib.dom (iv / salt / info inputs).
 */
function ivOf(view: Uint8Array): Uint8Array<ArrayBuffer> {
  const buf = bufferOf(view);
  return new Uint8Array(buf) as Uint8Array<ArrayBuffer>;
}

// ── HKDF-SHA256 matching CryptoKit's hkdfDerivedSymmetricKey ────────────────
async function hkdfEscrowKey(sharedSecret: ArrayBuffer): Promise<CryptoKey> {
  const ikm = await subtle().importKey("raw", sharedSecret, "HKDF", false, ["deriveKey"]);
  return subtle().deriveKey(
    {
      name: "HKDF",
      hash: "SHA-256",
      salt: new Uint8Array(0),
      info: ivOf(new TextEncoder().encode(ESCROW_HKDF_INFO)),
    },
    ikm,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}

// ── Device key pair (P-256, non-extractable, IndexedDB-persisted) ───────────
const DB_NAME = "burnbar-escrow";
const STORE = "keys";
const DEVICE_KEY_ID = "device-ecdh-p256";

function openDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    if (typeof indexedDB === "undefined") {
      reject(new EscrowError("indexeddb", "IndexedDB is unavailable."));
      return;
    }
    const req = indexedDB.open(DB_NAME, 1);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains(STORE)) db.createObjectStore(STORE);
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(new EscrowError("indexeddb", String(req.error)));
  });
}

function idbGet<T>(db: IDBDatabase, key: string): Promise<T | undefined> {
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, "readonly");
    const req = tx.objectStore(STORE).get(key);
    req.onsuccess = () => resolve(req.result as T | undefined);
    req.onerror = () => reject(new EscrowError("indexeddb", String(req.error)));
  });
}

function idbPut(db: IDBDatabase, key: string, value: unknown): Promise<void> {
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, "readwrite");
    tx.objectStore(STORE).put(value, key);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(new EscrowError("indexeddb", String(tx.error)));
  });
}

/**
 * Load (or create) the browser's non-extractable P-256 device key pair. The
 * CryptoKeyPair is stored in IndexedDB by reference — the private key is never
 * exportable, so no key material ever touches JS memory or the network.
 */
export async function getOrCreateDeviceKeyPair(): Promise<CryptoKeyPair> {
  const db = await openDb();
  const existing = await idbGet<CryptoKeyPair>(db, DEVICE_KEY_ID);
  if (existing?.privateKey && existing?.publicKey) return existing;
  const pair = await subtle().generateKey(
    { name: "ECDH", namedCurve: "P-256" },
    false, // non-extractable private key
    ["deriveBits"],
  );
  await idbPut(db, DEVICE_KEY_ID, pair);
  return pair;
}

/** Export the device public key as a JWK (sent to registerBrowserEscrowDevice). */
export async function exportDevicePublicJwk(pair: CryptoKeyPair): Promise<JsonWebKey> {
  return subtle().exportKey("jwk", pair.publicKey);
}

/**
 * Export the device public key as raw X9.63 (uncompressed, 65 bytes) so native
 * devices can wrap to it via P256.KeyAgreement.PublicKey(x963Representation:).
 */
export async function exportDevicePublicX963(pair: CryptoKeyPair): Promise<Uint8Array> {
  const raw = new Uint8Array(await subtle().exportKey("raw", pair.publicKey));
  if (raw.length !== P256_X963_PUBKEY_LEN || raw[0] !== 0x04) {
    throw new EscrowError("invalid_public_key", "Expected uncompressed P-256 public key (65 bytes).");
  }
  return raw;
}

// ── Vault-key wrap / unwrap (wire-compatible with Swift) ────────────────────

/** ECDH shared secret bytes between an ephemeral/our private and a peer public. */
async function deriveSharedSecret(
  privateKey: CryptoKey,
  peerPublicKey: CryptoKey,
): Promise<ArrayBuffer> {
  // P-256 ECDH outputs 256 bits = 32 bytes (the X coordinate), matching CryptoKit.
  return subtle().deriveBits({ name: "ECDH", public: peerPublicKey }, privateKey, 256);
}

async function importPeerPublicX963(x963: Uint8Array): Promise<CryptoKey> {
  if (x963.length !== P256_X963_PUBKEY_LEN || x963[0] !== 0x04) {
    throw new EscrowError("invalid_public_key", "Peer public key must be uncompressed P-256 (65 bytes).");
  }
  return subtle().importKey("raw", bufferOf(x963), { name: "ECDH", namedCurve: "P-256" }, false, []);
}

/**
 * Wrap a 32-byte vault key for a recipient's X9.63 public key. Output bytes match
 * Swift wrapVaultKey exactly: ephemeralPub.x963 (65) ‖ AES-GCM combined.
 */
export async function wrapVaultKey(
  vaultKey: Uint8Array,
  recipientPublicX963: Uint8Array,
): Promise<Uint8Array> {
  if (vaultKey.length !== 32) {
    throw new EscrowError("invalid_key_length", "Vault keys must be 32 bytes.");
  }
  const recipient = await importPeerPublicX963(recipientPublicX963);
  const ephemeral = await subtle().generateKey(
    { name: "ECDH", namedCurve: "P-256" },
    true,
    ["deriveBits"],
  );
  const shared = await deriveSharedSecret(ephemeral.privateKey, recipient);
  const wrappingKey = await hkdfEscrowKey(shared);

  const nonce = globalThis.crypto.getRandomValues(new Uint8Array(GCM_NONCE_LEN));
  const sealed = new Uint8Array(
    await subtle().encrypt(
      { name: "AES-GCM", iv: ivOf(nonce), tagLength: GCM_TAG_LEN * 8 },
      wrappingKey,
      bufferOf(vaultKey),
    ),
  );
  // WebCrypto returns ciphertext‖tag; CryptoKit `.combined` is nonce‖ciphertext‖tag.
  const combined = concat(nonce, sealed);
  const ephemeralPub = new Uint8Array(await subtle().exportKey("raw", ephemeral.publicKey));
  return concat(ephemeralPub, combined);
}

/**
 * Unwrap a wrapped vault key with our device private key. Accepts the exact byte
 * layout Swift produces. Returns the 32-byte vault key as a CryptoKey usable for
 * AES-GCM decrypt (non-extractable, in-memory only).
 */
export async function unwrapVaultKey(
  wrapped: Uint8Array,
  devicePrivateKey: CryptoKey,
): Promise<CryptoKey> {
  if (wrapped.length <= P256_X963_PUBKEY_LEN) {
    throw new EscrowError("invalid_envelope", "Wrapped vault key is too short.");
  }
  const ephemeralPub = wrapped.subarray(0, P256_X963_PUBKEY_LEN);
  const combined = wrapped.subarray(P256_X963_PUBKEY_LEN);
  if (combined.length <= GCM_NONCE_LEN + GCM_TAG_LEN) {
    throw new EscrowError("invalid_envelope", "Wrapped sealed box is too short.");
  }
  const peer = await importPeerPublicX963(ephemeralPub);
  const shared = await deriveSharedSecret(devicePrivateKey, peer);
  const wrappingKey = await hkdfEscrowKey(shared);

  const nonce = combined.subarray(0, GCM_NONCE_LEN);
  const ctAndTag = combined.subarray(GCM_NONCE_LEN);
  let raw: Uint8Array;
  try {
    raw = new Uint8Array(
      await subtle().decrypt(
        { name: "AES-GCM", iv: ivOf(nonce), tagLength: GCM_TAG_LEN * 8 },
        wrappingKey,
        bufferOf(ctAndTag),
      ),
    );
  } catch {
    throw new EscrowError("invalid_envelope", "Failed to unwrap vault key (auth tag mismatch).");
  }
  if (raw.length !== 32) {
    throw new EscrowError("invalid_key_length", "Unwrapped vault key must be 32 bytes.");
  }
  return importVaultKey(raw);
}

/** Import 32 raw bytes as a non-extractable AES-256-GCM CryptoKey (in-memory). */
export async function importVaultKey(raw: Uint8Array): Promise<CryptoKey> {
  if (raw.length !== 32) {
    throw new EscrowError("invalid_key_length", "Vault keys must be 32 bytes.");
  }
  return subtle().importKey("raw", bufferOf(raw), { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
}

// ── Sealed blob (matches CloudVaultBlobEnvelope) ────────────────────────────
export async function sealBlob(
  data: Uint8Array,
  vaultKey: CryptoKey,
  keyVersion = CURRENT_KEY_VERSION,
): Promise<CloudVaultBlobEnvelope> {
  const nonce = globalThis.crypto.getRandomValues(new Uint8Array(GCM_NONCE_LEN));
  const sealed = new Uint8Array(
    await subtle().encrypt(
      { name: "AES-GCM", iv: ivOf(nonce), tagLength: GCM_TAG_LEN * 8 },
      vaultKey,
      bufferOf(data),
    ),
  );
  return {
    schemaVersion: 1,
    algorithm: AESGCM_ALGORITHM,
    keyVersion,
    plaintextSHA256: await sha256Hex(data),
    sealedBoxBase64: bytesToBase64(concat(nonce, sealed)),
    createdAt: new Date().toISOString(),
  };
}

export async function openBlob(
  envelope: CloudVaultBlobEnvelope,
  vaultKey: CryptoKey,
): Promise<Uint8Array> {
  const combined = base64ToBytes(envelope.sealedBoxBase64);
  if (combined.length <= GCM_NONCE_LEN + GCM_TAG_LEN) {
    throw new EscrowError("invalid_envelope", "Sealed blob is too short.");
  }
  const nonce = combined.subarray(0, GCM_NONCE_LEN);
  const ctAndTag = combined.subarray(GCM_NONCE_LEN);
  let plaintext: Uint8Array;
  try {
    plaintext = new Uint8Array(
      await subtle().decrypt(
        { name: "AES-GCM", iv: ivOf(nonce), tagLength: GCM_TAG_LEN * 8 },
        vaultKey,
        bufferOf(ctAndTag),
      ),
    );
  } catch {
    throw new EscrowError("invalid_envelope", "Failed to open sealed blob (auth tag mismatch).");
  }
  if ((await sha256Hex(plaintext)) !== envelope.plaintextSHA256) {
    throw new EscrowError("hash_mismatch", "Decrypted blob hash does not match the envelope.");
  }
  return plaintext;
}

// ── Sealed text (matches CloudVaultSealedText) ──────────────────────────────
export async function sealText(
  text: string,
  vaultKey: CryptoKey,
  keyVersion = CURRENT_KEY_VERSION,
): Promise<CloudVaultSealedText> {
  const data = new TextEncoder().encode(text);
  const nonce = globalThis.crypto.getRandomValues(new Uint8Array(GCM_NONCE_LEN));
  const sealed = new Uint8Array(
    await subtle().encrypt(
      { name: "AES-GCM", iv: ivOf(nonce), tagLength: GCM_TAG_LEN * 8 },
      vaultKey,
      bufferOf(data),
    ),
  );
  // CryptoKit exposes nonce/ciphertext/tag separately; WebCrypto returns ct‖tag.
  const ciphertext = sealed.subarray(0, sealed.length - GCM_TAG_LEN);
  const tag = sealed.subarray(sealed.length - GCM_TAG_LEN);
  return {
    algorithm: AESGCM_ALGORITHM,
    keyVersion,
    nonce: bytesToBase64(nonce),
    ciphertext: bytesToBase64(ciphertext),
    tag: bytesToBase64(tag),
  };
}

export async function openText(
  envelope: CloudVaultSealedText,
  vaultKey: CryptoKey,
): Promise<string> {
  if (envelope.algorithm !== AESGCM_ALGORITHM) {
    throw new EscrowError("invalid_envelope", "Unsupported sealed-text algorithm.");
  }
  const nonce = base64ToBytes(envelope.nonce);
  const ctAndTag = concat(base64ToBytes(envelope.ciphertext), base64ToBytes(envelope.tag));
  let plaintext: Uint8Array;
  try {
    plaintext = new Uint8Array(
      await subtle().decrypt(
        { name: "AES-GCM", iv: ivOf(nonce), tagLength: GCM_TAG_LEN * 8 },
        vaultKey,
        bufferOf(ctAndTag),
      ),
    );
  } catch {
    throw new EscrowError("invalid_envelope", "Failed to open sealed text (auth tag mismatch).");
  }
  return new TextDecoder().decode(plaintext);
}

// ── WebAuthn PRF binding ────────────────────────────────────────────────────
/**
 * Returns true when the current credential/get exposes the WebAuthn PRF
 * extension, which we use to bind device-key usage to a passkey gesture. The
 * 32-byte PRF output can additionally salt the HKDF info in higher-assurance
 * deployments; the default wire format above stays Swift-compatible.
 */
export function webAuthnPrfSupported(): boolean {
  return (
    typeof PublicKeyCredential !== "undefined" &&
    typeof navigator !== "undefined" &&
    !!navigator.credentials
  );
}

/**
 * Request a WebAuthn PRF-derived secret for the given credential. The salt binds
 * the derived secret to this app + the device key. Returns the raw PRF bytes, or
 * null when PRF is unavailable (the escrow flow then proceeds without the extra
 * gesture binding).
 */
export async function deriveWebAuthnPrfSecret(
  rpId: string,
  allowCredentialIds: Uint8Array[],
  saltLabel = "burnbar-escrow-prf-v1",
): Promise<Uint8Array | null> {
  if (!webAuthnPrfSupported()) return null;
  const salt = await sha256BytesOf(saltLabel);
  const assertion = (await navigator.credentials.get({
    publicKey: {
      challenge: globalThis.crypto.getRandomValues(new Uint8Array(32)),
      rpId,
      timeout: 60_000,
      userVerification: "required",
      allowCredentials: allowCredentialIds.map((id) => ({
        type: "public-key",
        id: bufferOf(id),
      })),
      extensions: { prf: { eval: { first: bufferOf(salt) } } },
    } as PublicKeyCredentialRequestOptions,
  })) as PublicKeyCredential | null;
  const results = (
    assertion?.getClientExtensionResults() as {
      prf?: { results?: { first?: ArrayBuffer } };
    }
  )?.prf?.results?.first;
  return results ? new Uint8Array(results) : null;
}

async function sha256BytesOf(text: string): Promise<Uint8Array> {
  const digest = await subtle().digest("SHA-256", bufferOf(new TextEncoder().encode(text)));
  return new Uint8Array(digest);
}

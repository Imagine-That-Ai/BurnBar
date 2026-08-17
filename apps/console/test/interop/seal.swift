// Cross-language interop fixture generator. Reproduces the exact wire format of
// OpenBurnBarCore/.../CloudVaultCrypto.swift (HKDF info "OpenBurnBar-Escrow-v1",
// x963 ephemeral pubkey ‖ AES-GCM .combined) so the JS escrow lib can prove it
// opens Swift-sealed content and unwraps a Swift-wrapped vault key.
//
// Usage: swift seal.swift  -> prints a JSON fixture to stdout.
import CryptoKit
import Foundation

func b64(_ d: Data) -> String { d.base64EncodedString() }

let vaultKey = SymmetricKey(size: .bits256)
let vaultKeyData = vaultKey.withUnsafeBytes { Data($0) }

let aadPrefix = "OpenBurnBar-CloudVault-aad-v2"
let blobAAD = "\(aadPrefix)|console-user|project_memory_snapshots|pm_console_fixture|sealedSnapshot|2|sealedSnapshot"
let textAAD = "\(aadPrefix)|console-user|cloud_search_documents|console_fixture_doc|sealedTitle|2|sealedTitle"

// Pensieve knowledge chunk (RR-8 path-bound), matching PensieveKnowledgeChunker:
// collection "cloud_search_knowledge", docId = vectorId (the dedupHash), field
// "sealedCiphertext". CloudVaultAADContext defaults `purpose` to `field`.
let chunkUID = "console-user"
let chunkVectorID = "b7f1c3d5e90a4c2fa1806d4e5f2b39c8"
let chunkField = "sealedCiphertext"
let chunkAAD = "\(aadPrefix)|\(chunkUID)|cloud_search_knowledge|\(chunkVectorID)|\(chunkField)|2|\(chunkField)"

func cloudVaultHMAC(_ data: Data, purpose: String) -> String {
    let key = HKDF<SHA256>.deriveKey(
        inputKeyMaterial: vaultKey,
        salt: Data("OpenBurnBar-CloudVault-HMAC-Salt-v1".utf8),
        info: Data("OpenBurnBar-CloudVault-HMAC-v1|\(purpose)".utf8),
        outputByteCount: 32
    )
    let mac = HMAC<SHA256>.authenticationCode(for: data, using: key)
    return Data(mac).map { String(format: "%02x", $0) }.joined()
}

// 1) Seal a blob exactly like CloudVaultCrypto.sealBlob v2 (.combined = nonce‖ct‖tag).
let plaintext = "Swift sealed this for the browser".data(using: .utf8)!
let sealed = try AES.GCM.seal(plaintext, using: vaultKey, authenticating: Data(blobAAD.utf8))
let blobCombined = sealed.combined!
let plaintextHMAC = cloudVaultHMAC(plaintext, purpose: "blob-integrity")

// 2) Seal text like CloudVaultCrypto.sealText v2 (separate nonce/ciphertext/tag).
let textPlain = "conversation body from swift".data(using: .utf8)!
let sealedText = try AES.GCM.seal(textPlain, using: vaultKey, authenticating: Data(textAAD.utf8))
let nonceData = sealedText.nonce.withUnsafeBytes { Data($0) }

// 2b) Seal a knowledge chunk the way PensieveKnowledgeChunker.prepareBatch does
// with a uid present (path-bound v2), and the way it does WITHOUT one (the daemon
// queue writer has no auth session -> legacy schemaVersion-1, no AAD at all).
let chunkPlain = "Pensieve remembers: the vault key never leaves the device.".data(using: .utf8)!
let sealedChunk = try AES.GCM.seal(chunkPlain, using: vaultKey, authenticating: Data(chunkAAD.utf8))
let chunkNonce = sealedChunk.nonce.withUnsafeBytes { Data($0) }

let legacyChunkPlain = "Daemon-sealed chunk with no uid binding.".data(using: .utf8)!
let sealedLegacyChunk = try AES.GCM.seal(legacyChunkPlain, using: vaultKey)
let legacyChunkNonce = sealedLegacyChunk.nonce.withUnsafeBytes { Data($0) }

// 3) Recipient (the browser's device key) — generated here as JS will import it.
let recipientPriv = P256.KeyAgreement.PrivateKey()
let recipientPubX963 = recipientPriv.publicKey.x963Representation
let recipientPrivPKCS8 = recipientPriv.derRepresentation // PKCS#8 DER, importable by WebCrypto

// 4) Wrap the vault key for the recipient, exactly like CloudVaultCrypto.wrapVaultKey.
let ephemeral = P256.KeyAgreement.PrivateKey()
let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipientPriv.publicKey)
let wrappingKey = shared.hkdfDerivedSymmetricKey(
    using: SHA256.self,
    salt: Data(),
    sharedInfo: Data("OpenBurnBar-Escrow-v1".utf8),
    outputByteCount: 32
)
let wrappedSealed = try AES.GCM.seal(vaultKeyData, using: wrappingKey)
let wrapped = ephemeral.publicKey.x963Representation + wrappedSealed.combined!

let fixture: [String: Any] = [
    "vaultKeyB64": b64(vaultKeyData),
    "blob": [
        "schemaVersion": 2,
        "algorithm": "AES-256-GCM",
        "keyVersion": 1,
        "plaintextHMAC": plaintextHMAC,
        "integrityHashVersion": 1,
        "sealedBoxBase64": b64(blobCombined),
        "createdAt": ISO8601DateFormatter().string(from: Date()),
        "aad": blobAAD,
        "expectedPlaintext": "Swift sealed this for the browser"
    ],
    "text": [
        "schemaVersion": 2,
        "algorithm": "AES-256-GCM",
        "keyVersion": 1,
        "nonce": b64(nonceData),
        "ciphertext": b64(sealedText.ciphertext),
        "tag": b64(sealedText.tag),
        "aad": textAAD,
        "expectedPlaintext": "conversation body from swift"
    ],
    // The chunk's binding coordinates are emitted as COMPONENTS (not just the
    // joined `aad` string) so the TS test rebuilds the context the way the console
    // must at recall time — echoing `aad` back would prove nothing.
    "knowledgeChunk": [
        "schemaVersion": 2,
        "algorithm": "AES-256-GCM",
        "keyVersion": 1,
        "nonce": b64(chunkNonce),
        "ciphertext": b64(sealedChunk.ciphertext),
        "tag": b64(sealedChunk.tag),
        "aad": chunkAAD,
        "uid": chunkUID,
        "vectorId": chunkVectorID,
        "field": chunkField,
        "expectedPlaintext": String(decoding: chunkPlain, as: UTF8.self)
    ],
    // No schemaVersion / no aad — exactly what sealText emits for aadContext: nil.
    "legacyKnowledgeChunk": [
        "algorithm": "AES-256-GCM",
        "keyVersion": 1,
        "nonce": b64(legacyChunkNonce),
        "ciphertext": b64(sealedLegacyChunk.ciphertext),
        "tag": b64(sealedLegacyChunk.tag),
        "uid": chunkUID,
        "vectorId": "5c2e0918aa734bd6b0f4e73c1d8a6f20",
        "expectedPlaintext": String(decoding: legacyChunkPlain, as: UTF8.self)
    ],
    "recipientPrivatePKCS8B64": b64(recipientPrivPKCS8),
    "recipientPublicX963B64": b64(recipientPubX963),
    "wrappedVaultKeyB64": b64(wrapped)
]

let json = try JSONSerialization.data(withJSONObject: fixture, options: [.prettyPrinted])
FileHandle.standardOutput.write(json)

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
    "recipientPrivatePKCS8B64": b64(recipientPrivPKCS8),
    "recipientPublicX963B64": b64(recipientPubX963),
    "wrappedVaultKeyB64": b64(wrapped)
]

let json = try JSONSerialization.data(withJSONObject: fixture, options: [.prettyPrinted])
FileHandle.standardOutput.write(json)

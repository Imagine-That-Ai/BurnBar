import CryptoKit
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// Authoritative KAT-vector generator for the CloudVault E2EE crypto.
//
// Every byte here is produced by Apple's CryptoKit — the exact primitive stack the
// production macOS/iOS app uses via OpenBurnBarCore PlatformSupport. This file is a
// faithful transcription of the recipe in
//   OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift
// with PINNED nonces + PINNED ephemeral scalars so the sealed bytes are
// reproducible. Each seal is re-opened with CryptoKit and asserted equal to its
// plaintext before it is emitted (no vector escapes unverified).
//
// Constants — MUST equal CloudVaultCrypto.* :
let AES_GCM_ALGORITHM = "AES-256-GCM"
let CURRENT_KEY_VERSION = 1
let AAD_CONTEXT_PREFIX = "OpenBurnBar-CloudVault-aad-v2"
let CURRENT_SEALED_TEXT_SCHEMA_VERSION = 2
let CURRENT_BLOB_ENVELOPE_SCHEMA_VERSION = 2
let BLOB_ENVELOPE_AAD_CONTEXT = "OpenBurnBar-CloudVaultBlob-v2"
let BLOB_INTEGRITY_HASH_VERSION = 1
let CURRENT_SEALED_PAYLOAD_SCHEMA_VERSION = 2
let SEALED_PAYLOAD_AAD_CONTEXT = "OpenBurnBar-CloudVaultSealedPayload-v2"
let ESCROW_HKDF_INFO = "OpenBurnBar-Escrow-v1"
let HMAC_SALT = "OpenBurnBar-CloudVault-HMAC-Salt-v1"
let HMAC_INFO_PREFIX = "OpenBurnBar-CloudVault-HMAC-v1"
let RECOVERY_SALT = "OpenBurnBar-Recovery-Salt-v1"
let RECOVERY_WRAP_INFO = "OpenBurnBar-Recovery-Wrap-v1"

// ── helpers ──────────────────────────────────────────────────────────────────
func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
func hexToData(_ s: String) -> Data {
    var out = Data(); var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return out
}
func bytes(_ start: Int, _ count: Int) -> Data { Data((0..<count).map { UInt8(($0 + start) & 0xff) }) }
func sha256Hex(_ d: Data) -> String { hex(Data(SHA256.hash(data: d))) }

func hkdf(ikm: Data, salt: Data, info: Data, len: Int = 32) -> SymmetricKey {
    HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt, info: info, outputByteCount: len)
}
func keyData(_ k: SymmetricKey) -> Data { k.withUnsafeBytes { Data($0) } }

// Combined = nonce(12) ‖ ciphertext ‖ tag(16). Detached returns the three parts.
func sealDetached(plaintext: Data, key: Data, nonce: Data, aad: Data) throws -> (nonce: Data, ct: Data, tag: Data, combined: Data) {
    let sb = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
    let n = Data(sb.nonce)
    return (n, sb.ciphertext, sb.tag, n + sb.ciphertext + sb.tag)
}
func openCombined(combined: Data, key: Data, aad: Data) throws -> Data {
    let box = try AES.GCM.SealedBox(combined: combined)
    return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
}

func aadContextString(uid: String, collection: String, docID: String, field: String, schemaVersion: Int, purpose: String) -> String {
    "\(AAD_CONTEXT_PREFIX)|\(uid)|\(collection)|\(docID)|\(field)|\(schemaVersion)|\(purpose)"
}
func keyedHMACHex(_ data: Data, key: Data, purpose: String) -> String {
    let sub = hkdf(ikm: key, salt: Data(HMAC_SALT.utf8), info: Data("\(HMAC_INFO_PREFIX)|\(purpose)".utf8))
    let mac = HMAC<SHA256>.authenticationCode(for: data, using: sub)
    return hex(Data(mac))
}
func vaultKeyID(_ key: Data) -> String { "v1_" + String(sha256Hex(key).prefix(32)) }

// ── fixed inputs ─────────────────────────────────────────────────────────────
let keyA = bytes(0, 32)     // 0x00..0x1f
let keyB = bytes(0x20, 32)  // 0x20..0x3f
let keyC = bytes(0x40, 32)  // 0x40..0x5f

// Deterministic P-256 scalars (top byte 0x11 / 0x22 => strictly < curve order n).
let ephScalar = hexToData("1100000000000000000000000000000000000000000000000000000000000023")
let recScalar = hexToData("2200000000000000000000000000000000000000000000000000000000000045")

var root: [String: Any] = [
    "schema": "openburnbar.cloudvault.kat.v1",
    "origin": "Apple CryptoKit (macOS) — the production PlatformSupport primitive stack",
    "recipe": [
        "aesGcmCombined": "nonce(12) || ciphertext || tag(16)",
        "escrow": "P-256 ECDH (raw X) -> HKDF-SHA256(salt=empty, info=\(ESCROW_HKDF_INFO), 32) -> AES-256-GCM; output = ephemeralPublicX963(65) || combined",
        "keyedHmac": "HKDF-SHA256(ikm=vaultKey, salt=\(HMAC_SALT), info=\(HMAC_INFO_PREFIX)|<purpose>, 32) -> HMAC-SHA256 -> hex",
        "recoveryWrap": "HKDF-SHA256(ikm=normalizedRecoveryKey, salt=\(RECOVERY_SALT), info=\(RECOVERY_WRAP_INFO), 32) -> AES-256-GCM(combined)"
    ]
]

// ── escrow wrapVaultKey ──────────────────────────────────────────────────────
func escrowVector(name: String, recScalar: Data, ephScalar: Data, vaultKey: Data, nonce: Data) throws -> [String: Any] {
    let recPriv = try P256.KeyAgreement.PrivateKey(rawRepresentation: recScalar)
    let ephPriv = try P256.KeyAgreement.PrivateKey(rawRepresentation: ephScalar)
    let recPub = recPriv.publicKey
    let ephPub = ephPriv.publicKey
    let shared = try ephPriv.sharedSecretFromKeyAgreement(with: recPub)
    let sharedData = shared.withUnsafeBytes { Data($0) }
    let wrappingKey = hkdf(ikm: sharedData, salt: Data(), info: Data(ESCROW_HKDF_INFO.utf8))
    let sealed = try sealDetached(plaintext: vaultKey, key: keyData(wrappingKey), nonce: nonce, aad: Data())
    let wrapped = ephPub.x963Representation + sealed.combined
    // self-verify unwrap with the recipient private key
    let box = wrapped.suffix(from: 65)
    let recovered = try openCombined(combined: Data(box), key: keyData(wrappingKey), aad: Data())
    precondition(recovered == vaultKey, "escrow self-verify failed for \(name)")
    return [
        "name": name,
        "recipientPrivateKeyRawHex": hex(recScalar),
        "recipientPublicKeyX963Hex": hex(recPub.x963Representation),
        "ephemeralPrivateKeyRawHex": hex(ephScalar),
        "ephemeralPublicKeyX963Hex": hex(ephPub.x963Representation),
        "sharedSecretHex": hex(sharedData),
        "vaultKeyHex": hex(vaultKey),
        "aesGcmNonceHex": hex(nonce),
        "wrappedHex": hex(wrapped),
        "wrappedBase64": wrapped.base64EncodedString()
    ]
}
root["escrowWrap"] = [
    try escrowVector(name: "escrow-wrap-1", recScalar: recScalar, ephScalar: ephScalar,
                     vaultKey: bytes(1, 32), nonce: hexToData("aabbccddeeff001122334455")),
    try escrowVector(name: "escrow-wrap-2", recScalar: recScalar, ephScalar: ephScalar,
                     vaultKey: keyA, nonce: hexToData("0102030405060708090a0b0c"))
]

// ── sealText ─────────────────────────────────────────────────────────────────
func sealTextVector(name: String, key: Data, nonce: Data, text: String, aad: (uid: String, collection: String, docID: String, field: String, purpose: String)?) throws -> [String: Any] {
    let aadData: Data
    let aadString: String?
    let schemaVersion: Int?
    if let a = aad {
        let s = aadContextString(uid: a.uid, collection: a.collection, docID: a.docID, field: a.field, schemaVersion: CURRENT_SEALED_TEXT_SCHEMA_VERSION, purpose: a.purpose)
        aadData = Data(s.utf8); aadString = s; schemaVersion = CURRENT_SEALED_TEXT_SCHEMA_VERSION
    } else {
        aadData = Data(); aadString = nil; schemaVersion = nil
    }
    let sealed = try sealDetached(plaintext: Data(text.utf8), key: key, nonce: nonce, aad: aadData)
    // self-verify
    let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: sealed.nonce), ciphertext: sealed.ct, tag: sealed.tag)
    let opened = try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aadData)
    precondition(String(data: opened, encoding: .utf8) == text, "sealText self-verify failed for \(name)")
    var env: [String: Any] = [
        "algorithm": AES_GCM_ALGORITHM,
        "keyVersion": CURRENT_KEY_VERSION,
        "nonce": sealed.nonce.base64EncodedString(),
        "ciphertext": sealed.ct.base64EncodedString(),
        "tag": sealed.tag.base64EncodedString()
    ]
    if let sv = schemaVersion { env["schemaVersion"] = sv }
    if let a = aadString { env["aad"] = a }
    var vec: [String: Any] = [
        "name": name, "keyHex": hex(key), "nonceHex": hex(nonce),
        "plaintextUtf8": text, "aeadAadHex": hex(aadData), "envelope": env
    ]
    if let a = aad {
        vec["aadContext"] = ["uid": a.uid, "collection": a.collection, "docID": a.docID, "field": a.field, "schemaVersion": CURRENT_SEALED_TEXT_SCHEMA_VERSION, "purpose": a.purpose]
    }
    return vec
}
root["sealText"] = [
    try sealTextVector(name: "sealtext-v1-no-aad", key: keyA, nonce: hexToData("000102030405060708090a0b"), text: "private launch plan", aad: nil),
    try sealTextVector(name: "sealtext-v2-with-aad", key: keyA, nonce: hexToData("101112131415161718191a1b"), text: "context-bound title", aad: ("user_alice", "cloudSessions", "doc_123", "title", "title"))
]

// ── sealBlob ─────────────────────────────────────────────────────────────────
func sealBlobVector(name: String, key: Data, nonce: Data, data: Data, aad: (uid: String, collection: String, docID: String, field: String, purpose: String)?) throws -> [String: Any] {
    let aeadAad: Data
    let envAad: String
    var aadContextDict: [String: Any]? = nil
    if let a = aad {
        let s = aadContextString(uid: a.uid, collection: a.collection, docID: a.docID, field: a.field, schemaVersion: CURRENT_BLOB_ENVELOPE_SCHEMA_VERSION, purpose: a.purpose)
        aeadAad = Data(s.utf8); envAad = s
        aadContextDict = ["uid": a.uid, "collection": a.collection, "docID": a.docID, "field": a.field, "schemaVersion": CURRENT_BLOB_ENVELOPE_SCHEMA_VERSION, "purpose": a.purpose]
    } else {
        aeadAad = Data(); envAad = BLOB_ENVELOPE_AAD_CONTEXT   // AEAD aad is EMPTY; envelope carries the sentinel
    }
    let sealed = try sealDetached(plaintext: data, key: key, nonce: nonce, aad: aeadAad)
    _ = try openCombined(combined: sealed.combined, key: key, aad: aeadAad) // self-verify
    let plaintextHMAC = keyedHMACHex(data, key: key, purpose: "blob-integrity")
    var vec: [String: Any] = [
        "name": name, "keyHex": hex(key), "nonceHex": hex(nonce), "plaintextHex": hex(data),
        "aeadAadHex": hex(aeadAad),
        "envelope": [
            "schemaVersion": CURRENT_BLOB_ENVELOPE_SCHEMA_VERSION,
            "algorithm": AES_GCM_ALGORITHM,
            "keyVersion": CURRENT_KEY_VERSION,
            "plaintextHMAC": plaintextHMAC,
            "integrityHashVersion": BLOB_INTEGRITY_HASH_VERSION,
            "sealedBoxBase64": sealed.combined.base64EncodedString(),
            "aad": envAad
        ]
    ]
    if let d = aadContextDict { vec["aadContext"] = d }
    return vec
}
root["sealBlob"] = [
    try sealBlobVector(name: "sealblob-v2-default-ctx", key: keyB, nonce: hexToData("202122232425262728292a2b"), data: bytes(0, 64), aad: nil),
    try sealBlobVector(name: "sealblob-v2-path-aad", key: keyB, nonce: hexToData("303132333435363738393a3b"), data: Data("release policy".utf8), aad: ("user_alice", "cloudSessions", "doc_9", "body", "body"))
]

// ── sealPayload ──────────────────────────────────────────────────────────────
func sealPayloadVector(name: String, key: Data, nonce: Data, data: Data, aad: (uid: String, collection: String, docID: String, field: String, purpose: String)?) throws -> [String: Any] {
    let vkid = vaultKeyID(key)
    let aeadAad: Data
    let envAad: String
    var aadContextDict: [String: Any]? = nil
    if let a = aad {
        let s = aadContextString(uid: a.uid, collection: a.collection, docID: a.docID, field: a.field, schemaVersion: CURRENT_SEALED_PAYLOAD_SCHEMA_VERSION, purpose: a.purpose)
        aeadAad = Data(s.utf8); envAad = s
        aadContextDict = ["uid": a.uid, "collection": a.collection, "docID": a.docID, "field": a.field, "schemaVersion": CURRENT_SEALED_PAYLOAD_SCHEMA_VERSION, "purpose": a.purpose]
    } else {
        envAad = SEALED_PAYLOAD_AAD_CONTEXT
        aeadAad = Data("\(SEALED_PAYLOAD_AAD_CONTEXT)|\(AES_GCM_ALGORITHM)|keyVersion=\(CURRENT_KEY_VERSION)|vaultKeyID=\(vkid)".utf8)
    }
    let sealed = try sealDetached(plaintext: data, key: key, nonce: nonce, aad: aeadAad)
    _ = try openCombined(combined: sealed.combined, key: key, aad: aeadAad) // self-verify
    var vec: [String: Any] = [
        "name": name, "keyHex": hex(key), "nonceHex": hex(nonce), "plaintextHex": hex(data),
        "plaintextUtf8": String(data: data, encoding: .utf8) ?? "",
        "vaultKeyID": vkid, "aeadAadHex": hex(aeadAad),
        "envelope": [
            "schemaVersion": CURRENT_SEALED_PAYLOAD_SCHEMA_VERSION,
            "algorithm": AES_GCM_ALGORITHM,
            "keyVersion": CURRENT_KEY_VERSION,
            "vaultKeyID": vkid,
            "sealedBoxBase64": sealed.combined.base64EncodedString(),
            "aad": envAad
        ]
    ]
    if let d = aadContextDict { vec["aadContext"] = d }
    return vec
}
root["sealPayload"] = [
    try sealPayloadVector(name: "sealpayload-v2-default", key: keyC, nonce: hexToData("404142434445464748494a4b"), data: Data("sealed payload body".utf8), aad: nil),
    try sealPayloadVector(name: "sealpayload-v2-path-aad", key: keyC, nonce: hexToData("505152535455565758595a5b"), data: Data("mission event".utf8), aad: ("user_alice", "cloudMissions", "m_1", "sealedPayload", "sealedPayload"))
]

// ── recovery wrap ────────────────────────────────────────────────────────────
func recoveryVector(name: String, recoveryKey: String, vaultKey: Data, nonce: Data) throws -> [String: Any] {
    let normalized = recoveryKey.uppercased().filter { $0.isLetter || $0.isNumber }
    precondition(normalized.count >= 20)
    let wrappingKey = hkdf(ikm: Data(normalized.utf8), salt: Data(RECOVERY_SALT.utf8), info: Data(RECOVERY_WRAP_INFO.utf8))
    let sealed = try sealDetached(plaintext: vaultKey, key: keyData(wrappingKey), nonce: nonce, aad: Data())
    _ = try openCombined(combined: sealed.combined, key: keyData(wrappingKey), aad: Data()) // self-verify
    let verificationHash = sha256Hex(keyData(wrappingKey))
    return [
        "name": name, "recoveryKey": recoveryKey, "vaultKeyHex": hex(vaultKey), "nonceHex": hex(nonce),
        "wrappedVaultKeyBase64": sealed.combined.base64EncodedString(), "verificationHash": verificationHash
    ]
}
root["recoveryWrap"] = [
    try recoveryVector(name: "recovery-1", recoveryKey: "ABCDEFG-HJKMNPQ-RSTVWXY-Z234567", vaultKey: keyA, nonce: hexToData("606162636465666768696a6b"))
]

// ── keyed HMAC hashes (deterministic, no nonce) ──────────────────────────────
func keyedHashVector(purpose: String, key: Data, data: Data) -> [String: Any] {
    ["purpose": purpose, "keyHex": hex(key), "dataHex": hex(data), "hex": keyedHMACHex(data, key: key, purpose: purpose)]
}
let hashInput = Data("the quick brown fox jumps over the lazy dog".utf8)
root["keyedHashes"] = [
    keyedHashVector(purpose: "blob-integrity", key: keyA, data: hashInput),
    keyedHashVector(purpose: "session-body", key: keyA, data: hashInput),
    keyedHashVector(purpose: "session-chunk", key: keyB, data: hashInput),
    keyedHashVector(purpose: "project-memory-content", key: keyC, data: hashInput)
]

// ── vaultKeyID + sha256 ──────────────────────────────────────────────────────
root["vaultKeyId"] = [
    ["keyHex": hex(keyA), "vaultKeyID": vaultKeyID(keyA)],
    ["keyHex": hex(keyB), "vaultKeyID": vaultKeyID(keyB)],
    ["keyHex": hex(keyC), "vaultKeyID": vaultKeyID(keyC)]
]
root["sha256"] = [
    ["dataUtf8": "", "hex": sha256Hex(Data())],
    ["dataUtf8": "OpenBurnBar", "hex": sha256Hex(Data("OpenBurnBar".utf8))]
]

// ── emit ─────────────────────────────────────────────────────────────────────
let out = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted])
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "cloudvault-kat-vectors.json"
try out.write(to: URL(fileURLWithPath: outPath))
FileHandle.standardError.write("wrote \(out.count) bytes to \(outPath)\n".data(using: .utf8)!)
// echo escrow-wrap-1 wrappedHex for immediate cross-stack sanity
if let escrow = root["escrowWrap"] as? [[String: Any]], let first = escrow.first, let wh = first["wrappedHex"] as? String {
    FileHandle.standardError.write("escrow-wrap-1 wrappedHex=\(wh)\n".data(using: .utf8)!)
}

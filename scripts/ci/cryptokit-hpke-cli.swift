// cryptokit-hpke-cli.swift — pure-CryptoKit HPKE seal/open helper (NO libsignal).
//
// One half of the cross-implementation at-rest interop proof (ADR-001 §7.2):
// scripts/ci/generate-cryptokit-interop-vector.mjs drives this binary-free
// Swift script (run with plain `swift scripts/ci/cryptokit-hpke-cli.swift`)
// to seal/open envelopes with Apple CryptoKit only, while the Node side uses
// official libsignal. Suite: X25519-HKDF-SHA256 / HKDF-SHA256 / AES-256-GCM
// (HPKE Base mode) — libsignal's Base_X25519_HkdfSha256_Aes256Gcm.
//
// Protocol: JSON on stdin, JSON on stdout.
//   seal: {"mode":"seal","recipientPubRawB64":<32B>,"plaintextB64":..,"infoB64":..,"aadB64":..}
//         → {"sealedB64": base64(0x01 || enc(32) || ct)}
//   open: {"mode":"open","recipientPrivRawB64":<32B>,"sealedB64":..,"infoB64":..,"aadB64":..}
//         → {"plaintextB64": ...}
// Any failure exits 1 with {"error": "..."} on stdout.

import CryptoKit
import Foundation

struct Request: Decodable {
    let mode: String
    let recipientPubRawB64: String?
    let recipientPrivRawB64: String?
    let plaintextB64: String?
    let sealedB64: String?
    let infoB64: String
    let aadB64: String
}

func fail(_ message: String) -> Never {
    let payload = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()
    FileHandle.standardOutput.write(payload)
    exit(1)
}

func b64(_ s: String, _ what: String) -> Data {
    guard let data = Data(base64Encoded: s) else { fail("invalid base64 for \(what)") }
    return data
}

guard #available(macOS 14.0, *) else { fail("CryptoKit HPKE requires macOS 14+") }

let stdin = FileHandle.standardInput.readDataToEndOfFile()
guard let request = try? JSONDecoder().decode(Request.self, from: stdin) else {
    fail("could not decode request JSON from stdin")
}

let suite = HPKE.Ciphersuite(kem: .Curve25519_HKDF_SHA256, kdf: .HKDF_SHA256, aead: .AES_GCM_256)
let info = b64(request.infoB64, "infoB64")
let aad = b64(request.aadB64, "aadB64")

func emit(_ object: [String: String]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { fail("emit failed") }
    FileHandle.standardOutput.write(data)
}

switch request.mode {
case "seal":
    guard let pubB64 = request.recipientPubRawB64, let ptB64 = request.plaintextB64 else {
        fail("seal needs recipientPubRawB64 + plaintextB64")
    }
    let pubRaw = b64(pubB64, "recipientPubRawB64")
    guard pubRaw.count == 32 else { fail("recipient public key must be 32 raw bytes") }
    let plaintext = b64(ptB64, "plaintextB64")
    do {
        let pub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: pubRaw)
        var sender = try HPKE.Sender(recipientKey: pub, ciphersuite: suite, info: info)
        let ciphertext = try sender.seal(plaintext, authenticating: aad)
        let enc = sender.encapsulatedKey
        guard enc.count == 32 else { fail("unexpected encapsulated key size \(enc.count)") }
        // libsignal Base_X25519_HkdfSha256_Aes256Gcm framing: 0x01 || enc || ct
        var sealed = Data([0x01])
        sealed.append(enc)
        sealed.append(ciphertext)
        emit(["sealedB64": sealed.base64EncodedString()])
    } catch { fail("CryptoKit seal failed: \(error)") }

case "open":
    guard let privB64 = request.recipientPrivRawB64, let sealedB64 = request.sealedB64 else {
        fail("open needs recipientPrivRawB64 + sealedB64")
    }
    let privRaw = b64(privB64, "recipientPrivRawB64")
    let sealed = b64(sealedB64, "sealedB64")
    guard sealed.count > 33, sealed.first == 0x01 else {
        fail("sealed payload must be 0x01 || 32-byte enc || ciphertext")
    }
    let enc = sealed.subdata(in: 1 ..< 33)
    let ciphertext = sealed.subdata(in: 33 ..< sealed.count)
    do {
        let priv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privRaw.suffix(32))
        var recipient = try HPKE.Recipient(
            privateKey: priv, ciphersuite: suite, info: info, encapsulatedKey: enc)
        let plaintext = try recipient.open(ciphertext, authenticating: aad)
        emit(["plaintextB64": plaintext.base64EncodedString()])
    } catch { fail("CryptoKit open failed: \(error)") }

default:
    fail("unknown mode \(request.mode)")
}

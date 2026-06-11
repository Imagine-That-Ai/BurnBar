import CryptoKit
import Foundation

// MARK: - Artifact verification

enum DirectDownloadVerificationError: Error, Equatable {
    case missingPublicKey
    case malformedPublicKey
    case missingSignature
    case malformedSignature
    case lengthMismatch(expected: Int, actual: Int)
    case sha256Mismatch(expected: String, actual: String)
    case signatureInvalid
    case unreadableArtifact(String)
}

extension DirectDownloadVerificationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingPublicKey:
            return "The app bundle does not contain an update signing key (SUPublicEDKey)."
        case .malformedPublicKey:
            return "The bundled update signing key (SUPublicEDKey) is not a valid Ed25519 public key."
        case .missingSignature:
            return "The update feed did not include an Ed25519 signature for the download."
        case .malformedSignature:
            return "The update's Ed25519 signature is not valid base64 or has the wrong size."
        case let .lengthMismatch(expected, actual):
            return "The downloaded file is \(actual) bytes but the feed advertised \(expected) bytes."
        case let .sha256Mismatch(expected, actual):
            return "The downloaded file's SHA-256 digest (\(actual)) does not match the feed (\(expected))."
        case .signatureInvalid:
            return "The downloaded file's Ed25519 signature does not verify against the key this app shipped with."
        case let .unreadableArtifact(reason):
            return "The downloaded file could not be read for verification: \(reason)"
        }
    }
}

/// Verifies a downloaded update artifact against the feed metadata and the
/// Ed25519 public key pinned in Info.plist (`SUPublicEDKey`).
///
/// What is verified, in order, all of which must pass:
/// 1. Exact byte length advertised by the feed.
/// 2. SHA-256 digest of the file bytes equals the feed's `sha256`.
/// 3. Ed25519 signature (`sparkleEdSignature`, produced by Sparkle's
///    `sign_update` over the file bytes) verifies against `SUPublicEDKey`.
struct DirectDownloadArtifactVerifier: Sendable {
    /// Base64 of the raw 32-byte Ed25519 public key (Sparkle `SUPublicEDKey`).
    let publicKeyBase64: String

    static let publicKeyInfoPlistKey = "SUPublicEDKey"

    /// Reads the pinned `SUPublicEDKey` from the bundle, or `nil` when absent.
    /// Callers must fail closed (never offer or open an update) when this is
    /// `nil`.
    static func bundledPublicKeyBase64(in bundle: Bundle = .main) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: publicKeyInfoPlistKey) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func verify(
        fileAt fileURL: URL,
        expectedLength: Int,
        expectedSHA256: String,
        edSignatureBase64: String?
    ) throws {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch {
            throw DirectDownloadVerificationError.unreadableArtifact(String(describing: error))
        }
        try verify(
            data: data,
            expectedLength: expectedLength,
            expectedSHA256: expectedSHA256,
            edSignatureBase64: edSignatureBase64
        )
    }

    func verify(
        data: Data,
        expectedLength: Int,
        expectedSHA256: String,
        edSignatureBase64: String?
    ) throws {
        if expectedLength > 0, data.count != expectedLength {
            throw DirectDownloadVerificationError.lengthMismatch(expected: expectedLength, actual: data.count)
        }

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == expectedSHA256.lowercased() else {
            throw DirectDownloadVerificationError.sha256Mismatch(
                expected: expectedSHA256.lowercased(),
                actual: digest
            )
        }

        guard let signatureBase64 = edSignatureBase64?.trimmingCharacters(in: .whitespacesAndNewlines),
              !signatureBase64.isEmpty else {
            throw DirectDownloadVerificationError.missingSignature
        }
        guard let signature = Data(base64Encoded: signatureBase64), signature.count == 64 else {
            throw DirectDownloadVerificationError.malformedSignature
        }

        let keyBase64 = publicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyBase64.isEmpty else {
            throw DirectDownloadVerificationError.missingPublicKey
        }
        guard let keyData = Data(base64Encoded: keyBase64), keyData.count == 32,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            throw DirectDownloadVerificationError.malformedPublicKey
        }

        guard publicKey.isValidSignature(signature, for: data) else {
            throw DirectDownloadVerificationError.signatureInvalid
        }
    }
}

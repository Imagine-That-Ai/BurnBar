import Foundation
import OpenBurnBarCore

enum BurnBarLinuxAttestationIngressContract {
    static let protocolVersion = 1
    static let attestationKind = "tpm2_ima_signed_verdict_v1"
    static let ticketPrefix = "obbat1_"
    static let ticketIDBytes = 16
    static let ticketSecretBytes = 32
    static let maximumEvidenceBytes = 16 * 1_024 * 1_024
    static let ticketSecretHashDomain = Data("openburnbar.linux.attestation-ticket-secret.v1\0".utf8)
}

enum BurnBarLinuxAttestationIngressContractError: Error, Equatable, Sendable {
    case invalidTicketCredential
    case invalidTicketIssue
    case invalidUploadReservation
    case invalidUploadReceipt
    case invalidEvidence
}

struct BurnBarLinuxAttestationTicketCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let secretHashSHA256: String
    private let secret: SecretStorage

    private final class SecretStorage: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        private let lock = NSLock()
        private var bytes: Data

        var description: String { "<redacted-attestation-ticket-secret>" }
        var debugDescription: String { description }

        init(_ bytes: Data) { self.bytes = bytes }

        deinit { erase() }

        func withBytes<T>(_ body: (Data) throws -> T) throws -> T {
            try lock.withLock {
                guard bytes.count == BurnBarLinuxAttestationIngressContract.ticketSecretBytes else {
                    throw BurnBarLinuxAttestationIngressContractError.invalidTicketCredential
                }
                return try body(bytes)
            }
        }

        func erase() {
            lock.withLock {
                guard bytes.isEmpty == false else { return }
                bytes.resetBytes(in: bytes.startIndex..<bytes.endIndex)
                bytes.removeAll(keepingCapacity: false)
            }
        }
    }

    var description: String { "<redacted-attestation-ticket>" }
    var debugDescription: String { description }

    init(secret: Data) throws {
        guard secret.count == BurnBarLinuxAttestationIngressContract.ticketSecretBytes else {
            throw BurnBarLinuxAttestationIngressContractError.invalidTicketCredential
        }
        self.secret = SecretStorage(secret)
        var hashInput = BurnBarLinuxAttestationIngressContract.ticketSecretHashDomain
        hashInput.append(secret)
        defer { hashInput.resetBytes(in: hashInput.startIndex..<hashInput.endIndex) }
        secretHashSHA256 = PlatformCrypto.sha256Hex(hashInput)
    }

    static func random() throws -> Self {
        try Self(secret: PlatformCrypto.secureRandomBytes(
            count: BurnBarLinuxAttestationIngressContract.ticketSecretBytes
        ))
    }

    func wireValue(ticketID: String) throws -> String {
        guard Self.isCanonicalBase64URL(
            ticketID,
            decodedByteCount: BurnBarLinuxAttestationIngressContract.ticketIDBytes
        ) else {
            throw BurnBarLinuxAttestationIngressContractError.invalidTicketIssue
        }
        return try secret.withBytes {
            BurnBarLinuxAttestationIngressContract.ticketPrefix
                + ticketID
                + "."
                + Self.base64URL($0)
        }
    }

    func erase() { secret.erase() }

    static func isCanonicalIdentifier(_ value: String) -> Bool {
        isCanonicalBase64URL(value, decodedByteCount: BurnBarLinuxAttestationIngressContract.ticketIDBytes)
    }

    private static func base64URL(_ value: Data) -> String {
        value.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func isCanonicalBase64URL(_ value: String, decodedByteCount: Int) -> Bool {
        guard value.isEmpty == false,
              value.utf8.allSatisfy({ byte in
                  (byte >= 0x41 && byte <= 0x5A)
                      || (byte >= 0x61 && byte <= 0x7A)
                      || (byte >= 0x30 && byte <= 0x39)
                      || byte == 0x2D
                      || byte == 0x5F
              }) else {
            return false
        }
        let standard = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let decoded = Data(base64Encoded: standard + padding),
              decoded.count == decodedByteCount else {
            return false
        }
        return base64URL(decoded) == value
    }
}

struct BurnBarLinuxAttestationTicketIssue: Equatable, Sendable {
    let ticketID: String
    let expiresAtMillis: Int64
}

struct BurnBarLinuxAttestationUploadDeclaration: Equatable, Sendable {
    let appID: String
    let deviceID: String
    let challengeID: String
    let releaseDigestSHA256: String
    let expectedSHA256: String
    let expectedSize: Int
}

struct BurnBarLinuxAttestationUploadReservation: Equatable, Sendable {
    let uploadID: String
    let expiresAtMillis: Int64
}

struct BurnBarLinuxAttestationUploadReceipt: Codable, Equatable, Sendable {
    let uploadId: String
    let generation: String
    let sha256: String
    let size: Int
}

protocol BurnBarLinuxAttestationUploadBody: Sendable {
    var byteCount: Int { get }
    var sha256: String { get }
    func makeInputStream() throws -> InputStream
}

struct BurnBarLinuxAttestationDataUploadBody: BurnBarLinuxAttestationUploadBody {
    let data: Data
    let sha256: String

    var byteCount: Int { data.count }

    init(data: Data) throws {
        guard (1...BurnBarLinuxAttestationIngressContract.maximumEvidenceBytes).contains(data.count) else {
            throw BurnBarLinuxAttestationIngressContractError.invalidEvidence
        }
        self.data = data
        sha256 = PlatformCrypto.sha256Hex(data)
    }

    func makeInputStream() throws -> InputStream { InputStream(data: data) }
}

import Foundation

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
@preconcurrency import Crypto
#else
#error("DomainCoreReleaseIdentityReporter requires CryptoKit or Swift Crypto")
#endif

#if canImport(OpenBurnBarDomainCoreFFI)
import OpenBurnBarDomainCoreFFI
#endif

public struct DomainCoreReleaseIdentity: Codable, Equatable, Sendable {
    public let candidateCommit: String
    public let coreVersion: String
    public let abiVersion: UInt32
    public let sourceSha256: String
    public let binarySha256: String
}

public enum DomainCoreReleaseIdentityError: Error, LocalizedError {
    case invalidCandidateCommit
    case unavailableNativeCore
    case invalidSourceFingerprint
    case unsafeExecutable
    case unsafeReportPath

    public var errorDescription: String? {
        switch self {
        case .invalidCandidateCommit:
            "candidate commit must be a lowercase 40-character Git SHA"
        case .unavailableNativeCore:
            "the shared Rust domain core is unavailable"
        case .invalidSourceFingerprint:
            "the loaded shared Rust source fingerprint is invalid"
        case .unsafeExecutable:
            "the process executable must be a regular non-symlink file"
        case .unsafeReportPath:
            "the identity report must be an absent absolute non-symlink path"
        }
    }
}

public enum DomainCoreReleaseIdentityReporter {
    public static let argument = "--domain-core-release-identity-report"

    public static func write(
        candidateCommit: String,
        reportURL: URL,
        executableURL: URL
    ) throws -> DomainCoreReleaseIdentity {
        guard candidateCommit.range(
            of: #"^[0-9a-f]{40}$"#,
            options: .regularExpression
        ) != nil else {
            throw DomainCoreReleaseIdentityError.invalidCandidateCommit
        }

        let executable = executableURL.standardizedFileURL
        let executableValues = try executable.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard executableValues.isRegularFile == true,
              executableValues.isSymbolicLink != true else {
            throw DomainCoreReleaseIdentityError.unsafeExecutable
        }

        let report = reportURL.standardizedFileURL
        guard report.isFileURL,
              report.path.hasPrefix("/"),
              !FileManager.default.fileExists(atPath: report.path) else {
            throw DomainCoreReleaseIdentityError.unsafeReportPath
        }

        #if canImport(OpenBurnBarDomainCoreFFI)
        let sourceSha256 = OpenBurnBarDomainCoreFFI.domainCoreSourceFingerprint()
        guard sourceSha256.range(
            of: #"^[0-9a-f]{64}$"#,
            options: .regularExpression
        ) != nil else {
            throw DomainCoreReleaseIdentityError.invalidSourceFingerprint
        }
        let executableData = try Data(contentsOf: executable, options: .mappedIfSafe)
        let identity = DomainCoreReleaseIdentity(
            candidateCommit: candidateCommit,
            coreVersion: OpenBurnBarDomainCoreFFI.domainCoreVersion(),
            abiVersion: OpenBurnBarDomainCoreFFI.domainCoreAbiVersion(),
            sourceSha256: sourceSha256,
            binarySha256: SHA256.hash(data: executableData)
                .map { String(format: "%02x", $0) }
                .joined()
        )
        var encoded = try JSONEncoder().encode(identity)
        encoded.append(0x0A)
        try encoded.write(to: report, options: .atomic)
        return identity
        #else
        throw DomainCoreReleaseIdentityError.unavailableNativeCore
        #endif
    }
}

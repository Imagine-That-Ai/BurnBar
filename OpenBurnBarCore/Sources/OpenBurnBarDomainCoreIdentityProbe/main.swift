import CryptoKit
import Foundation
import OpenBurnBarDomainCoreFFI

struct ObservedIdentity: Encodable {
    let candidateCommit: String
    let coreVersion: String
    let abiVersion: UInt32
    let sourceSha256: String
    let binarySha256: String
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("domain-core identity probe failed: \(message)\n".utf8))
    exit(1)
}

let environment = ProcessInfo.processInfo.environment
guard let candidateCommit = environment["DOMAIN_CORE_CANDIDATE_COMMIT"],
      candidateCommit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil else {
    fail("DOMAIN_CORE_CANDIDATE_COMMIT must be a lowercase 40-character commit")
}
guard let reportPath = environment["DOMAIN_CORE_OBSERVED_IDENTITY_REPORT"], !reportPath.isEmpty else {
    fail("DOMAIN_CORE_OBSERVED_IDENTITY_REPORT is required")
}
guard let shippedBinaryPath = environment["DOMAIN_CORE_SHIPPED_BINARY"], !shippedBinaryPath.isEmpty else {
    fail("DOMAIN_CORE_SHIPPED_BINARY is required")
}

let shippedBinaryURL = URL(fileURLWithPath: shippedBinaryPath).standardizedFileURL
let shippedBinaryData: Data
do {
    shippedBinaryData = try Data(contentsOf: shippedBinaryURL, options: .mappedIfSafe)
} catch {
    fail("cannot read shipped binary: \(error)")
}
let binarySha256 = SHA256.hash(data: shippedBinaryData).map { String(format: "%02x", $0) }.joined()
let sourceSha256 = OpenBurnBarDomainCoreFFI.domainCoreSourceFingerprint()
guard sourceSha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
    fail("loaded source fingerprint is invalid")
}

let identity = ObservedIdentity(
    candidateCommit: candidateCommit,
    coreVersion: OpenBurnBarDomainCoreFFI.domainCoreVersion(),
    abiVersion: OpenBurnBarDomainCoreFFI.domainCoreAbiVersion(),
    sourceSha256: sourceSha256,
    binarySha256: binarySha256
)
do {
    var encoded = try JSONEncoder().encode(identity)
    encoded.append(0x0A)
    try encoded.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
} catch {
    fail("cannot write observed identity: \(error)")
}

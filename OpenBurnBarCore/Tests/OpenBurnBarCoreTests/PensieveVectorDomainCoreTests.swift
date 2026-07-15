import Foundation
import XCTest
@testable import OpenBurnBarCore

final class PensieveVectorDomainCoreTests: XCTestCase {
    func test_rustAuthority_l2NormalizationMatchesLegacyContract() {
        withCloudVaultMode("rust") {
            let normalized = PensieveVectorCloak.l2normalize([3, 4])
            XCTAssertEqual(normalized, [0.6, 0.8])
            XCTAssertEqual(PensieveVectorCloak.l2normalize([0, 0]), [0, 0])
            XCTAssertEqual(PensieveVectorCloak.l2normalize([]), [])
        }
    }

    func test_nonLegacySourcesDoNotCallDeletedL2Implementation() throws {
        let vectorKitSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/OpenBurnBarVectorKit")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: vectorKitSources,
            includingPropertiesForKeys: nil
        ))
        var offenders: [String] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            guard !fileURL.path.contains("/Legacy/") else { continue }
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            if source.contains("PensieveVectorLegacy.l2normalize") {
                offenders.append(fileURL.path)
            }
        }
        XCTAssertEqual(offenders, [], "The migrated L2 implementation must be deletable outside Legacy/")
    }

    func test_rustAuthority_matchesPublishedGoldenHeads() throws {
        try withCloudVaultMode("rust") {
            var basis = [Double](repeating: 0, count: PensieveVectorCloak.embeddingDim)
            basis[5] = 1
            let result = try PensieveVectorCloak.cloak(
                basis,
                vaultKey: Data(repeating: 0x42, count: 32),
                modelVersion: "hashing-bow-v1"
            )
            let expected = [
                0.024962057620774702,
                -0.0012100986493098734,
                0.01970170194431331,
                -0.01876288243402278,
                0.050834395709711204,
                0.8367944634995997,
            ]
            for (actual, expected) in zip(result, expected) {
                XCTAssertEqual(actual, expected, accuracy: 1e-12)
            }
        }
    }

    private func withCloudVaultMode<T>(_ mode: String, operation: () throws -> T) rethrows -> T {
        let environmentKey = "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE"
        let previous = getenv(environmentKey).map { String(cString: $0) }
        setenv(environmentKey, mode, 1)
        defer {
            if let previous { setenv(environmentKey, previous, 1) } else { unsetenv(environmentKey) }
        }
        return try operation()
    }
}

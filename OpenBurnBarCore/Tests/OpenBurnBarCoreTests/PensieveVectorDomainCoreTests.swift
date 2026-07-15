import Foundation
import XCTest
@testable import OpenBurnBarCore

final class PensieveVectorDomainCoreTests: XCTestCase {
    func test_rustAuthority_matchesPublishedGoldenHeads() throws {
        let environmentKey = "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE"
        let previous = getenv(environmentKey).map { String(cString: $0) }
        setenv(environmentKey, "rust", 1)
        defer {
            if let previous { setenv(environmentKey, previous, 1) } else { unsetenv(environmentKey) }
        }

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

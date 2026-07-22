import OpenBurnBarCore
import XCTest
@testable import OpenBurnBar

final class CloudVaultRotationRewrapWorkerTests: XCTestCase {
    func testCloudSearchChunks_preservesBodyWithinByteLimit() throws {
        let body = "first section second section"

        let chunks = try CloudVaultRotationRewrapWorker.cloudSearchChunks(
            body,
            title: "Rotation title",
            provider: "claude",
            maxBytes: 14
        )

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined(), body)
        XCTAssertTrue(chunks.allSatisfy { $0.utf8.count <= 14 })
    }

    func testCloudSearchChunks_includesTitleAndProviderInMetadataBudget() {
        let nearlyFullTitle = Array(repeating: "metadata", count: 4_094).joined(separator: " ")

        XCTAssertThrowsError(
            try CloudVaultRotationRewrapWorker.cloudSearchChunks(
                "body token",
                title: nearlyFullTitle,
                provider: "provider token",
                maxBytes: 16_000
            )
        ) { error in
            guard case CloudVaultCryptoError.invalidSearchInput = error else {
                return XCTFail("Expected invalidSearchInput, got \(error)")
            }
        }
    }
}

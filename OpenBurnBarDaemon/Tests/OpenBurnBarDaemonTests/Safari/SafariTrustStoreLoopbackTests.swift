import Foundation
import OpenBurnBarKernel
@testable import OpenBurnBarDaemon
import XCTest

final class SafariTrustStoreLoopbackTests: XCTestCase {
    func test_exactHTTPLoopbackOriginIsPersistedAndMaterialized() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("safari-trust-loopback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 1_786_647_600)
        let store = BurnBarSafariTrustStore(
            fileURL: root.appendingPathComponent("trust.json"),
            now: { now }
        )
        let origin = "http://127.0.0.1:42771"
        let response = try await store.update(
            BurnBarSafariTrustUpdateRequest(
                safariSessionId: "session-1",
                origin: origin,
                decision: .allow,
                trustMode: "step"
            )
        )

        XCTAssertEqual(response.origin, origin)
        let policy = try await store.policy(for: "\(origin)/mixed", requestedTrustMode: .step)
        XCTAssertEqual(policy.origin, origin)
        XCTAssertEqual(policy.trustMode, .step)
        XCTAssertEqual(policy.scopeRules.count, 1)
    }

    func test_remoteHTTPAndImpersonatedLoopbackOriginsRemainRejected() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("safari-trust-reject-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = BurnBarSafariTrustStore(
            fileURL: root.appendingPathComponent("trust.json")
        )
        for origin in [
            "http://example.com",
            "http://127.0.0.1.example.com",
            "http://user@127.0.0.1:42771"
        ] {
            await XCTAssertThrowsErrorAsync {
                _ = try await store.update(
                    BurnBarSafariTrustUpdateRequest(
                        safariSessionId: "session-1",
                        origin: origin,
                        decision: .allow,
                        trustMode: "step"
                    )
                )
            }
        }
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        XCTAssertEqual(
            error as? BurnBarSafariTrustStore.StoreError,
            .invalidOrigin,
            file: file,
            line: line
        )
    }
}

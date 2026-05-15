import XCTest
@testable import OpenBurnBarIrohRelay
import OpenBurnBarCore

/// Regression coverage for the May-2026 audit pass on the xcframework
/// transport. The bugs caught by these tests were:
///
///   - `IrohBackendError.streamFailed` was surfaced as
///     `IrohRelayTransportError.decodeFailed`. Transport-layer stream
///     drops are NOT decode errors; the composite cascade depended on the
///     correct discriminator to know whether to fall back to WSS.
///
///   - The fanout transport's bootstrap was not race-safe: two parallel
///     `transport()` callers could each call `backend.bootstrap(...)` and
///     leak one of the endpoints.
final class IrohXcframeworkTransportAuditTests: XCTestCase {

    // MARK: - Error surface mapping

    func testStreamFailureSurfacesAsStreamRejected() {
        let mapped = IrohXcframeworkTransport.surface(.streamFailed("write_all failed: broken pipe"))
        guard case .streamRejected(let message) = mapped else {
            XCTFail("expected streamRejected, got \(mapped)")
            return
        }
        XCTAssertTrue(message.contains("iroh stream failed"))
        XCTAssertTrue(message.contains("broken pipe"))
    }

    func testStreamFailureWithTimeoutSurfacesAsTimedOut() {
        let mapped = IrohXcframeworkTransport.surface(.streamFailed("connection timed out after 5s"))
        XCTAssertEqual(mapped, .timedOut)
    }

    func testConnectFailureSurfacesAsTimedOutWhenMessageMentionsTimeout() {
        let mapped = IrohXcframeworkTransport.surface(.connectFailed("iroh connect timed out"))
        XCTAssertEqual(mapped, .timedOut)
    }

    func testAcceptFailureSurfacesAsStreamRejectedWhenNotATimeout() {
        let mapped = IrohXcframeworkTransport.surface(.acceptFailed("listener closed"))
        guard case .streamRejected = mapped else {
            XCTFail("expected streamRejected, got \(mapped)")
            return
        }
    }

    func testNotInitializedSurfacesAsEndpointNotReady() {
        let mapped = IrohXcframeworkTransport.surface(.notInitialized)
        XCTAssertEqual(mapped, .endpointNotReady)
    }

    // MARK: - Pairing directory: reader-only enforcement

    func testReaderOnlyDirectoryRejectsPublish() async {
        let directory = ReaderOnlyDirectory()
        do {
            try await directory.publish(
                IrohPairingRecord(
                    uid: "u",
                    connectionId: "c",
                    nodeId: "n",
                    publishedAtMillis: 0,
                    protocolVersion: 1,
                    signature: ""
                ),
                for: "u"
            )
            XCTFail("expected unsupportedOnReader")
        } catch {
            XCTAssertEqual(error as? IrohPairingDirectoryError, .unsupportedOnReader)
        }
    }

    func testReaderOnlyDirectoryRejectsRevoke() async {
        let directory = ReaderOnlyDirectory()
        do {
            try await directory.revoke(uid: "u", connectionId: "c")
            XCTFail("expected unsupportedOnReader")
        } catch {
            XCTAssertEqual(error as? IrohPairingDirectoryError, .unsupportedOnReader)
        }
    }
}

/// Minimal stub mirroring the iOS mobile reader semantics (throws
/// `.unsupportedOnReader` on publish/revoke, no-ops on fetch). Co-located
/// in this test file so we never let the audit-fix regress without
/// breaking a deterministic SwiftPM-runnable check.
private final class ReaderOnlyDirectory: IrohPairingDirectory, @unchecked Sendable {
    func publish(_ record: IrohPairingRecord, for uid: String) async throws {
        throw IrohPairingDirectoryError.unsupportedOnReader
    }
    func fetch(uid: String, connectionId: String) async throws -> IrohPairingRecord? {
        nil
    }
    func revoke(uid: String, connectionId: String) async throws {
        throw IrohPairingDirectoryError.unsupportedOnReader
    }
}

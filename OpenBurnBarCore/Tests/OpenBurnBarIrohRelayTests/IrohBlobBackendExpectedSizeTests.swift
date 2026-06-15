import Foundation
import XCTest
@testable import OpenBurnBarIrohRelay

final class IrohBlobBackendExpectedSizeTests: XCTestCase {
    func testDefaultExpectedSizeFetchAllowsExactSize() async throws {
        let destination = tempFileURL()
        let backend = DefaultExpectedSizeBackend(writeBytes: 16, reportedBytes: 16)

        let stats = try await backend.fetchBlob(
            ticketText: "blob1",
            destination: destination.path,
            expectedSizeBytes: 16
        )

        XCTAssertEqual(stats.bytesTotal, 16)
        XCTAssertEqual(backend.fetchCalls, 1)
        XCTAssertEqual(fileSize(destination), 16)
    }

    func testDefaultExpectedSizeFetchAllowsSmallerPayload() async throws {
        let destination = tempFileURL()
        let backend = DefaultExpectedSizeBackend(writeBytes: 4, reportedBytes: 4)

        let stats = try await backend.fetchBlob(
            ticketText: "blob1",
            destination: destination.path,
            expectedSizeBytes: 16
        )

        XCTAssertEqual(stats.bytesTotal, 4)
        XCTAssertEqual(fileSize(destination), 4)
    }

    func testDefaultExpectedSizeFetchRejectsReportedOverrunAndRemovesFile() async throws {
        let destination = tempFileURL()
        let backend = DefaultExpectedSizeBackend(writeBytes: 24, reportedBytes: 24)

        try await assertFetchFails(backend, destination: destination, expectedSizeBytes: 16)

        XCTAssertEqual(backend.fetchCalls, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testDefaultExpectedSizeFetchRejectsDiskOverrunEvenWhenStatsUnderReport() async throws {
        let destination = tempFileURL()
        let backend = DefaultExpectedSizeBackend(writeBytes: 24, reportedBytes: 4)

        try await assertFetchFails(backend, destination: destination, expectedSizeBytes: 16)

        XCTAssertEqual(backend.fetchCalls, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testDefaultExpectedSizeFetchRejectsOverCapBeforeBackendCall() async throws {
        let destination = tempFileURL()
        let backend = DefaultExpectedSizeBackend(writeBytes: 1, reportedBytes: 1)

        try await assertFetchFails(
            backend,
            destination: destination,
            expectedSizeBytes: IrohBlobTransferLimits.maxExpectedFetchBytes + 1
        )

        XCTAssertEqual(backend.fetchCalls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testConcreteExpectedSizeOverrideIsUsedThroughProtocolExistential() async throws {
        let destination = tempFileURL()
        let backend: IrohBlobBackend = ExpectedSizeOverrideBackend()

        let stats = try await backend.fetchBlob(
            ticketText: "blob1",
            destination: destination.path,
            expectedSizeBytes: 9
        )

        XCTAssertEqual(stats.bytesTotal, 9)
        XCTAssertEqual(fileSize(destination), 9)
    }

    private func assertFetchFails(
        _ backend: IrohBlobBackend,
        destination: URL,
        expectedSizeBytes: UInt64
    ) async throws {
        do {
            _ = try await backend.fetchBlob(
                ticketText: "blob1",
                destination: destination.path,
                expectedSizeBytes: expectedSizeBytes
            )
            XCTFail("expected fetch to fail")
        } catch let error as IrohBlobBackendError {
            guard case .fetchFailed = error else {
                XCTFail("expected fetchFailed, got \(error)")
                return
            }
        }
    }

    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("iroh-blob-expected-size-\(UUID().uuidString)")
            .appendingPathExtension("bin")
    }

    private func fileSize(_ url: URL) -> UInt64 {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber
        else {
            return 0
        }
        return size.uint64Value
    }
}

private class DefaultExpectedSizeBackend: IrohBlobBackend, @unchecked Sendable {
    let writeBytes: Int
    let reportedBytes: UInt64
    var fetchCalls = 0

    init(writeBytes: Int, reportedBytes: UInt64) {
        self.writeBytes = writeBytes
        self.reportedBytes = reportedBytes
    }

    func bootstrap(secret: Data, storeDirectoryPath: String, relayURL: String?) async throws -> IrohEndpointIdentity {
        IrohEndpointIdentity(nodeId: "test", rawPublicKey: Data(repeating: 1, count: 32))
    }

    func publishBlob(localPath: String) async throws -> String {
        "blob1"
    }

    func fetchBlob(ticketText: String, destination: String) async throws -> BlobTransferStats {
        fetchCalls += 1
        let url = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0xA5, count: writeBytes).write(to: url)
        return BlobTransferStats(
            bytesTotal: reportedBytes,
            blake3Hash: "fake",
            durationMillis: 1,
            didResume: false
        )
    }

    func fetchBlob(
        ticketText: String,
        destination: String,
        expectedSizeBytes: UInt64
    ) async throws -> BlobTransferStats {
        try IrohBlobTransferLimits.validateExpectedFetchSize(expectedSizeBytes)
        fetchCalls += 1
        let url = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0xA5, count: writeBytes).write(to: url)
        let actualBytes = max(UInt64(writeBytes), reportedBytes)
        guard actualBytes <= expectedSizeBytes else {
            try? FileManager.default.removeItem(atPath: destination)
            throw IrohBlobBackendError.fetchFailed(
                "blob exceeded expected size: \(actualBytes) bytes > \(expectedSizeBytes) bytes"
            )
        }
        return BlobTransferStats(
            bytesTotal: reportedBytes,
            blake3Hash: "fake",
            durationMillis: 1,
            didResume: false
        )
    }

    func identity() async throws -> IrohEndpointIdentity {
        IrohEndpointIdentity(nodeId: "test", rawPublicKey: Data(repeating: 1, count: 32))
    }

    func shutdown() async {}
}

private final class ExpectedSizeOverrideBackend: DefaultExpectedSizeBackend {
    init() {
        super.init(writeBytes: 0, reportedBytes: 0)
    }

    override func fetchBlob(ticketText: String, destination: String) async throws -> BlobTransferStats {
        throw IrohBlobBackendError.fetchFailed("old fetch path should not be used")
    }

    override func fetchBlob(
        ticketText: String,
        destination: String,
        expectedSizeBytes: UInt64
    ) async throws -> BlobTransferStats {
        let url = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x5A, count: Int(expectedSizeBytes)).write(to: url)
        return BlobTransferStats(
            bytesTotal: expectedSizeBytes,
            blake3Hash: "fake",
            durationMillis: 1,
            didResume: false
        )
    }
}

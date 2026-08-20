import XCTest
@testable import OpenBurnBarCore
@testable import OpenBurnBarIrohRelay
@testable import OpenBurnBarMedia

/// Verifies the platform-agnostic transfer service drives publish → fetch
/// correctly through a fake `IrohBlobBackend`. The real iroh endpoints
/// are exercised by the manual TestFlight loop documented in
/// `docs/runbooks/media-rollout-status.md`; this suite is the unit-level
/// safety net that runs on every CI build.
final class MediaFileTransferServiceTests: XCTestCase {
    func testPublishProducesManifestAndTicket() async throws {
        let backend = FakeBlobBackend()
        let service = await makeService(backend: backend)

        let inputURL = try writeTempFile(named: "snapshot.png", bytes: Data([0x89, 0x50, 0x4E, 0x47]))
        let result = try await service.publish(localFile: inputURL, peerDeviceID: "peer123")

        XCTAssertFalse(result.ticketText.isEmpty)
        XCTAssertEqual(result.manifest.filename, "snapshot.png")
        XCTAssertEqual(result.manifest.mime, "image/png")
        XCTAssertEqual(result.manifest.size, 4)
        XCTAssertEqual(result.manifest.peerDeviceId, "peer123")
        XCTAssertTrue(result.manifest.manifestId.hasPrefix("att_"))
        XCTAssertEqual(backend.publishedPaths.last, inputURL.path)
    }

    func testFetchWritesIntoInbox() async throws {
        let backend = FakeBlobBackend()
        let service = await makeService(backend: backend)

        let manifest = HermesRealtimeRelayAttachmentManifest(
            manifestId: "att_xyz",
            blobHash: "blake3:deadbeef",
            filename: "log.txt",
            mime: "text/plain",
            size: 32,
            peerDeviceId: "peer1",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let (destination, stats) = try await service.fetch(
            ticketText: "blob1xyzfakedata",
            manifest: manifest
        )

        XCTAssertEqual(stats.bytesTotal, 32)
        XCTAssertTrue(destination.lastPathComponent.hasSuffix(".txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testPublishRejectsMissingFile() async throws {
        let backend = FakeBlobBackend()
        let service = await makeService(backend: backend)

        let bogus = URL(fileURLWithPath: "/tmp/this-file-does-not-exist-mercury")
        do {
            _ = try await service.publish(localFile: bogus, peerDeviceID: nil)
            XCTFail("expected publish to throw")
        } catch let error as MediaFileTransferService.ServiceError {
            guard case .localFileMissing = error else {
                XCTFail("expected localFileMissing, got \(error)")
                return
            }
        }
    }

    func testBootstrapIsIdempotent() async throws {
        let backend = FakeBlobBackend()
        let service = await makeService(backend: backend)

        async let a = service.bootstrap()
        async let b = service.bootstrap()
        let identities = try await [a, b]
        XCTAssertEqual(identities[0].nodeId, identities[1].nodeId)
        XCTAssertEqual(backend.bootstrapInvocations, 1)
    }

    func testPublishSurfacesBackendErrorsTyped() async throws {
        let backend = FakeBlobBackend()
        backend.publishOverride = .failure(.publishFailed("disk full"))
        let service = await makeService(backend: backend)

        let inputURL = try writeTempFile(named: "x.png", bytes: Data([0x00]))
        do {
            _ = try await service.publish(localFile: inputURL, peerDeviceID: nil)
            XCTFail("expected publish to throw")
        } catch let error as MediaFileTransferService.ServiceError {
            guard case .publishFailed = error else {
                XCTFail("expected publishFailed, got \(error)")
                return
            }
        }
    }

    func testFetchSurfacesBackendErrorsTyped() async throws {
        let backend = FakeBlobBackend()
        backend.fetchOverride = .failure(.fetchFailed("peer unreachable"))
        let service = await makeService(backend: backend)

        let manifest = HermesRealtimeRelayAttachmentManifest(
            manifestId: "att_a", blobHash: "h", filename: "a.bin", mime: "x", size: 1
        )
        do {
            _ = try await service.fetch(ticketText: "blob1", manifest: manifest)
            XCTFail("expected fetch to throw")
        } catch let error as MediaFileTransferService.ServiceError {
            guard case .fetchFailed = error else {
                XCTFail("expected fetchFailed, got \(error)")
                return
            }
        }
    }

    func testShutdownClearsBootstrapState() async throws {
        let backend = FakeBlobBackend()
        let service = await makeService(backend: backend)

        _ = try await service.bootstrap()
        XCTAssertEqual(backend.bootstrapInvocations, 1)

        await service.shutdown()
        XCTAssertEqual(backend.shutdownInvocations, 1)

        _ = try await service.bootstrap()
        XCTAssertEqual(backend.bootstrapInvocations, 2)
    }

    // MARK: - helpers

    private func makeService(backend: IrohBlobBackend) async -> MediaFileTransferService {
        let temp = uniqueTempDirectory()
        let store = temp.appendingPathComponent("store", isDirectory: true)
        let inbox = temp.appendingPathComponent("inbox", isDirectory: true)
        return MediaFileTransferService(
            backend: backend,
            configuration: .init(
                storeDirectoryURL: store,
                inboxDirectoryURL: inbox,
                secretKeyProvider: { Data(repeating: 0xAB, count: 32) }
            )
        )
    }

    private func uniqueTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mercury-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeTempFile(named: String, bytes: Data) throws -> URL {
        let url = uniqueTempDirectory().appendingPathComponent(named)
        try bytes.write(to: url)
        return url
    }
}

// MARK: - Fake backend

private final class FakeBlobBackend: IrohBlobBackend, @unchecked Sendable {
    enum Outcome<T> {
        case success(T)
        case failure(IrohBlobBackendError)
    }

    var publishedPaths: [String] = []
    var bootstrapInvocations: Int = 0
    var shutdownInvocations: Int = 0
    var publishOverride: Outcome<String>?
    var fetchOverride: Outcome<BlobTransferStats>?

    func bootstrap(secret: Data, storeDirectoryPath: String, relayURL: String?) async throws -> IrohEndpointIdentity {
        bootstrapInvocations += 1
        return IrohEndpointIdentity(
            nodeId: "fakenode_" + UUID().uuidString.prefix(8),
            rawPublicKey: Data(secret.prefix(32))
        )
    }

    func publishBlob(localPath: String) async throws -> String {
        publishedPaths.append(localPath)
        switch publishOverride {
        case .some(.failure(let error)): throw error
        case .some(.success(let value)): return value
        case .none: return "blob1faketicket_\(UUID().uuidString.prefix(8))"
        }
    }

    func fetchBlob(ticketText: String, destination: String) async throws -> BlobTransferStats {
        switch fetchOverride {
        case .some(.failure(let error)): throw error
        case .some(.success(let stats)): return stats
        case .none:
            // Synthesize a destination file so callers exercising the
            // happy path have a real artifact to inspect.
            let url = URL(fileURLWithPath: destination)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? Data(repeating: 0xDE, count: 32).write(to: url)
            return BlobTransferStats(
                bytesTotal: 32,
                blake3Hash: "blake3:deadbeef",
                durationMillis: 12,
                didResume: false
            )
        }
    }

    func identity() async throws -> IrohEndpointIdentity {
        IrohEndpointIdentity(nodeId: "fakenode", rawPublicKey: Data(repeating: 0, count: 32))
    }

    func shutdown() async {
        shutdownInvocations += 1
    }
}

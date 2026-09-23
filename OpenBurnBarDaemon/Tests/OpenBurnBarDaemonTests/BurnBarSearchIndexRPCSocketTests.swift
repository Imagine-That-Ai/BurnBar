import Darwin
import Foundation
import OpenBurnBarKernel
import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// Wave 2.1c-iv: `daemon.search.index.apply` exercised end to end through
/// the production dispatch — real Unix socket, `responseData` routing,
/// `handleSearchRPC`, and the lazily bootstrapped project-memory store
/// bound to the configured index database.
///
/// These tests prove the wire contract, not the storage semantics (those
/// live in `BurnBarSearchIndexLaneTests`): a valid apply returns its
/// counts, a malformed apply is the caller's fault (`invalidParams`), a
/// storage failure is an `internalError` with nothing partially applied,
/// and a missing store fails closed instead of writing nowhere.
final class BurnBarSearchIndexRPCSocketTests: XCTestCase {
    private let authToken = "search-index-rpc-test-token"

    func test_searchIndexApplyDispatchesThroughTheServerSocket() async throws {
        let rootURL = try makeTemporaryRoot(name: "search-index-rpc")
        let databasePath = rootURL.appendingPathComponent("openburnbar.sqlite").path

        // The index database must exist BEFORE the daemon bootstraps the
        // project-memory store, exactly as production requires. The seed
        // handle is scoped so its connection closes before the server
        // opens the file.
        do {
            let seed = try BurnBarProjectCodeMemoryStore(
                databasePath: databasePath,
                logger: BurnBarDaemonLogger(category: "search-index-rpc-seed")
            )
            try seed.searchIndexTestCompleteSchema()
        }

        let socketPath = makeSocketPath(name: "search-index")
        let server = makeServer(rootURL: rootURL, socketPath: socketPath, indexDatabasePath: databasePath)
        try await server.start()
        addTeardownBlock { await server.stop() }

        // 1. A valid apply commits over the wire and returns its counts.
        let applied: BurnBarRPCResponseEnvelope<BurnBarSearchIndexApplyResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "apply",
                method: .searchIndexApply,
                authToken: authToken,
                params: BurnBarSearchIndexApplyRequest(
                    documentUpsert: BurnBarSearchIndexDocumentRow(
                        id: "doc-1",
                        sourceKind: "conversation",
                        sourceID: "source-1",
                        sourceVersionID: "v1",
                        provider: "test-provider",
                        projectName: "test-project",
                        title: "Test title",
                        indexedAtText: "2026-09-23 05:00:00.000",
                        createdAtText: "2026-09-23 05:00:00.000",
                        updatedAtText: "2026-09-23 06:00:00.000"
                    ),
                    chunkMutations: BurnBarSearchIndexChunkMutations(
                        documentID: "doc-1",
                        ftsTitle: "Test title",
                        ftsProjectName: "test-project",
                        ftsProvider: "test-provider",
                        chunksToInsert: [BurnBarSearchIndexChunkRow(
                            id: "chunk-1",
                            documentID: "doc-1",
                            sourceKind: "conversation",
                            sourceID: "source-1",
                            ordinal: 0,
                            startOffset: 0,
                            endOffset: 11,
                            text: "hello world",
                            createdAtText: "2026-09-23 05:00:00.000",
                            updatedAtText: "2026-09-23 06:00:00.000"
                        )]
                    )
                )
            ),
            socketPath: socketPath
        )
        XCTAssertNil(applied.error)
        let appliedResult = try XCTUnwrap(applied.result)
        XCTAssertEqual(appliedResult.documentsUpserted, 1)
        XCTAssertEqual(appliedResult.chunksAdded, 1)
        XCTAssertEqual(appliedResult.chunksDeleted, 0)

        // 2. A malformed apply is the caller's fault, not an internal error.
        let rejected: BurnBarRPCResponseEnvelope<BurnBarSearchIndexApplyResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "malformed",
                method: .searchIndexApply,
                authToken: authToken,
                params: BurnBarSearchIndexApplyRequest()
            ),
            socketPath: socketPath
        )
        XCTAssertNil(rejected.result)
        XCTAssertEqual(rejected.error?.code, BurnBarRPCErrorCode.invalidParams)

        // 3. A storage failure is an internal error and applies nothing:
        // the clashing chunk violates the unique (documentID, ordinal)
        // index, so the whole apply — including the document upsert in
        // the same request — rolls back.
        let failed: BurnBarRPCResponseEnvelope<BurnBarSearchIndexApplyResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "clash",
                method: .searchIndexApply,
                authToken: authToken,
                params: BurnBarSearchIndexApplyRequest(
                    documentUpsert: BurnBarSearchIndexDocumentRow(
                        id: "doc-2",
                        sourceKind: "conversation",
                        sourceID: "source-2",
                        sourceVersionID: "v1",
                        title: "Second",
                        indexedAtText: "2026-09-23 05:00:00.000",
                        createdAtText: "2026-09-23 05:00:00.000",
                        updatedAtText: "2026-09-23 06:00:00.000"
                    ),
                    chunkMutations: BurnBarSearchIndexChunkMutations(
                        documentID: "doc-2",
                        ftsTitle: "Second",
                        ftsProjectName: "test-project",
                        ftsProvider: "test-provider",
                        chunksToInsert: [
                            BurnBarSearchIndexChunkRow(
                                id: "chunk-a",
                                documentID: "doc-2",
                                sourceKind: "conversation",
                                sourceID: "source-2",
                                ordinal: 0,
                                startOffset: 0,
                                endOffset: 5,
                                text: "alpha",
                                createdAtText: "2026-09-23 05:00:00.000",
                                updatedAtText: "2026-09-23 06:00:00.000"
                            ),
                            BurnBarSearchIndexChunkRow(
                                id: "chunk-b",
                                documentID: "doc-2",
                                sourceKind: "conversation",
                                sourceID: "source-2",
                                ordinal: 0,
                                startOffset: 6,
                                endOffset: 10,
                                text: "beta",
                                createdAtText: "2026-09-23 05:00:00.000",
                                updatedAtText: "2026-09-23 06:00:00.000"
                            )
                        ]
                    )
                )
            ),
            socketPath: socketPath
        )
        XCTAssertNil(failed.result)
        XCTAssertEqual(failed.error?.code, BurnBarRPCErrorCode.internalError)
    }

    func test_searchIndexApplyFailsClosedWithoutAStore() async throws {
        let rootURL = try makeTemporaryRoot(name: "search-index-rpc-unavailable")
        let socketPath = makeSocketPath(name: "search-index-unavail")
        let server = makeServer(rootURL: rootURL, socketPath: socketPath, indexDatabasePath: nil)
        try await server.start()
        addTeardownBlock { await server.stop() }

        let response: BurnBarRPCResponseEnvelope<BurnBarSearchIndexApplyResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "unavailable",
                method: .searchIndexApply,
                authToken: authToken,
                params: BurnBarSearchIndexApplyRequest(
                    documentUpsert: BurnBarSearchIndexDocumentRow(
                        id: "doc-1",
                        sourceKind: "conversation",
                        sourceID: "source-1",
                        sourceVersionID: "v1",
                        title: "Test title",
                        indexedAtText: "2026-09-23 05:00:00.000",
                        createdAtText: "2026-09-23 05:00:00.000",
                        updatedAtText: "2026-09-23 06:00:00.000"
                    )
                )
            ),
            socketPath: socketPath
        )
        XCTAssertNil(response.result)
        XCTAssertEqual(response.error?.code, BurnBarRPCErrorCode.internalError)
    }

    // MARK: - Server construction

    private func makeServer(
        rootURL: URL,
        socketPath: String,
        indexDatabasePath: String?
    ) -> BurnBarDaemonServer {
        BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: authToken,
                indexDatabasePath: indexDatabasePath,
                startsMissionControlBackgroundLoops: false
            ),
            logger: BurnBarDaemonLogger(category: "search-index-rpc-tests"),
            configStore: BurnBarConfigStore(
                fileURL: rootURL.appendingPathComponent("provider-config.json"),
                secretStore: BurnBarInMemorySecretStore(),
                logger: BurnBarDaemonLogger(category: "search-index-rpc-tests")
            ),
            usageRecorder: BurnBarUsageRecorder(
                fileURL: rootURL.appendingPathComponent("usage-events.jsonl")
            )
        )
    }

    private func makeTemporaryRoot(name: String) throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: rootURL) }
        return rootURL
    }

    private func makeSocketPath(name: String) -> String {
        "/tmp/obb-search-index-\(name)-\(String(UUID().uuidString.prefix(8))).sock"
    }

    // MARK: - Socket transport

    private func sendEnvelope<Envelope: Encodable, Response: Decodable>(
        _ envelope: Envelope,
        socketPath: String
    ) throws -> BurnBarRPCResponseEnvelope<Response> {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertNotEqual(fileDescriptor, -1)

        var noSigPipe: Int32 = 1
        setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = try socketAddress(for: socketPath)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { reboundPointer in
                connect(fileDescriptor, reboundPointer, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        guard connectResult == 0 else {
            let code = errno
            close(fileDescriptor)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        defer { close(fileDescriptor) }

        let payload = try JSONEncoder().encode(envelope) + Data([0x0A])
        payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesRemaining = rawBuffer.count
            var offset = 0
            while bytesRemaining > 0 {
                let bytesWritten = write(fileDescriptor, baseAddress.advanced(by: offset), bytesRemaining)
                XCTAssertGreaterThan(bytesWritten, 0)
                bytesRemaining -= bytesWritten
                offset += bytesWritten
            }
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let bytesRead = read(fileDescriptor, &buffer, buffer.count)
            if bytesRead == 0 { break }
            XCTAssertGreaterThan(bytesRead, 0)
            response.append(contentsOf: buffer.prefix(bytesRead))
            if response.last == 0x0A { break }
        }
        while response.last == 0x0A || response.last == 0x0D { response.removeLast() }

        return try JSONDecoder().decode(BurnBarRPCResponseEnvelope<Response>.self, from: response)
    }

    private func socketAddress(for socketPath: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() { rawBuffer[index] = byte }
        }
        return address
    }
}

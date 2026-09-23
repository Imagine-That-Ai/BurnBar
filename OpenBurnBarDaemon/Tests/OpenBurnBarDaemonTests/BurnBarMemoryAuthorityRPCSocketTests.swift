import Darwin
import Foundation
import OpenBurnBarKernel
import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// Wave 2.1c-iii: `daemon.memory.authority.apply` exercised end to end
/// through the production dispatch — real Unix socket, `responseData`
/// routing, `handleMemoryRPC`, and the lazily bootstrapped project-memory
/// store bound to the configured index database.
///
/// These tests prove the wire contract, not the storage semantics (those
/// live in `BurnBarMemoryAuthorityLaneTests`): a valid remember returns
/// the daemon-assigned audit sequences, a malformed mutation is the
/// caller's fault (`invalidParams`), and a stale reseal precondition is a
/// retryable `conflict` — never a crash and never a partial apply.
final class BurnBarMemoryAuthorityRPCSocketTests: XCTestCase {
    private let authToken = "memory-authority-rpc-test-token"

    func test_authorityApplyDispatchesThroughTheServerSocket() async throws {
        let rootURL = try makeTemporaryRoot(name: "memory-authority-rpc")
        let databasePath = rootURL.appendingPathComponent("openburnbar.sqlite").path

        // The index database must exist BEFORE the daemon bootstraps the
        // project-memory store, exactly as production requires. The store
        // init bootstraps the daemon tables; the test support completes
        // the migrator-owned authority schema. The seed handle is scoped
        // so its connection closes before the server opens the file.
        do {
            let seed = try BurnBarProjectCodeMemoryStore(
                databasePath: databasePath,
                logger: BurnBarDaemonLogger(category: "memory-authority-rpc-seed")
            )
            try seed.memoryAuthorityTestCompleteSchema()
        }

        let socketPath = makeSocketPath(name: "memory-authority")
        let server = makeServer(rootURL: rootURL, socketPath: socketPath, indexDatabasePath: databasePath)
        try await server.start()
        addTeardownBlock { await server.stop() }

        // 1. A valid remember commits over the wire and returns the
        // daemon-assigned audit sequence.
        let applied: BurnBarRPCResponseEnvelope<BurnBarMemoryAuthorityApplyResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "remember",
                method: .memoryAuthorityApply,
                authToken: authToken,
                params: BurnBarMemoryAuthorityApplyRequest(
                    mutationID: "mutation-1",
                    actor: "app",
                    operations: [.remember(makeRemember())]
                )
            ),
            socketPath: socketPath
        )
        XCTAssertNil(applied.error)
        let appliedResult = try XCTUnwrap(applied.result)
        XCTAssertEqual(appliedResult.results.count, 1)
        XCTAssertEqual(appliedResult.results[0].audits.map(\.sequence), [1])

        // 2. A second mutation continues the chain the daemon assigned —
        // the sequences the wire returns are the chain, not echoes.
        let appended: BurnBarRPCResponseEnvelope<BurnBarMemoryAuthorityApplyResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "append",
                method: .memoryAuthorityApply,
                authToken: authToken,
                params: BurnBarMemoryAuthorityApplyRequest(
                    mutationID: "mutation-2",
                    actor: "app",
                    operations: [.appendAudit(makeAudit(action: "memory.candidate_dropped"))]
                )
            ),
            socketPath: socketPath
        )
        XCTAssertNil(appended.error)
        XCTAssertEqual(appended.result?.results[0].audits.map(\.sequence), [2])

        // 3. A malformed mutation is the caller's fault, not an internal error.
        var malformed = makeRemember()
        malformed = BurnBarMemoryAuthorityRemember(
            snapshot: malformed.snapshot,
            memory: malformed.memory,
            provenance: malformed.provenance,
            audits: [],
            merge: nil
        )
        let rejected: BurnBarRPCResponseEnvelope<BurnBarMemoryAuthorityApplyResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "malformed",
                method: .memoryAuthorityApply,
                authToken: authToken,
                params: BurnBarMemoryAuthorityApplyRequest(
                    mutationID: "mutation-3",
                    actor: "app",
                    operations: [.remember(malformed)]
                )
            ),
            socketPath: socketPath
        )
        XCTAssertNil(rejected.result)
        XCTAssertEqual(rejected.error?.code, BurnBarRPCErrorCode.invalidParams)

        // 4. A stale reseal precondition is a retryable conflict: the app
        // re-reads and retries, and nothing was applied.
        let conflicted: BurnBarRPCResponseEnvelope<BurnBarMemoryAuthorityApplyResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "conflict",
                method: .memoryAuthorityApply,
                authToken: authToken,
                params: BurnBarMemoryAuthorityApplyRequest(
                    mutationID: "mutation-4",
                    actor: "app",
                    operations: [.updateBody(BurnBarMemoryAuthorityUpdate(
                        memoryID: "memory-1",
                        sourceKind: "chat",
                        kind: "preference",
                        confidence: nil,
                        updatedAtText: "2026-09-23 07:00:00.000",
                        reseal: BurnBarMemoryAuthorityReseal(
                            expectedBodyHash: String(repeating: "ff", count: 32),
                            expectedUpdatedAtText: "2026-09-23 05:00:00.000",
                            snapshot: makeSnapshot()
                        ),
                        audit: makeAudit(action: "memory.update")
                    ))]
                )
            ),
            socketPath: socketPath
        )
        XCTAssertNil(conflicted.result)
        XCTAssertEqual(conflicted.error?.code, BurnBarRPCErrorCode.conflict)
    }

    func test_authorityApplyFailsClosedWhenNoIndexDatabaseIsConfigured() async throws {
        let rootURL = try makeTemporaryRoot(name: "memory-authority-rpc-nil")
        let socketPath = makeSocketPath(name: "memory-authority-nil")
        let server = makeServer(rootURL: rootURL, socketPath: socketPath, indexDatabasePath: nil)
        try await server.start()
        addTeardownBlock { await server.stop() }

        let response: BurnBarRPCResponseEnvelope<BurnBarMemoryAuthorityApplyResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "remember",
                method: .memoryAuthorityApply,
                authToken: authToken,
                params: BurnBarMemoryAuthorityApplyRequest(
                    mutationID: "mutation-1",
                    actor: "app",
                    operations: [.remember(makeRemember())]
                )
            ),
            socketPath: socketPath
        )

        XCTAssertNil(response.result)
        let error = try XCTUnwrap(response.error)
        XCTAssertEqual(error.code, BurnBarRPCErrorCode.internalError)
        XCTAssertTrue(
            error.message.contains("Project memory is not available"),
            "The error must tell the operator how to fix it: \(error.message)"
        )
    }

    // MARK: - Fixtures

    private func makeAudit(action: String) -> BurnBarMemoryAuthorityAuditEvent {
        BurnBarMemoryAuthorityAuditEvent(
            action: action,
            projectID: "project-1",
            subjectID: "memory-1",
            labels: ["memory_id:memory-1", "source_kind:chat"],
            labelsJSON: #"["memory_id:memory-1","source_kind:chat"]"#,
            timestampText: "2026-09-23T05:00:00.000Z"
        )
    }

    private func makeSnapshot() -> BurnBarMemoryAuthoritySnapshotRow {
        BurnBarMemoryAuthoritySnapshotRow(
            id: "snapshot-memory-1",
            memoryID: "memory-1",
            bodyRef: "memory_body_snapshots:snapshot-memory-1",
            snapshotJSON: #"{"schemaVersion":1}"#,
            bodyHash: String(repeating: "ab", count: 32),
            sourceKind: "chat",
            createdAtText: "2026-09-23 05:00:00.000",
            updatedAtText: "2026-09-23 05:00:00.000"
        )
    }

    private func makeRemember() -> BurnBarMemoryAuthorityRemember {
        BurnBarMemoryAuthorityRemember(
            snapshot: makeSnapshot(),
            memory: BurnBarMemoryAuthorityMemoryRow(
                id: "memory-1",
                projectID: "project-1",
                kind: "fact",
                scopeText: "chat",
                confidence: 0.9,
                bodyRef: "memory_body_snapshots:snapshot-memory-1",
                bodyRedacted: "memory_body_snapshots:snapshot-memory-1",
                tagsJSON: "[]",
                sourcePath: nil,
                validFromText: "2026-09-23 05:00:00.000",
                validToText: nil,
                supersededBy: nil,
                createdAtText: "2026-09-23 05:00:00.000",
                updatedAtText: "2026-09-23 05:00:00.000",
                sourceKind: "chat",
                reviewStatus: "quarantined",
                userID: "user-1",
                agentID: nil,
                runID: nil,
                appID: "app-1"
            ),
            provenance: [BurnBarMemoryAuthorityProvenanceRow(
                id: "prov-1",
                memoryID: "memory-1",
                sourceKind: "chat",
                threadLogicalID: "thread-1",
                messageID: "message-1",
                role: "user",
                authoredAtText: "2026-09-23 04:00:00.000",
                contentHash: String(repeating: "cd", count: 32),
                occurrence: 0,
                xdeviceHMAC: String(repeating: "ef", count: 32),
                citationState: "live",
                createdAtText: "2026-09-23 05:00:00.000"
            )],
            audits: [makeAudit(action: "memory.add")],
            merge: nil
        )
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
            logger: BurnBarDaemonLogger(category: "memory-authority-rpc-tests"),
            configStore: BurnBarConfigStore(
                fileURL: rootURL.appendingPathComponent("provider-config.json"),
                secretStore: BurnBarInMemorySecretStore(),
                logger: BurnBarDaemonLogger(category: "memory-authority-rpc-tests")
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
        "/tmp/obb-memory-authority-\(name)-\(String(UUID().uuidString.prefix(8))).sock"
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

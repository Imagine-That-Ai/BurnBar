import BurnBarCore
@testable import BurnBarDaemon
import Darwin
import Foundation
import XCTest

/// Service + RPC integration for the persistence layer: the fleet service
/// persists every completed tick into fleet.sqlite and fleet-snapshot.json,
/// records fixed-row transitions, and surfaces `persistenceHealth` in the
/// served snapshot while RPC keeps serving.
final class BurnBarFleetPersistenceServiceTests: XCTestCase {
    private var fixtureRoot: URL!

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-fleet-persist-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
    }

    /// A probe whose claude-code row status can be flipped between builds.
    private final class FlipProbe: BurnBarFleetProbe, @unchecked Sendable {
        let agentID: BurnBarFleetAgentID
        let rootPath: String
        var claudeStatus: BurnBarFleetAgentStatus
        var claudeConfidence: BurnBarFleetConfidence

        init(
            agentID: BurnBarFleetAgentID,
            rootPath: String,
            claudeStatus: BurnBarFleetAgentStatus,
            claudeConfidence: BurnBarFleetConfidence
        ) {
            self.agentID = agentID
            self.rootPath = rootPath
            self.claudeStatus = claudeStatus
            self.claudeConfidence = claudeConfidence
        }

        func probe(now: Date) async -> BurnBarFleetProbeResult {
            let isClaude = agentID == .claudeCode
            let status = isClaude ? claudeStatus : .unknown
            let confidence = isClaude ? claudeConfidence : .unsupported
            let agent = BurnBarFleetAgent(
                id: agentID,
                displayName: BurnBarFleetSnapshotBuilder.displayName(for: agentID),
                status: status,
                confidence: confidence,
                projectName: isClaude ? "/Users/test/RepoA" : nil
            )
            return BurnBarFleetProbeResult(
                agent: agent,
                health: BurnBarFleetProbeHealth(
                    agent: agentID,
                    state: .ok,
                    rootPath: rootPath,
                    checkedAt: now
                )
            )
        }
    }

    private func makeProbes(
        claudeStatus: BurnBarFleetAgentStatus,
        claudeConfidence: BurnBarFleetConfidence
    ) -> (probes: [BurnBarFleetAgentID: any BurnBarFleetProbe], flip: FlipProbe) {
        var probes: [BurnBarFleetAgentID: any BurnBarFleetProbe] = [:]
        var flip: FlipProbe?
        for agentID in BurnBarFleetAgentID.declaredRoster {
            let rootPath = fixtureRoot
                .appendingPathComponent(BurnBarFleetRootResolver.rootDirectoryName(for: agentID), isDirectory: true)
                .path
            if agentID == .claudeCode {
                let probe = FlipProbe(
                    agentID: agentID,
                    rootPath: rootPath,
                    claudeStatus: claudeStatus,
                    claudeConfidence: claudeConfidence
                )
                probes[agentID] = probe
                flip = probe
            } else {
                probes[agentID] = FlipProbe(
                    agentID: agentID,
                    rootPath: rootPath,
                    claudeStatus: .unknown,
                    claudeConfidence: .unsupported
                )
            }
        }
        return (probes, flip!)
    }

    private func makePersister() throws -> BurnBarFleetPersister {
        // The store lives in a subdirectory so a read-only fixture root only
        // blocks the file writer (VAL-FLEET-021 injection), never the store.
        let storeDir = fixtureRoot.appendingPathComponent("store", isDirectory: true)
        let store = BurnBarFleetStore(
            databasePath: storeDir.appendingPathComponent("fleet.sqlite").path,
            eventRetentionSeconds: 3600,
            snapshotRetentionCount: 5
        )
        _ = try store.open()
        let writer = BurnBarFleetFileWriter(
            fileURL: fixtureRoot.appendingPathComponent("fleet-snapshot.json")
        )
        return BurnBarFleetPersister(store: store, fileWriter: writer)
    }

    // MARK: - Service persists every tick + records transitions

    func testService_persistsEveryTick_recordsTransitions() async throws {
        let (probes, flip) = makeProbes(claudeStatus: .running, claudeConfidence: .exactProcess)
        let builder = BurnBarFleetSnapshotBuilder(cadenceSeconds: 1, probes: probes)
        let service = BurnBarFleetService(builder: builder, persister: try makePersister())

        let first = try await service.buildOnce()
        XCTAssertEqual(first.persistenceHealth, .ok)
        XCTAssertEqual(first.cadenceSeconds, 1)

        // Flip the fixture: running -> idle on the next build.
        flip.claudeStatus = .idle
        let second = try await service.buildOnce()

        // The store holds the latest snapshot and the transition event.
        let servicePersisterOptional = await service.persister
        let servicePersister = try XCTUnwrap(servicePersisterOptional)
        let store = servicePersister.store
        // Verbatim persistence: the stored payload decodes to the exact wire
        // form of the served snapshot (cadenceSeconds never re-stamped).
        let storedPayload = try XCTUnwrap(store.latestSnapshotPayload())
        let stored = try JSONDecoder().decode(BurnBarFleetSnapshot.self, from: Data(storedPayload.utf8))
        let servedWire = try JSONDecoder().decode(
            BurnBarFleetSnapshot.self,
            from: JSONEncoder().encode(second)
        )
        XCTAssertEqual(stored, servedWire)
        XCTAssertEqual(stored.cadenceSeconds, 1)
        XCTAssertEqual(stored.agents.first { $0.id == .claudeCode }?.status, .idle)

        let events = try store.events(for: .claudeCode)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, "status_changed")
        XCTAssertEqual(events.first?.fromStatus, "running")
        XCTAssertEqual(events.first?.toStatus, "idle")

        // The well-known file exists and matches the served snapshot's wire
        // form (dates are ms-truncated on the wire; compare decoded-to-decoded).
        let fileData = try Data(contentsOf: fixtureRoot.appendingPathComponent("fleet-snapshot.json"))
        let fileSnapshot = try JSONDecoder().decode(BurnBarFleetSnapshot.self, from: fileData)
        XCTAssertEqual(fileSnapshot, servedWire)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixtureRoot.appendingPathComponent("fleet-snapshot.json.tmp").path
            )
        )
    }

    // MARK: - Writer failure: RPC keeps serving, health degraded

    func testService_writerFailure_servedSnapshotDegraded_rpcKeepsServing() async throws {
        let (probes, _) = makeProbes(claudeStatus: .running, claudeConfidence: .exactProcess)
        let builder = BurnBarFleetSnapshotBuilder(cadenceSeconds: 1, probes: probes)
        let persister = try makePersister()
        let service = BurnBarFleetService(builder: builder, persister: persister)

        // First build succeeds: last-good file established.
        let good = try await service.buildOnce()
        XCTAssertEqual(good.persistenceHealth, .ok)
        let lastGoodData = try Data(contentsOf: fixtureRoot.appendingPathComponent("fleet-snapshot.json"))

        // Make the writer fail while the destination stays intact: a
        // read-only parent directory blocks the tmp write (EACCES) without
        // touching the last-good file.
        let fileURL = fixtureRoot.appendingPathComponent("fleet-snapshot.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixtureRoot.path)

        // The next build still completes and serves a fresh snapshot with
        // typed degraded persistenceHealth.
        let degraded = try await service.buildOnce()
        guard case .degraded(let reason) = degraded.persistenceHealth else {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixtureRoot.path)
            return XCTFail("writer failure must degrade persistenceHealth, got \(degraded.persistenceHealth)")
        }
        XCTAssertTrue(reason.contains("fleet-snapshot.json write failed"), "unexpected reason: \(reason)")
        let servicePersisterOptional = await service.persister
        let servicePersister = try XCTUnwrap(servicePersisterOptional)
        XCTAssertEqual(servicePersister.persistenceHealth(), degraded.persistenceHealth)

        // The last-good file stays byte-identical and no .tmp litter remains.
        XCTAssertEqual(
            try Data(contentsOf: fileURL),
            lastGoodData,
            "last-good file must stay byte-identical while the writer is degraded"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixtureRoot.appendingPathComponent("fleet-snapshot.json.tmp").path
            ),
            "no .tmp litter after a failed write"
        )

        // The store still persists the latest snapshot (RPC truth is fresh).
        // The store row carries the builder's embedded (pre-persist) health —
        // the served snapshot carries the post-persist degraded health.
        let storedPayload = try XCTUnwrap(servicePersister.store.latestSnapshotPayload())
        let stored = try JSONDecoder().decode(BurnBarFleetSnapshot.self, from: Data(storedPayload.utf8))
        let degradedWire = try JSONDecoder().decode(
            BurnBarFleetSnapshot.self,
            from: JSONEncoder().encode(degraded)
        )
        XCTAssertEqual(stored.persistenceHealth, .ok, "store row carries the builder's pre-persist health")
        XCTAssertEqual(stored.generatedAt, degradedWire.generatedAt)
        XCTAssertEqual(stored.cadenceSeconds, degraded.cadenceSeconds)
        XCTAssertEqual(stored.agents.first { $0.id == .claudeCode }?.status, .running)

        // Recovery: restore permissions; the next persist clears health and
        // the file is replaced atomically.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixtureRoot.path)
        let recovered = try await service.buildOnce()
        XCTAssertEqual(recovered.persistenceHealth, .ok)
        let fileSnapshot = try JSONDecoder().decode(
            BurnBarFleetSnapshot.self,
            from: Data(contentsOf: fileURL)
        )
        let recoveredWire = try JSONDecoder().decode(
            BurnBarFleetSnapshot.self,
            from: JSONEncoder().encode(recovered)
        )
        XCTAssertEqual(fileSnapshot, recoveredWire)
        _ = lastGoodData
    }

    // MARK: - RPC: daemon serves persistenceHealth + file == RPC payload

    func testRPC_snapshotServesPersistenceHealth_fileMatchesPayload() async throws {
        // Socket under /tmp: the temp fixture dir path can exceed the
        // sockaddr_un limit.
        let socketPath = "/tmp/burnbar-fleet-persist-rpc-\(UUID().uuidString).sock"
        let (probes, _) = makeProbes(claudeStatus: .running, claudeConfidence: .exactProcess)
        let builder = BurnBarFleetSnapshotBuilder(cadenceSeconds: 1, probes: probes)
        let service = BurnBarFleetService(builder: builder, persister: try makePersister())
        _ = try await service.buildOnce()

        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(socketPath: socketPath),
            fleetService: service
        )
        try await server.start()
        defer { Task { await server.stop() } }

        let response: BurnBarRPCResponseEnvelope<BurnBarFleetSnapshotResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "persist-1",
                method: .fleetSnapshot,
                params: BurnBarFleetSnapshotRequest()
            ),
            socketPath: socketPath
        )
        let snapshot = try XCTUnwrap(response.result?.snapshot)
        XCTAssertEqual(snapshot.persistenceHealth, .ok)
        XCTAssertEqual(snapshot.cadenceSeconds, 1)

        // File payload is field-for-field identical to the RPC payload.
        let fileData = try Data(contentsOf: fixtureRoot.appendingPathComponent("fleet-snapshot.json"))
        let fileSnapshot = try JSONDecoder().decode(BurnBarFleetSnapshot.self, from: fileData)
        XCTAssertEqual(fileSnapshot, snapshot)
    }

    // MARK: - Socket helper (mirrors BurnBarFleetServerRPCTests)

    private func sendEnvelope<Envelope: Encodable, Response: Decodable>(
        _ envelope: Envelope,
        socketPath: String
    ) throws -> BurnBarRPCResponseEnvelope<Response> {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertNotEqual(fileDescriptor, -1)

        var noSigPipe: Int32 = 1
        setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )

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

        defer {
            close(fileDescriptor)
        }

        let encoder = JSONEncoder()
        let payload = try encoder.encode(envelope) + Data([0x0A])
        payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            var bytesRemaining = rawBuffer.count
            var offset = 0

            while bytesRemaining > 0 {
                let pointer = baseAddress.advanced(by: offset)
                let bytesWritten = write(fileDescriptor, pointer, bytesRemaining)
                XCTAssertGreaterThan(bytesWritten, 0)
                bytesRemaining -= bytesWritten
                offset += bytesWritten
            }
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let bytesRead = read(fileDescriptor, &buffer, buffer.count)
            if bytesRead == 0 {
                break
            }
            XCTAssertGreaterThan(bytesRead, 0)
            response.append(contentsOf: buffer.prefix(bytesRead))
            if response.last == 0x0A {
                break
            }
        }

        while response.last == 0x0A || response.last == 0x0D {
            response.removeLast()
        }

        let decoder = JSONDecoder()
        return try decoder.decode(BurnBarRPCResponseEnvelope<Response>.self, from: response)
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
            for (index, byte) in pathBytes.enumerated() {
                rawBuffer[index] = byte
            }
        }

        return address
    }
}

import BurnBarCore
@testable import BurnBarDaemon
import Foundation
import XCTest

/// Cadence-boundary and cross-client parity coverage for the M5 API.
final class BurnBarFleetAPICadenceTests: BurnBarFleetRPCTestCase {
    func testReadersOverlapBlockedTickAndKeepGenerationCorrelated() async throws {
        let configuration = makeConfiguration(name: "api-generation")
        let generationState = GenerationProbeState()
        let service = makeGenerationTaggedService(
            configuration: configuration,
            cadenceSeconds: 1,
            generationState: generationState
        )
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: service)
        try await server.start()
        addTeardownBlock {
            await generationState.releaseBlockedGeneration()
            await server.stop()
        }

        let first = try await waitForSnapshot(socketPath: configuration.socketPath, timeout: 5)
        XCTAssertEqual(
            first.agents.first(where: { $0.id == .claudeCode })?.currentTask,
            "generation-1"
        )

        await generationState.armNextGeneration()
        try await waitUntilGenerationProbeIsBlocked(generationState)

        let overlappingSnapshots = try await readConcurrentSnapshots(socketPath: configuration.socketPath)

        XCTAssertEqual(overlappingSnapshots.count, 24)
        for snapshot in overlappingSnapshots {
            XCTAssertEqual(snapshot.generatedAt, first.generatedAt)
            XCTAssertEqual(
                snapshot.agents.first(where: { $0.id == .claudeCode })?.currentTask,
                "generation-1"
            )
            XCTAssertEqual(
                snapshot.runningCount,
                snapshot.agents.count(where: { $0.status == .running })
            )
            XCTAssertEqual(snapshot.countsByAgent.values.reduce(0, +), snapshot.runningCount)
        }

        await generationState.releaseBlockedGeneration()
        let second = try await waitForSnapshot(
            after: first,
            socketPath: configuration.socketPath
        )
        XCTAssertEqual(
            second.agents.first(where: { $0.id == .claudeCode })?.currentTask,
            "generation-2"
        )
        XCTAssertGreaterThan(second.generatedAt, first.generatedAt)
    }

    func testAppStyleRPCAndExternalFileReadersSeeSameGeneration() async throws {
        let configuration = makeConfiguration(name: "api-cross-client")
        let service = makePersistedFleetService(configuration: configuration, cadenceSeconds: 1)
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: service)
        try await server.start()
        addTeardownBlock { await server.stop() }
        let fileURL = URL(fileURLWithPath: configuration.fleetSnapshotFilePath)
        _ = try await waitForSnapshot(socketPath: configuration.socketPath, timeout: 5)
        _ = try await waitForFile(fileURL: fileURL)

        // The app FleetService and a documented external reader are separate
        // clients. Exercise both surfaces concurrently across cadence churn.
        for _ in 0..<12 {
            async let appSnapshot = appStyleSnapshot(socketPath: configuration.socketPath)
            async let externalSnapshot = documentedFileSnapshot(fileURL: fileURL)
            let (app, external) = try await (appSnapshot, externalSnapshot)
            // A concurrent file read may legally observe the preceding
            // complete generation during atomic rename; it may never observe
            // a torn payload or drift by more than one cadence generation.
            XCTAssertLessThanOrEqual(
                abs(app.generatedAt.timeIntervalSince(external.generatedAt)),
                1.1
            )
            XCTAssertEqual(app.agents, external.agents)
            XCTAssertEqual(app.runningCount, external.runningCount)
            XCTAssertEqual(app.countsByAgent, external.countsByAgent)
            try await Task.sleep(nanoseconds: 125_000_000)
        }
    }

    func testDefaultFactoryEnvironmentCadenceOverrideReachesRPCAndFile() async throws {
        let configuration = makeConfiguration(name: "api-default-cadence-env")
        let environment = [
            "BURNBAR_FLEET_CADENCE_SECONDS": "1",
            "BURNBAR_FLEET_ROOTS_DIR": tempRoots.appendingPathComponent("fixture-roots").path
        ]
        let service = BurnBarFleetServiceFactory.makeDefault(
            configuration: configuration,
            environment: environment
        )
        let resolvedCadence = await service.cadenceSeconds
        XCTAssertEqual(resolvedCadence, 1)

        let server = BurnBarDaemonServer(configuration: configuration, fleetService: service)
        try await server.start()
        addTeardownBlock { await server.stop() }

        let first = try await waitForSnapshot(socketPath: configuration.socketPath, timeout: 5)
        let fileURL = URL(fileURLWithPath: configuration.fleetSnapshotFilePath)
        let firstFile = try Self.rawJSONDictionary(from: Data(contentsOf: fileURL))
        XCTAssertEqual(first.cadenceSeconds, 1)
        XCTAssertEqual(firstFile["cadenceSeconds"] as? Int, 1)

        let second = try await waitForSnapshot(after: first, socketPath: configuration.socketPath, timeout: 5)
        XCTAssertEqual(second.cadenceSeconds, 1)
        XCTAssertGreaterThan(second.generatedAt, first.generatedAt)
    }

    private func readConcurrentSnapshots(socketPath: String) async throws -> [BurnBarFleetSnapshot] {
        try await withThrowingTaskGroup(of: [BurnBarFleetSnapshot].self) { group in
            for client in 0..<3 {
                group.addTask {
                    var snapshots: [BurnBarFleetSnapshot] = []
                    for requestIndex in 0..<8 {
                        let response = try self.rawRequest(
                            #"{"id":"reader-\#(client)-\#(requestIndex)","method":"daemon.fleet.snapshot"}"#,
                            socketPath: socketPath
                        )
                        snapshots.append(try Self.decodeSnapshot(from: response))
                    }
                    return snapshots
                }
            }

            var snapshots: [BurnBarFleetSnapshot] = []
            for try await clientSnapshots in group {
                snapshots.append(contentsOf: clientSnapshots)
            }
            return snapshots
        }
    }

    private func makeGenerationTaggedService(
        configuration: BurnBarDaemonConfiguration,
        cadenceSeconds: Int,
        generationState: GenerationProbeState
    ) -> BurnBarFleetService {
        var probes = makeProbes()
        let rootPath = tempRoots
            .appendingPathComponent(BurnBarFleetRootResolver.rootDirectoryName(for: .claudeCode), isDirectory: true)
            .path
        probes[.claudeCode] = GenerationTaggedProbe(rootPath: rootPath, state: generationState)
        return makePersistedFleetService(
            configuration: configuration,
            cadenceSeconds: cadenceSeconds,
            probes: probes
        )
    }

    private func waitUntilGenerationProbeIsBlocked(
        _ state: GenerationProbeState,
        timeout: TimeInterval = 5
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await state.isBlocked() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw APICadenceTestError.generationProbeDidNotBlock
    }

    private func waitForSnapshot(
        after previous: BurnBarFleetSnapshot,
        socketPath: String,
        timeout: TimeInterval = 10
    ) async throws -> BurnBarFleetSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let response = try? rawRequest(
                #"{"id":"wait-after","method":"daemon.fleet.snapshot"}"#,
                socketPath: socketPath
            ),
               let snapshot = try? Self.decodeSnapshot(from: response),
               snapshot.generatedAt > previous.generatedAt {
                return snapshot
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw APICadenceTestError.snapshotDidNotBecomeReady
    }

    private func waitForFile(fileURL: URL, timeout: TimeInterval = 5) async throws -> URL {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                return fileURL
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw APICadenceTestError.fileDidNotBecomeReady
    }

    private func appStyleSnapshot(socketPath: String) throws -> BurnBarFleetSnapshot {
        let response = try rawRequest(
            #"{"id":"app-fleet-service","method":"daemon.fleet.snapshot"}"#,
            socketPath: socketPath
        )
        return try Self.decodeSnapshot(from: response)
    }

    private func documentedFileSnapshot(fileURL: URL) async throws -> BurnBarFleetSnapshot {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let data = try? Data(contentsOf: fileURL),
               let snapshot = try? JSONDecoder().decode(BurnBarFleetSnapshot.self, from: data) {
                return snapshot
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw APICadenceTestError.invalidFileJSON
    }
}

private enum APICadenceTestError: Error {
    case snapshotDidNotBecomeReady
    case invalidFileJSON
    case fileDidNotBecomeReady
    case generationProbeDidNotBlock
}

private actor GenerationProbeState {
    private var generation = 0
    private var blockNextGeneration = false
    private var blocked = false
    private var released = false

    func armNextGeneration() {
        blockNextGeneration = true
        released = false
    }

    func beginGeneration() async -> Int {
        generation += 1
        guard blockNextGeneration else {
            return generation
        }
        blockNextGeneration = false
        blocked = true
        while !released {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        blocked = false
        released = false
        return generation
    }

    func isBlocked() -> Bool {
        blocked
    }

    func releaseBlockedGeneration() {
        released = true
    }
}

private struct GenerationTaggedProbe: BurnBarFleetProbe {
    let agentID: BurnBarFleetAgentID = .claudeCode
    let rootPath: String
    let state: GenerationProbeState

    func probe(now: Date) async -> BurnBarFleetProbeResult {
        let generation = await state.beginGeneration()
        let agent = BurnBarFleetAgent(
            id: .claudeCode,
            displayName: "Claude Code",
            status: .running,
            confidence: .activeSessionFile,
            currentTask: "generation-\(generation)",
            signals: [
                BurnBarFleetSignalSource(
                    kind: "generation-fixture",
                    path: "\(rootPath)/generation.json"
                )
            ]
        )
        return BurnBarFleetProbeResult(
            agent: agent,
            health: BurnBarFleetProbeHealth(
                agent: .claudeCode,
                state: .ok,
                rootPath: rootPath,
                checkedAt: now
            )
        )
    }
}

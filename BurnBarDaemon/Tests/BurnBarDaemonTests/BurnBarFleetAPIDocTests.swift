import BurnBarCore
import Foundation
import XCTest

@testable import BurnBarDaemon

/// Executes the shell blocks copied from BURNBAR_FLEET_API.md so socket
/// fallback, file lookup, and the embedded consumer cannot drift from the
/// documented contract.
final class BurnBarFleetAPIDocTests: BurnBarFleetRPCTestCase {
    func testDocumentedReaders_runVerbatimWithSupportDirectorySocketFallback() async throws {
        let supportDirectory = try makeShortSupportDirectory(name: "doc")
        let socketPath = supportDirectory.appendingPathComponent("burnbar-daemon.sock").path
        let configuration = BurnBarDaemonConfiguration(
            socketPath: socketPath,
            fleetStorePath: supportDirectory.appendingPathComponent("fleet.sqlite").path,
            fleetSnapshotFilePath: supportDirectory.appendingPathComponent("fleet-snapshot.json").path
        )
        let service = BurnBarFleetServiceFactory.makeDefault(
            configuration: configuration,
            environment: [
                "BURNBAR_FLEET_CADENCE_SECONDS": "1",
                "BURNBAR_FLEET_ROOTS_DIR": tempRoots.appendingPathComponent("fixture-roots").path
            ]
        )
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: service)
        addTeardownBlock {
            await server.stop()
            try? FileManager.default.removeItem(at: supportDirectory)
        }
        try await server.start()
        _ = try await waitForSnapshot(socketPath: socketPath, timeout: 5)

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = tempRoots.path
        environment["BURNBAR_DAEMON_SUPPORT_DIR"] = supportDirectory.path
        environment["BURNBAR_FLEET_USE_RPC"] = "1"
        environment.removeValue(forKey: "BURNBAR_DAEMON_SOCKET_PATH")
        environment.removeValue(forKey: "BURNBAR_FLEET_SNAPSHOT_PATH")

        let ncOutput = try runDocumentedShellBlock(
            heading: "### `nc -U` snapshot read",
            environment: environment
        )
        try assertSuccessfulEnvelope(ncOutput)

        let pythonOutput = try runDocumentedShellBlock(
            heading: "### Python 3 AF_UNIX snapshot read",
            environment: environment
        )
        try assertSuccessfulEnvelope(pythonOutput)

        let fileOutput = try runDocumentedShellBlock(
            heading: "### Read the well-known file",
            environment: environment
        )
        let fileObject = try jsonObject(fileOutput)
        XCTAssertEqual(fileObject["schemaVersion"] as? Int, 1)
        XCTAssertNotNil(fileObject["generatedAt"])
    }

    func testEmbeddedConsumer_runVerbatim_acceptsOmittedNonRunningCountsAndEvaluatesFreshness() async throws {
        let supportDirectory = try makeShortSupportDirectory(name: "consumer")
        let socketPath = supportDirectory.appendingPathComponent("burnbar-daemon.sock").path
        let configuration = BurnBarDaemonConfiguration(
            socketPath: socketPath,
            fleetStorePath: supportDirectory.appendingPathComponent("fleet.sqlite").path,
            fleetSnapshotFilePath: supportDirectory.appendingPathComponent("fleet-snapshot.json").path
        )
        let service = BurnBarFleetServiceFactory.makeDefault(
            configuration: configuration,
            environment: [
                "BURNBAR_FLEET_CADENCE_SECONDS": "1",
                "BURNBAR_FLEET_ROOTS_DIR": tempRoots.appendingPathComponent("fixture-roots").path
            ]
        )
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: service)
        addTeardownBlock {
            await server.stop()
            try? FileManager.default.removeItem(at: supportDirectory)
        }
        try await server.start()
        _ = try await waitForSnapshot(socketPath: socketPath, timeout: 5)

        let fixtureURL = try makeForwardCompatibleFixture(
            sourceURL: URL(fileURLWithPath: configuration.fleetSnapshotFilePath)
        )

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = tempRoots.path
        environment["BURNBAR_DAEMON_SUPPORT_DIR"] = supportDirectory.path
        environment["BURNBAR_FLEET_SNAPSHOT_PATH"] = fixtureURL.path
        environment.removeValue(forKey: "BURNBAR_DAEMON_SOCKET_PATH")
        environment.removeValue(forKey: "BURNBAR_FLEET_USE_RPC")

        let output = try runDocumentedShellBlock(
            heading: "## From-the-doc-alone Python consumer",
            environment: environment
        )
        let envelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        )
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        let freshness = try XCTUnwrap(result["freshness"] as? [String: Any])
        XCTAssertEqual(freshness["state"] as? String, "fresh")
        XCTAssertEqual(freshness["thresholdSeconds"] as? Int, 2)

        let validatedSnapshot = try XCTUnwrap(result["snapshot"] as? [String: Any])
        let validatedAgents = try XCTUnwrap(validatedSnapshot["agents"] as? [[String: Any]])
        XCTAssertTrue(validatedAgents.contains { $0["id"] as? String == "aider" })
        let validatedCounts = try XCTUnwrap(validatedSnapshot["countsByAgent"] as? [String: Any])
        XCTAssertNil(validatedCounts["kimi"])
        XCTAssertNil(validatedCounts["aider"])
    }

    func testSnapshotDocumentedPlainEnvelope_ignoresArbitraryParamsValue() async throws {
        let configuration = makeConfiguration(name: "snapshot-params")
        let service = makeFleetService()
        _ = try await service.buildOnce()
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: service)
        try await server.start()
        addTeardownBlock { await server.stop() }

        let response = try rawRequest(
            #"{"id":"snapshot-params","method":"daemon.fleet.snapshot","params":"ignored"}"#,
            socketPath: configuration.socketPath
        )
        let envelope = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarFleetSnapshotResponse>.self,
            from: Data(response.utf8)
        )
        XCTAssertNil(envelope.error)
        XCTAssertNotNil(envelope.result?.snapshot)
    }

    // MARK: - Restart/file freshness boundary follow-up (M5 scrutiny)

    func testDocumentedConsumer_restartKeepsLastGoodFile_untilNextCompletedTick() async throws {
        let supportDirectory = try makeShortSupportDirectory(name: "restart-freshness")
        let socketPath = supportDirectory.appendingPathComponent("burnbar-daemon.sock").path
        let configuration = BurnBarDaemonConfiguration(
            socketPath: socketPath,
            fleetStorePath: supportDirectory.appendingPathComponent("fleet.sqlite").path,
            fleetSnapshotFilePath: supportDirectory.appendingPathComponent("fleet-snapshot.json").path
        )
        let initialService = makePersistedFleetService(configuration: configuration, cadenceSeconds: 1)
        let initialServer = BurnBarDaemonServer(configuration: configuration, fleetService: initialService)
        try await initialServer.start()
        addTeardownBlock {
            await initialServer.stop()
            try? FileManager.default.removeItem(at: supportDirectory)
        }
        let first = try await waitForSnapshot(socketPath: socketPath, timeout: 5)
        let fileURL = URL(fileURLWithPath: configuration.fleetSnapshotFilePath)
        let lastGoodBytes = try Data(contentsOf: fileURL)
        await initialServer.stop()

        let gate = APIDocGateProbe(
            agentID: .claudeCode,
            rootPath: tempRoots.appendingPathComponent("fixture-roots/claude").path
        )
        var probes = makeProbes()
        probes[.claudeCode] = gate
        let restartedService = makePersistedFleetService(
            configuration: configuration,
            cadenceSeconds: 1,
            probes: probes
        )
        let restartedServer = BurnBarDaemonServer(
            configuration: configuration,
            fleetService: restartedService
        )
        addTeardownBlock {
            gate.release()
            await restartedServer.stop()
            try? FileManager.default.removeItem(at: supportDirectory)
        }
        try await restartedServer.start()

        // The restarted daemon is in its pre-first-tick window. The
        // doc-specified file reader must still see the complete prior
        // generation, not an empty placeholder or a partially replaced file.
        let environment = documentedFileEnvironment(
            supportDirectory: supportDirectory,
            fileURL: fileURL
        )
        let duringRestart = try runDocumentedShellBlock(
            heading: "## From-the-doc-alone Python consumer",
            environment: environment
        )
        let duringObject = try consumerResult(duringRestart)
        let duringSnapshot = try XCTUnwrap(duringObject["snapshot"] as? [String: Any])
        XCTAssertEqual(duringSnapshot["generatedAt"] as? String, isoString(first.generatedAt))
        XCTAssertEqual(try Data(contentsOf: fileURL), lastGoodBytes)
        XCTAssertEqual(
            (duringObject["freshness"] as? [String: Any])?["state"] as? String,
            "fresh"
        )

        // Releasing the first probe lets the new daemon publish. The file
        // must remain the old generation until this completed-tick barrier,
        // then advance to the new generation.
        gate.release()
        let next = try await waitForNewerSnapshot(
            after: first,
            socketPath: socketPath,
            timeout: 5
        )
        let persistedAfterTick = try Data(contentsOf: fileURL)
        let afterTick = try JSONDecoder().decode(BurnBarFleetSnapshot.self, from: persistedAfterTick)
        XCTAssertEqual(afterTick.generatedAt, next.generatedAt)
        XCTAssertNotEqual(persistedAfterTick, lastGoodBytes)
    }

    func testDocumentedConsumer_shutdownGeneration_staysReadable_thenBecomesStale() async throws {
        let supportDirectory = try makeShortSupportDirectory(name: "shutdown-freshness")
        let socketPath = supportDirectory.appendingPathComponent("burnbar-daemon.sock").path
        let configuration = BurnBarDaemonConfiguration(
            socketPath: socketPath,
            fleetStorePath: supportDirectory.appendingPathComponent("fleet.sqlite").path,
            fleetSnapshotFilePath: supportDirectory.appendingPathComponent("fleet-snapshot.json").path
        )
        let service = makePersistedFleetService(configuration: configuration, cadenceSeconds: 1)
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: service)
        addTeardownBlock {
            await server.stop()
            try? FileManager.default.removeItem(at: supportDirectory)
        }
        try await server.start()
        let generation = try await waitForSnapshot(socketPath: socketPath, timeout: 5)
        await server.stop()

        let environment = documentedFileEnvironment(
            supportDirectory: supportDirectory,
            fileURL: URL(fileURLWithPath: configuration.fleetSnapshotFilePath)
        )
        let immediatelyAfterShutdown = try runDocumentedShellBlock(
            heading: "## From-the-doc-alone Python consumer",
            environment: environment
        )
        let immediateObject = try consumerResult(immediatelyAfterShutdown)
        let immediateSnapshot = try XCTUnwrap(immediateObject["snapshot"] as? [String: Any])
        XCTAssertEqual(immediateSnapshot["generatedAt"] as? String, isoString(generation.generatedAt))

        // The daemon is down, so no new generation can arrive. After the
        // documented strict > 2*cadence boundary the same old generation is
        // still readable but must be classified stale.
        try await Task.sleep(nanoseconds: 2_200_000_000)
        let staleOutput = try runDocumentedShellBlock(
            heading: "## From-the-doc-alone Python consumer",
            environment: environment
        )
        let staleObject = try consumerResult(staleOutput)
        XCTAssertEqual(
            (staleObject["freshness"] as? [String: Any])?["state"] as? String,
            "stale"
        )
    }

    func testDocumentedConsumer_freshnessBoundary_usesStrictGreaterThan() throws {
        var base = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(try makeSnapshotFixture())
            ) as? [String: Any]
        )
        base["cadenceSeconds"] = 100

        let boundaryRoot = tempRoots.appendingPathComponent("freshness-boundary")
        try FileManager.default.createDirectory(at: boundaryRoot, withIntermediateDirectories: true)
        let environment = ProcessInfo.processInfo.environment.merging(
            ["BURNBAR_FLEET_SNAPSHOT_PATH": boundaryRoot.appendingPathComponent("snapshot.json").path],
            uniquingKeysWith: { _, new in new }
        )

        var fresh = base
        fresh["generatedAt"] = isoString(Date().addingTimeInterval(-199.0))
        try JSONSerialization.data(withJSONObject: fresh).write(
            to: URL(fileURLWithPath: environment["BURNBAR_FLEET_SNAPSHOT_PATH"]!)
        )
        let freshObject = try consumerResult(
            runDocumentedShellBlock(
                heading: "## From-the-doc-alone Python consumer",
                environment: environment
            )
        )
        XCTAssertEqual((freshObject["freshness"] as? [String: Any])?["thresholdSeconds"] as? Int, 200)
        XCTAssertEqual((freshObject["freshness"] as? [String: Any])?["state"] as? String, "fresh")

        var stale = base
        stale["generatedAt"] = isoString(Date().addingTimeInterval(-201.0))
        try JSONSerialization.data(withJSONObject: stale).write(
            to: URL(fileURLWithPath: environment["BURNBAR_FLEET_SNAPSHOT_PATH"]!)
        )
        let staleObject = try consumerResult(
            runDocumentedShellBlock(
                heading: "## From-the-doc-alone Python consumer",
                environment: environment
            )
        )
        XCTAssertEqual((staleObject["freshness"] as? [String: Any])?["state"] as? String, "stale")
    }

    private func runDocumentedShellBlock(
        heading: String,
        environment: [String: String]
    ) throws -> String {
        let document = try String(contentsOf: apiDocumentURL, encoding: .utf8)
        let block = try shellBlock(after: heading, in: document)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", block]
        process.environment = environment
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(bytes: outputData, encoding: .utf8) ?? ""
        let error = String(bytes: errorData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw APIDocTestError.shellFailed(
                heading: heading,
                status: process.terminationStatus,
                stderr: error
            )
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func documentedFileEnvironment(
        supportDirectory: URL,
        fileURL: URL
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = tempRoots.path
        environment["BURNBAR_DAEMON_SUPPORT_DIR"] = supportDirectory.path
        environment["BURNBAR_FLEET_SNAPSHOT_PATH"] = fileURL.path
        environment.removeValue(forKey: "BURNBAR_DAEMON_SOCKET_PATH")
        environment.removeValue(forKey: "BURNBAR_FLEET_USE_RPC")
        return environment
    }

    private func consumerResult(_ output: String) throws -> [String: Any] {
        let envelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        )
        return try XCTUnwrap(envelope["result"] as? [String: Any])
    }

    private func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func makeSnapshotFixture() throws -> BurnBarFleetSnapshot {
        var agents: [BurnBarFleetAgent] = []
        var health: [BurnBarFleetProbeHealth] = []
        let now = Date()
        for agentID in BurnBarFleetAgentID.declaredRoster {
            agents.append(
                BurnBarFleetAgent(
                    id: agentID,
                    displayName: BurnBarFleetSnapshotBuilder.displayName(for: agentID),
                    status: .unknown,
                    confidence: .unsupported,
                    signals: [
                        BurnBarFleetSignalSource(
                            kind: "fixture",
                            path: "/tmp/fleet/\(agentID.wireValue)"
                        )
                    ]
                )
            )
            health.append(
                BurnBarFleetProbeHealth(
                    agent: agentID,
                    state: .ok,
                    rootPath: "/tmp/fleet/\(agentID.wireValue)",
                    checkedAt: now
                )
            )
        }
        return BurnBarFleetSnapshot(
            schemaVersion: 1,
            generatedAt: now,
            cadenceSeconds: 100,
            machine: BurnBarMachineStatus(
                memoryTotalBytes: 1,
                thermal: .unavailable(reason: "fixture"),
                power: .unavailable(reason: "fixture")
            ),
            agents: agents,
            repos: [],
            runningCount: 0,
            countsByAgent: Dictionary(uniqueKeysWithValues: agents.map { ($0.id.wireValue, 0) }),
            orchestrator: BurnBarOrchestratorState(designation: .none),
            probeHealth: health,
            persistenceHealth: .ok
        )
    }

    private func assertSuccessfulEnvelope(_ output: String) throws {
        let envelope = try jsonObject(output)
        XCTAssertNotNil(envelope["result"])
    }

    private func jsonObject(_ output: String) throws -> [String: Any] {
        try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        )
    }

    private func makeForwardCompatibleFixture(sourceURL: URL) throws -> URL {
        let source = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: sourceURL)) as? [String: Any]
        )
        var fixture = source
        var agents = try XCTUnwrap(fixture["agents"] as? [[String: Any]])
        agents.append([
            "id": "aider",
            "displayName": "Aider",
            "status": "idle",
            "confidence": "unsupported",
            "signals": [["kind": "future-fixture", "path": "/tmp/aider"]]
        ])
        fixture["agents"] = agents

        var counts = try XCTUnwrap(fixture["countsByAgent"] as? [String: Any])
        counts.removeValue(forKey: "kimi")
        counts.removeValue(forKey: "aider")
        fixture["countsByAgent"] = counts
        fixture["futureExtension"] = ["ignored": true]

        let fixtureURL = tempRoots.appendingPathComponent("forward-compatible.json")
        try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys]).write(to: fixtureURL)
        return fixtureURL
    }

    private func makeShortSupportDirectory(name: String) throws -> URL {
        let suffix = String(UUID().uuidString.prefix(8))
        let url = URL(fileURLWithPath: "/tmp/burnbar-\(name)-\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func shellBlock(after heading: String, in document: String) throws -> String {
        guard let headingRange = document.range(of: heading) else {
            throw APIDocTestError.missingHeading(heading)
        }
        let remainder = document[headingRange.upperBound...]
        guard let opening = remainder.range(of: "```sh\n") else {
            throw APIDocTestError.missingShellBlock(heading)
        }
        let bodyStart = opening.upperBound
        guard let closing = remainder.range(of: "\n```\n", range: bodyStart..<remainder.endIndex) else {
            throw APIDocTestError.unterminatedShellBlock(heading)
        }
        return String(remainder[bodyStart..<closing.lowerBound])
    }

    private var apiDocumentURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/fleet/BURNBAR_FLEET_API.md")
    }
}

private final class APIDocGateProbe: BurnBarFleetProbe, @unchecked Sendable {
    let agentID: BurnBarFleetAgentID
    let rootPath: String
    private let gate = DispatchSemaphore(value: 0)

    init(agentID: BurnBarFleetAgentID, rootPath: String) {
        self.agentID = agentID
        self.rootPath = rootPath
    }

    func probe(now: Date) async -> BurnBarFleetProbeResult {
        gate.wait()
        return BurnBarFleetProbeResult(
            agent: BurnBarFleetAgent(
                id: agentID,
                displayName: BurnBarFleetSnapshotBuilder.displayName(for: agentID),
                status: .unknown,
                confidence: .unsupported,
                signals: [BurnBarFleetSignalSource(kind: "fixture", path: "\(rootPath)/gate")]
            ),
            health: BurnBarFleetProbeHealth(
                agent: agentID,
                state: .ok,
                rootPath: rootPath,
                checkedAt: now
            )
        )
    }

    func release() {
        gate.signal()
    }
}

private enum APIDocTestError: Error {
    case missingHeading(String)
    case missingShellBlock(String)
    case unterminatedShellBlock(String)
    case shellFailed(heading: String, status: Int32, stderr: String)
}

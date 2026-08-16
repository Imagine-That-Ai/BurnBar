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

private enum APIDocTestError: Error {
    case missingHeading(String)
    case missingShellBlock(String)
    case unterminatedShellBlock(String)
    case shellFailed(heading: String, status: Int32, stderr: String)
}

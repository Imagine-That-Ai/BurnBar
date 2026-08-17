import OpenBurnBarKernel
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

/// Typed unsupported probe tests (kimi, gemini-cli): always a typed
/// `unknown`/`unsupported` row, never omitted, never presented as live.
final class BurnBarFleetUnsupportedProbeTests: XCTestCase {
    private var fixtureRoot: URL!

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-unsupported-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
    }

    func testKimi_rootPresent_unknownUnsupportedOkHealth() async throws {
        let now = Date()
        let result = await BurnBarFleetUnsupportedProbe(
            agentID: .kimi,
            rootPath: fixtureRoot.path,
            note: "No live signal is claimed for Kimi."
        ).probe(now: now)

        XCTAssertEqual(result.agent.id, .kimi)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.health.state, .ok)
        XCTAssertEqual(result.health.rootPath, fixtureRoot.path)
        XCTAssertEqual(result.agent.note?.contains("No live signal"), true)
    }

    func testGeminiCLI_rootMissing_failedHealthUnknownRow() async throws {
        let now = Date()
        let missingRoot = fixtureRoot.appendingPathComponent("missing", isDirectory: true).path
        let result = await BurnBarFleetUnsupportedProbe(
            agentID: .geminiCLI,
            rootPath: missingRoot,
            note: "No live signal is claimed for Gemini CLI."
        ).probe(now: now)

        XCTAssertEqual(result.agent.id, .geminiCLI)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        if case .failed(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("Declared root missing"), "unexpected reason: \(reason)")
        } else {
            XCTFail("missing root must be typed failed, got \(result.health.state)")
        }
    }

    func testNeverRunningRegardlessOfRootContent() async throws {
        let now = Date()
        // Plant fresh-looking content in the root: unsupported probes must
        // ignore it entirely.
        let freshFile = fixtureRoot.appendingPathComponent("fresh-signal.txt").path
        try "fresh".write(toFile: freshFile, atomically: true, encoding: .utf8)
        try setFileMtime(now, at: freshFile)

        let result = await BurnBarFleetUnsupportedProbe(
            agentID: .kimi,
            rootPath: fixtureRoot.path,
            note: "No live signal is claimed for Kimi."
        ).probe(now: now)

        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertTrue(result.agent.signals.isEmpty)
    }
}

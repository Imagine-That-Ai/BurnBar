@testable import BurnBarDaemon
import Foundation
import XCTest

final class BurnBarFleetFactoryAttributionScrutinyTests: XCTestCase {
    private var fixtureRoot: URL!
    private var liveProcess: LiveSleepProcess?

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-factory-attribution-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        liveProcess?.terminate()
        liveProcess = nil
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
    }

    func testLiveEvidence_prefersInvocationCwdOverNewerBackgroundAndSessionEvidence() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        try writeJSONFixture(
            [
                "invocations": [[
                    "cwd": "/Users/test/invocation-repo",
                    "status": "running",
                    "updatedAt": Int((now.addingTimeInterval(-120).timeIntervalSince1970) * 1000)
                ]]
            ],
            to: fixtureRoot.appendingPathComponent("task-invocations.json").path
        )
        try writeJSONFixture(
            [
                "processes": [[
                    "pid": Int(live.pid),
                    "cwd": "/Users/test/background-repo",
                    "startTime": Int(now.timeIntervalSince1970 * 1000)
                ]]
            ],
            to: fixtureRoot.appendingPathComponent("background-processes.json").path
        )
        let sessionsURL = fixtureRoot.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        let sessionURL = sessionsURL.appendingPathComponent("-Users-test-session-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionURL, withIntermediateDirectories: true)
        try setFileMtime(now, at: sessionURL.path)

        let result = await BurnBarFleetFactoryDroidProbe(rootPath: fixtureRoot.path).probe(now: now)

        XCTAssertEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.projectName, "/Users/test/invocation-repo")
    }
}

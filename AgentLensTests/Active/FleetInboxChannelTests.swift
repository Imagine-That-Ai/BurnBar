import XCTest
@testable import OpenBurnBar

final class FleetInboxChannelTests: XCTestCase {
    func test_inboxWrite_is0600AndKeyedByAgentAndSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-inbox-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let channel = FleetInboxChannel(inboxRoot: root)
        let directive = BurnBarFleetDirective(
            id: "dir-1",
            kind: .askStatus,
            targetAgent: .claudeCode,
            sessionRef: "sess-9",
            payload: "status please",
            state: .approved,
            createdAt: Date(timeIntervalSince1970: 1_752_000_000)
        )
        let outcome = await channel.deliver(directive)
        XCTAssertEqual(outcome, .submitted)

        let file = root
            .appendingPathComponent("claude-code", isDirectory: true)
            .appendingPathComponent("sess-9.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let mode = attributes[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)

        let body = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(body.contains("\"sessionRef\":\"sess-9\""))
        XCTAssertTrue(body.contains("\"targetAgent\":\"claude-code\""))
        XCTAssertTrue(body.contains("dir-1"))
    }

    func test_inboxSupportsEveryRosterCLI() {
        let channel = FleetInboxChannel(
            inboxRoot: FileManager.default.temporaryDirectory.appendingPathComponent("x")
        )
        for agent in BurnBarFleetAgentID.declaredRoster {
            XCTAssertTrue(channel.supports(targetAgent: agent), agent.wireValue)
        }
    }

    func test_rejectsPathTraversalSessionRef() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-inbox-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let channel = FleetInboxChannel(inboxRoot: root)
        let directive = BurnBarFleetDirective(
            id: "dir-2",
            kind: .custom,
            targetAgent: .codex,
            sessionRef: "../escape",
            payload: "nope",
            state: .approved,
            createdAt: Date()
        )
        let outcome = await channel.deliver(directive)
        guard case .failed = outcome else {
            XCTFail("expected failed, got \(outcome)")
            return
        }
    }
}

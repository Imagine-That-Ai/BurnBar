import XCTest
import Foundation
@testable import OpenBurnBarCore

final class CLIAgentSessionCodecTests: XCTestCase {

    func test_roundTrip_preservesEveryField() throws {
        let started = Date(timeIntervalSince1970: 1_730_000_000)
        let updated = started.addingTimeInterval(60)
        let endedAt = started.addingTimeInterval(120)
        let record = CLIAgentSessionRecord(
            id: "thread-1",
            agent: .codex,
            title: "Refactor login flow",
            preview: "Final answer text…",
            modelName: "gpt-5.5",
            workspaceLabel: "BurnBar",
            createdAt: started,
            updatedAt: updated,
            endedAt: endedAt,
            messages: [
                CLIAgentMessage(
                    id: "m-1",
                    role: .user,
                    text: "Refactor the login flow.",
                    timestamp: started
                ),
                CLIAgentMessage(
                    id: "m-2",
                    role: .assistant,
                    text: "Sure — I'll read the auth files first.",
                    timestamp: updated,
                    toolUses: [
                        CLIAgentToolUse(
                            id: "t-1",
                            name: "Read",
                            status: "done",
                            detail: "AgentLens/Services/AuthRepository.swift",
                            startedAt: updated
                        )
                    ]
                )
            ],
            tokenUsage: CLIAgentTokenUsage(inputTokens: 320, outputTokens: 1200)
        )

        let encoded = CLIAgentSessionCodec.encode(record)
        let decoded = try XCTUnwrap(
            CLIAgentSessionCodec.decode(documentID: record.id, data: encoded)
        )

        XCTAssertEqual(decoded.id, record.id)
        XCTAssertEqual(decoded.agent, .codex)
        XCTAssertEqual(decoded.title, "Refactor login flow")
        XCTAssertEqual(decoded.preview, "Final answer text…")
        XCTAssertEqual(decoded.modelName, "gpt-5.5")
        XCTAssertEqual(decoded.workspaceLabel, "BurnBar")
        XCTAssertEqual(decoded.createdAt.timeIntervalSince1970, started.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(decoded.updatedAt.timeIntervalSince1970, updated.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(decoded.endedAt?.timeIntervalSince1970, endedAt.timeIntervalSince1970)
        XCTAssertEqual(decoded.messages.count, 2)
        XCTAssertEqual(decoded.messages[1].toolUses.first?.name, "Read")
        XCTAssertEqual(decoded.messages[1].toolUses.first?.detail, "AgentLens/Services/AuthRepository.swift")
        XCTAssertEqual(decoded.tokenUsage?.inputTokens, 320)
        XCTAssertEqual(decoded.tokenUsage?.outputTokens, 1200)
    }

    func test_decode_returnsNilForFutureSchemaVersion() {
        let payload: [String: Any] = [
            "id": "x",
            "agent": "codex",
            "title": "future schema",
            "preview": "",
            "createdAt": Date(),
            "updatedAt": Date(),
            "schemaVersion": CLIAgentSessionRecord.currentSchemaVersion + 1,
            "messages": []
        ]
        XCTAssertNil(CLIAgentSessionCodec.decode(documentID: "x", data: payload))
    }

    func test_decode_returnsNilForUnknownAgent() {
        let payload: [String: Any] = [
            "id": "x",
            "agent": "mysterynewagent",
            "title": "",
            "preview": "",
            "createdAt": Date(),
            "updatedAt": Date(),
            "messages": []
        ]
        XCTAssertNil(CLIAgentSessionCodec.decode(documentID: "x", data: payload))
    }

    func test_decode_toleratesMissingOptionalFields() throws {
        let payload: [String: Any] = [
            "agent": "claude",
            "createdAt": Date(),
            "updatedAt": Date(),
            "messages": []
        ]
        let decoded = try XCTUnwrap(
            CLIAgentSessionCodec.decode(documentID: "fallback-id", data: payload)
        )
        XCTAssertEqual(decoded.id, "fallback-id")
        XCTAssertEqual(decoded.title, "CLI session")
        XCTAssertEqual(decoded.preview, "")
        XCTAssertNil(decoded.modelName)
        XCTAssertNil(decoded.workspaceLabel)
        XCTAssertNil(decoded.endedAt)
        XCTAssertTrue(decoded.messages.isEmpty)
        XCTAssertNil(decoded.tokenUsage)
    }

    func test_decodeMessage_returnsNilForMalformedRecord() {
        // Missing required `role` -> no message.
        let raw: [String: Any] = [
            "id": "msg",
            "text": "hi"
        ]
        XCTAssertNil(CLIAgentSessionCodec.decodeMessage(raw))
    }

    func test_encodeToolUse_omitsBlankDetail() {
        let tool = CLIAgentToolUse(
            id: "t",
            name: "Bash",
            status: "done",
            detail: "   ",
            startedAt: Date()
        )
        let encoded = CLIAgentSessionCodec.encodeToolUse(tool)
        // Blank detail is preserved as-is on encode (writers may want it);
        // the decoder is where the trim-to-nil happens.
        let decoded = CLIAgentSessionCodec.decodeToolUse(encoded)
        XCTAssertEqual(decoded?.id, "t")
        XCTAssertNil(decoded?.detail)
    }
}

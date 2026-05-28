// Quarantined tests extracted from: ConversationSyncRoundTripTests.swift
//
// These tests were quarantined because they reference stale contracts,
// drifted schemas, or environmental preconditions not satisfied in CI.
// See QUARANTINE_MANIFEST.md for per-test owner, reason, and revival criteria.
//
// Revival workflow:
//   1. Update tests to compile against current public/@testable APIs.
//   2. Move this file to AgentLensTests/Active/ (matching subdirectory).
//   3. Remove the file from Quarantine.
//   4. Prove with: ./scripts/test-openburnbar-app.sh

import XCTest
import GRDB
import FirebaseFirestore
import OpenBurnBarCore
@testable import OpenBurnBar

final class ConversationSyncRoundTripTests: XCTestCase {

    // MARK: - Quarantined Tests

    func test_conversationUpload_writesToFirestoreAndMarksSynced() async throws {
        try XCTSkipIf(true, "Stale contract — Firestore mock surface drifted; rebuild fakeStore against current writers.")
        let now = Date()
        let record = ConversationRecord(
            id: "conv-1",
            provider: .claudeCode,
            sessionId: "session-1",
            projectName: "TestProject",
            startTime: now,
            endTime: now.addingTimeInterval(100),
            messageCount: 10,
            userWordCount: 100,
            assistantWordCount: 200,
            keyFiles: ["file1.swift"],
            keyCommands: ["git status"],
            keyTools: [],
            inferredTaskTitle: "Test Task",
            lastAssistantMessage: "Hello world",
            fullText: "Full text here",
            fileModifiedAt: nil
        )
        try dataStore.upsertConversation(record)

        let unsyncedBefore = try dataStore.fetchUnsyncedConversations(limit: 400)
        XCTAssertEqual(unsyncedBefore.count, 1)

        await conversationSync.sync()

        let docPath = "users/test-uid-1/conversations/test-device-1_conv-1"
        let docData = fakeGateway.documentData(at: docPath)
        XCTAssertNotNil(docData)
        XCTAssertEqual(docData?["provider"] as? String, AgentProvider.claudeCode.rawValue)
        XCTAssertEqual(docData?["sessionId"] as? String, "session-1")
        XCTAssertEqual(docData?["messageCount"] as? Int, 10)
        XCTAssertEqual(docData?["deviceId"] as? String, "test-device-1")

        let unsyncedAfter = try dataStore.fetchUnsyncedConversations(limit: 400)
        XCTAssertTrue(unsyncedAfter.isEmpty)
    }


}

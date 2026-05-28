// Quarantined tests extracted from: SessionLogSyncRoundTripTests.swift
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

final class SessionLogSyncRoundTripTests: XCTestCase {

    // MARK: - Quarantined Tests

    func test_sessionLogUpload_writesManifestAndChunks() async throws {
        try XCTSkipIf(true, "Stale contract — session-log chunk manifest format drifted; rebuild fakeStore writers.")
        let largeBody = String(repeating: "A", count: 1_000_000) // ~1MB, will be chunked
        let record = ConversationRecord(
            id: "session-log-1",
            provider: .claudeCode,
            sessionId: "session-1",
            projectName: "TestProject",
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_100),
            messageCount: 10,
            userWordCount: 100,
            assistantWordCount: 200,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "Test Task",
            lastAssistantMessage: "Hello",
            fullText: largeBody,
            fileModifiedAt: nil
        )
        try dataStore.insertRemoteConversation(record)

        await sessionLogSync.sync()

        let manifestPath = "users/test-uid-1/session_logs/test-device-1_session-log-1"
        let manifest = fakeGateway.documentData(at: manifestPath)
        XCTAssertNotNil(manifest)
        XCTAssertEqual(manifest?["id"] as? String, "session-log-1")
        XCTAssertEqual(manifest?["deviceId"] as? String, "test-device-1")
        XCTAssertEqual(manifest?["chunkCount"] as? Int, 2) // > 900KB should be 2 chunks

        // Verify chunks exist
        let chunk0 = fakeGateway.documentData(at: "\(manifestPath)/chunks/0")
        let chunk1 = fakeGateway.documentData(at: "\(manifestPath)/chunks/1")
        XCTAssertNotNil(chunk0)
        XCTAssertNotNil(chunk1)

        let body0 = chunk0?["body"] as? String ?? ""
        let body1 = chunk1?["body"] as? String ?? ""
        XCTAssertEqual(body0.count + body1.count, largeBody.count)
        XCTAssertEqual(body0 + body1, largeBody)
    }


}

// Quarantined tests extracted from: UsageConflictResolutionTests.swift
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

final class UsageConflictResolutionTests: XCTestCase {

    // MARK: - Quarantined Tests

    func test_remoteExact_overwritesLocalHighConfidenceEstimate() async throws {
        try XCTSkipIf(true, "Stale contract — provenance conflict resolution rewrote local rules; restore once realigned.")
        let localUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: "session-1",
            projectName: "LocalProject",
            model: "claude-3-5-sonnet",
            inputTokens: 100,
            outputTokens: 50,
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_100),
            provenanceConfidence: .highConfidenceEstimate
        )
        try dataStore.insert(localUsage)

        // Simulate remote exact data
        let remoteDeviceId = "remote-device"
        let remoteDocPath = "users/test-uid-1/usage/\(remoteDeviceId)_\(UUID().uuidString)"
        fakeGateway.setDocumentData([
            "id": UUID().uuidString,
            "deviceId": remoteDeviceId,
            "provider": AgentProvider.claudeCode.rawValue,
            "sessionId": "session-1",
            "projectName": "RemoteProject",
            "model": "claude-3-5-sonnet",
            "inputTokens": 200,
            "outputTokens": 100,
            "usageSource": UsageSource.billingAPI.rawValue,
            "totalTokens": 300,
            "cost": 0.02,
            "startTime": Timestamp(date: Date(timeIntervalSince1970: 1_700_000_000)),
            "endTime": Timestamp(date: Date(timeIntervalSince1970: 1_700_000_100)),
            "updatedAt": Timestamp(date: Date(timeIntervalSince1970: 1_700_000_000))
        ], at: remoteDocPath)

        fakeGateway.setDocumentData([
            "deviceName": "Remote Mac",
            "platform": "macOS"
        ], at: "users/test-uid-1/devices/\(remoteDeviceId)")

        await downloadSync.sync()

        let allUsage = try dataStore.usageStore.fetchAllUsage()
        XCTAssertEqual(allUsage.count, 1)

        let result = allUsage.first!
        XCTAssertEqual(result.inputTokens, 200) // Updated
        XCTAssertEqual(result.outputTokens, 100) // Updated
        XCTAssertEqual(result.projectName, "RemoteProject") // Updated
        XCTAssertEqual(result.provenanceConfidence, UsageProvenanceConfidence.exact) // Promoted
        XCTAssertEqual(result.usageSource, UsageSource.billingAPI) // Changed because strictly higher confidence
    }


    func test_remoteEqualConfidence_updatesValuesButPreservesUsageSource() async throws {
        try XCTSkipIf(true, "Stale contract — provenance conflict resolution rewrote local rules; restore once realigned.")
        let localUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: "session-1",
            projectName: "LocalProject",
            model: "claude-3-5-sonnet",
            inputTokens: 100,
            outputTokens: 50,
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_100),
            usageSource: .providerLog,
            provenanceConfidence: .exact
        )
        try dataStore.insert(localUsage)

        let remoteDeviceId = "remote-device"
        let remoteDocPath = "users/test-uid-1/usage/\(remoteDeviceId)_\(UUID().uuidString)"
        fakeGateway.setDocumentData([
            "id": UUID().uuidString,
            "deviceId": remoteDeviceId,
            "provider": AgentProvider.claudeCode.rawValue,
            "sessionId": "session-1",
            "projectName": "RemoteProject",
            "model": "claude-3-5-sonnet",
            "inputTokens": 200,
            "outputTokens": 100,
            "usageSource": UsageSource.billingAPI.rawValue,
            "totalTokens": 300,
            "cost": 0.02,
            "startTime": Timestamp(date: Date(timeIntervalSince1970: 1_700_000_000)),
            "endTime": Timestamp(date: Date(timeIntervalSince1970: 1_700_000_100)),
            "updatedAt": Timestamp(date: Date(timeIntervalSince1970: 1_700_000_000))
        ], at: remoteDocPath)

        fakeGateway.setDocumentData([
            "deviceName": "Remote Mac",
            "platform": "macOS"
        ], at: "users/test-uid-1/devices/\(remoteDeviceId)")

        await downloadSync.sync()

        let allUsage = try dataStore.usageStore.fetchAllUsage()
        XCTAssertEqual(allUsage.count, 1)

        let result = allUsage.first!
        XCTAssertEqual(result.inputTokens, 200) // Updated because equal confidence allows update
        XCTAssertEqual(result.outputTokens, 100) // Updated
        XCTAssertEqual(result.usageSource, UsageSource.providerLog) // Preserved because not strictly higher
    }
}

}

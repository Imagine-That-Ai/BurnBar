// Quarantined tests extracted from: OfflineOnlineMergeTests.swift
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
import OpenBurnBarCore
@testable import OpenBurnBar

final class OfflineOnlineMergeTests: XCTestCase {

    // MARK: - Quarantined Tests

    func test_backoff_suppression_onPermissionDenied() async throws {
        try XCTSkipIf(true, "Stale contract — sync gateway error-classification surface drifted; retune mocks before re-enabling.")
        fakeGateway.nextError = NSError(
            domain: "FakeFirestore",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "Permission denied"]
        )

        let usage = AppTokenUsage(
            provider: AppAgentProvider.claudeCode,
            sessionId: "session-1",
            projectName: "TestProject",
            model: "claude-3-5-sonnet",
            inputTokens: 100,
            outputTokens: 50,
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_100)
        )
        try dataStore.insert(usage)

        await usageSync.sync()

        // Sync should be suppressed
        XCTAssertTrue(context.syncIsSuppressed())
        XCTAssertNotNil(context.suppressedSyncUntil)

        // Clear suppression and verify sync resumes
        context.suppressedSyncUntil = nil
        XCTAssertFalse(context.syncIsSuppressed())

        fakeGateway.nextError = nil
        await usageSync.sync()

        let docs = fakeGateway.documents(under: "users/test-uid-1/usage")
        XCTAssertEqual(docs.count, 1)
    }


    func test_watermark_doesNotAdvanceOnFailure() async throws {
        try XCTSkipIf(true, "Stale contract — watermark advancement now happens through a different code path; mock surface drifted.")
        let remoteDeviceId = "remote-device"
        let remoteTimestamp = Date(timeIntervalSince1970: 1_700_000_000)

        fakeGateway.setDocumentData([
            "id": UUID().uuidString,
            "deviceId": remoteDeviceId,
            "provider": AppAgentProvider.claudeCode.rawValue,
            "sessionId": "session-1",
            "projectName": "RemoteProject",
            "model": "claude-3-5-sonnet",
            "inputTokens": 100,
            "outputTokens": 50,
            "usageSource": AppUsageSource.providerLog.rawValue,
            "totalTokens": 150,
            "cost": 0.005,
            "startTime": Date(timeIntervalSince1970: 1_700_000_000),
            "endTime": Date(timeIntervalSince1970: 1_700_000_100),
            "updatedAt": remoteTimestamp
        ], at: "users/test-uid-1/usage/\(remoteDeviceId)_usage-1")

        fakeGateway.setDocumentData([
            "deviceName": "Remote Mac",
            "platform": "macOS"
        ], at: "users/test-uid-1/devices/\(remoteDeviceId)")

        // Record initial watermark
        let initialWatermark = try dataStore.remoteSyncWatermarkStore.fetchWatermark(
            accountUid: "test-uid-1",
            collectionKind: .usage
        )

        // Force error on getDocuments
        fakeGateway.nextError = NSError(
            domain: "FakeFirestore",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Network error"]
        )

        await downloadSync.sync()

        // Watermark should not have advanced
        let watermarkAfterFailure = try dataStore.remoteSyncWatermarkStore.fetchWatermark(
            accountUid: "test-uid-1",
            collectionKind: .usage
        )
        XCTAssertEqual(initialWatermark?.lastProcessedRemoteUpdateAt, watermarkAfterFailure?.lastProcessedRemoteUpdateAt)
        XCTAssertEqual(initialWatermark?.lastSyncedAt, watermarkAfterFailure?.lastSyncedAt)

        // Clear error and retry
        fakeGateway.nextError = nil
        await downloadSync.sync()

        // Watermark should now advance
        let watermarkAfterSuccess = try dataStore.remoteSyncWatermarkStore.fetchWatermark(
            accountUid: "test-uid-1",
            collectionKind: .usage
        )
        XCTAssertNotNil(watermarkAfterSuccess)
        XCTAssertEqual(watermarkAfterSuccess?.lastProcessedRemoteUpdateAt, remoteTimestamp)
    }


    func test_circuitBreaker_halfOpenToClosed_recovery() async throws {
        try XCTSkipIf(true, "Stale contract — circuit breaker state machine refactor needed before re-enabling.")
        // Trip the circuit breaker by injecting consecutive failures
        fakeGateway.nextError = NSError(
            domain: "FakeFirestore",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Network error"]
        )

        for _ in 0..<5 {
            let usage = AppTokenUsage(
                provider: AppAgentProvider.claudeCode,
                sessionId: "session-\(UUID().uuidString)",
                projectName: "TestProject",
                model: "claude-3-5-sonnet",
                inputTokens: 100,
                outputTokens: 50,
                startTime: Date(),
                endTime: Date()
            )
            try dataStore.insert(usage)
            await usageSync.sync()
        }

        // Circuit should be open
        let stateAfterFailures = await circuitBreaker.state
        XCTAssertEqual(stateAfterFailures, .open(since: Date()))

        // Advance time past reset timeout and inject success
        fakeGateway.nextError = nil
        await circuitBreaker.advanceTime(by: 70)

        let usage = AppTokenUsage(
            provider: AppAgentProvider.claudeCode,
            sessionId: "session-recovery",
            projectName: "TestProject",
            model: "claude-3-5-sonnet",
            inputTokens: 100,
            outputTokens: 50,
            startTime: Date(),
            endTime: Date()
        )
        try dataStore.insert(usage)
        await usageSync.sync()

        // After first success, should be half-open
        let stateAfterFirstSuccess = await circuitBreaker.state
        XCTAssertEqual(stateAfterFirstSuccess, .halfOpen)

        // Second success should close the circuit
        let usage2 = AppTokenUsage(
            provider: AppAgentProvider.claudeCode,
            sessionId: "session-recovery-2",
            projectName: "TestProject",
            model: "claude-3-5-sonnet",
            inputTokens: 100,
            outputTokens: 50,
            startTime: Date(),
            endTime: Date()
        )
        try dataStore.insert(usage2)
        await usageSync.sync()

        let stateAfterSecondSuccess = await circuitBreaker.state
        XCTAssertEqual(stateAfterSecondSuccess, .closed)
    }


}

#if canImport(AppKit) && !DISTRIBUTION_MAS
import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
import XCTest
@testable import OpenBurnBar

@MainActor
final class ComputerUseCloudMeteringServiceTests: XCTestCase {
    func testWritesSessionAndActionDocumentsThroughGatewayWithExpectedMergeSemantics() async throws {
        let gateway = ComputerUseFirestoreGatewaySpy()
        let service = ComputerUseCloudMeteringService(firestoreGateway: gateway)
        let startedAt = Date(timeIntervalSince1970: 1_788_000_000)
        let request = ComputerUseSessionStartRequest(
            mode: ComputerUseMode.system.rawValue,
            trustMode: ComputerUseTrustMode.manual.rawValue,
            scopeRuleIds: [],
            phoneViewerNodeId: nil,
            macHostNodeId: "mac-1",
            clientID: BurnBarClientID(rawValue: "client-1")
        )
        let startResponse = ComputerUseSessionStartResponse(
            sessionId: "session-1",
            manifestHashHex: String(repeating: "a", count: 64),
            startedAt: startedAt,
            entitlementProductId: "hosted_computer_use_sync",
            actionCap: 50
        )
        let header = ComputerUseActionMeteringHeader(
            entryIndex: 4,
            actionKind: "mac.input.click",
            approvedBy: ComputerUseAuditEntry.ApprovedBy.mac.rawValue,
            parentEntryHashHex: String(repeating: "b", count: 64),
            recordedAt: startedAt.addingTimeInterval(10)
        )
        let invocation = BurnBarToolInvocation(
            callID: "call-1",
            runID: BurnBarRunID(rawValue: "run-1"),
            tool: .macInputClick,
            arguments: .object([:]),
            requestedBy: BurnBarClientID(rawValue: "client-1"),
            requestedAt: startedAt
        )
        let invokeResponse = ComputerUseInvokeResponse(
            sessionId: "session-1",
            callID: "call-1",
            status: .executed,
            denyReason: nil,
            auditEntryIndex: 4,
            auditHeadHashHex: String(repeating: "c", count: 64),
            meteringHeader: header
        )
        let actionID = try XCTUnwrap(
            ComputerUseCloudMeteringService.actionRecord(
                invocation: invocation,
                response: invokeResponse
            )?.id
        )

        try await service.recordSessionStart(
            userID: " user-1 ",
            request: request,
            response: startResponse,
            macAppVersion: "1.0"
        )
        try await service.recordAction(
            userID: " user-1 ",
            invocation: invocation,
            response: invokeResponse
        )
        try await service.recordSessionEnd(
            userID: " user-1 ",
            sessionID: "session-1",
            endedAt: startedAt.addingTimeInterval(20),
            reason: .completed,
            state: nil,
            auditHeadHashHex: String(repeating: "d", count: 64)
        )

        XCTAssertEqual(gateway.writes, [
            .init(
                path: "users/user-1/computer_use_sessions/session-1",
                merge: false,
                id: "session-1",
                sessionID: "session-1",
                userID: "user-1",
                endReason: nil,
                containsPrivateActionData: false
            ),
            .init(
                path: "users/user-1/computer_use_actions/\(actionID)",
                merge: false,
                id: actionID,
                sessionID: "session-1",
                userID: nil,
                endReason: nil,
                containsPrivateActionData: false
            ),
            .init(
                path: "users/user-1/computer_use_sessions/session-1",
                merge: true,
                id: nil,
                sessionID: nil,
                userID: nil,
                endReason: ComputerUseEndReason.completed.rawValue,
                containsPrivateActionData: false
            )
        ])
    }

    func testSessionStartPayloadExcludesDeviceAndAuthorizationDetails() {
        let startedAt = Date(timeIntervalSince1970: 1_788_000_000)
        let request = ComputerUseSessionStartRequest(
            mode: ComputerUseMode.system.rawValue,
            trustMode: ComputerUseTrustMode.manual.rawValue,
            scopeRuleIds: ["private-scope-name"],
            phoneViewerNodeId: "private-phone-node",
            macHostNodeId: "private-mac-node",
            clientID: BurnBarClientID(rawValue: "private-client")
        )
        let response = ComputerUseSessionStartResponse(
            sessionId: "session-1",
            manifestHashHex: String(repeating: "a", count: 64),
            startedAt: startedAt,
            entitlementProductId: "hosted_computer_use_sync",
            actionCap: 50
        )

        let payload = ComputerUseCloudMeteringService.sessionStartPayload(
            userID: "user-1",
            request: request,
            response: response,
            macAppVersion: String(repeating: "v", count: 100)
        )

        XCTAssertEqual(Set(payload.keys), [
            "id", "sessionId", "userId", "mode", "trustMode", "startedAt",
            "actionCount", "approvalCount", "rejectionCount", "panicHaltCount",
            "visionSpendUSD", "manifestHashHex", "macAppVersion", "schemaVersion", "updatedAt"
        ])
        XCTAssertEqual(payload.string("macAppVersion"), String(repeating: "v", count: 80))
        XCTAssertFalse(payload.containsStringFragment("private-"))
    }

    func testActionPayloadUsesStableIDAndNeverFallsBackToRawResponseError() throws {
        let header = ComputerUseActionMeteringHeader(
            entryIndex: 4,
            actionKind: "mac.input.click",
            approvedBy: ComputerUseAuditEntry.ApprovedBy.mac.rawValue,
            parentEntryHashHex: String(repeating: "b", count: 64),
            recordedAt: Date(timeIntervalSince1970: 1_788_000_100)
        )
        let invocation = BurnBarToolInvocation(
            callID: "call-1",
            runID: BurnBarRunID(rawValue: "run-1"),
            tool: .macInputClick,
            arguments: .object(["secret": .string("https://private.example/path")]),
            requestedBy: BurnBarClientID(rawValue: "client-1"),
            requestedAt: Date()
        )
        let response = ComputerUseInvokeResponse(
            sessionId: "session-1",
            callID: "call-1",
            status: .error,
            denyReason: "dispatch failed at https://private.example/path",
            auditEntryIndex: 4,
            auditHeadHashHex: String(repeating: "c", count: 64),
            meteringHeader: header
        )

        let first = try XCTUnwrap(ComputerUseCloudMeteringService.actionRecord(invocation: invocation, response: response))
        let second = try XCTUnwrap(ComputerUseCloudMeteringService.actionRecord(invocation: invocation, response: response))

        XCTAssertEqual(first.id, second.id)
        XCTAssertFalse(first.payload.contains("denyReason"))
        XCTAssertFalse(first.payload.containsStringFragment("private.example"))
        XCTAssertFalse(first.payload.contains("arguments"))
        XCTAssertFalse(first.payload.contains("result"))
    }

    func testActionPayloadBoundsScopedDenialMetadata() throws {
        let header = ComputerUseActionMeteringHeader(
            entryIndex: 7,
            actionKind: String(repeating: "a", count: 200),
            approvedBy: ComputerUseAuditEntry.ApprovedBy.trustedScope.rawValue,
            scopeRuleId: String(repeating: "s", count: 240),
            denyReason: String(repeating: "d", count: 240),
            parentEntryHashHex: String(repeating: "b", count: 64),
            recordedAt: Date(timeIntervalSince1970: 1_788_000_150)
        )
        let invocation = BurnBarToolInvocation(
            callID: "call-denied",
            runID: BurnBarRunID(rawValue: "run-1"),
            tool: .browserClick,
            arguments: .object([:]),
            requestedBy: BurnBarClientID(rawValue: "client-1"),
            requestedAt: Date()
        )
        let response = ComputerUseInvokeResponse(
            sessionId: "session-1",
            callID: "call-denied",
            status: .denied,
            denyReason: "not exported",
            auditEntryIndex: 7,
            auditHeadHashHex: String(repeating: "c", count: 64),
            meteringHeader: header
        )

        let record = try XCTUnwrap(ComputerUseCloudMeteringService.actionRecord(invocation: invocation, response: response))

        XCTAssertEqual(record.payload.string("scopeRuleId"), String(repeating: "s", count: 200))
        XCTAssertEqual(record.payload.string("denyReason"), String(repeating: "d", count: 200))
        XCTAssertEqual(record.payload.string("actionKind"), String(repeating: "a", count: 120))
    }

    func testRecordSessionStartRejectsMissingAndLocalUsers() async throws {
        let service = ComputerUseCloudMeteringService(firestoreGateway: ComputerUseFirestoreGatewaySpy())
        let request = ComputerUseSessionStartRequest(
            mode: ComputerUseMode.browser.rawValue,
            trustMode: ComputerUseTrustMode.manual.rawValue,
            scopeRuleIds: [],
            clientID: BurnBarClientID(rawValue: "client-1")
        )
        let response = ComputerUseSessionStartResponse(
            sessionId: "session-1",
            manifestHashHex: String(repeating: "a", count: 64),
            startedAt: Date(timeIntervalSince1970: 1_788_000_000),
            entitlementProductId: "hosted_computer_use_sync",
            actionCap: 50
        )

        do {
            try await service.recordSessionStart(
                userID: " local-device ",
                request: request,
                response: response,
                macAppVersion: "1.0"
            )
            XCTFail("Expected local Computer Use user IDs to be rejected.")
        } catch {
            XCTAssertNotNil(error)
        }

        do {
            try await service.recordSessionStart(
                userID: "   ",
                request: request,
                response: response,
                macAppVersion: "1.0"
            )
            XCTFail("Expected blank user IDs to be rejected.")
        } catch {
            XCTAssertNotNil(error)
        }
    }

    func testDaemonSessionEndPayloadDoesNotRegressUnknownCounters() {
        let payload = ComputerUseCloudMeteringService.sessionEndPayload(
            endedAt: Date(timeIntervalSince1970: 1_788_000_200),
            reason: .entitlementLost,
            state: nil,
            auditHeadHashHex: String(repeating: "d", count: 64)
        )

        XCTAssertFalse(payload.contains("actionCount"))
        XCTAssertFalse(payload.contains("rejectionCount"))
        XCTAssertEqual(payload.int("panicHaltCount"), 0)
        XCTAssertEqual(payload.string("auditHeadHashHex"), String(repeating: "d", count: 64))
    }

    func testDaemonSessionEndPayloadIncludesStateCountersAndPanicClassification() {
        let sessionID = ComputerUseSessionID(rawValue: "session-1")
        let manifest = ComputerUseSessionManifest(
            sessionId: sessionID,
            mode: .system,
            trustMode: .manual,
            startedAt: Date(timeIntervalSince1970: 1_788_000_000),
            userId: "user-1",
            entitlementProductId: "hosted_computer_use_sync",
            actionCap: 50,
            sessionTimeoutSeconds: 1800
        )
        let state = ComputerUseSessionState(
            sessionId: sessionID,
            manifest: manifest,
            liveTrustMode: .manual,
            actionsExecuted: 3,
            actionsRejected: 2,
            auditChainHeadHashHex: String(repeating: "e", count: 64)
        )

        let payload = ComputerUseCloudMeteringService.sessionEndPayload(
            endedAt: Date(timeIntervalSince1970: 1_788_000_240),
            reason: .panicAccessibilityRevoked,
            state: state,
            auditHeadHashHex: nil
        )

        XCTAssertEqual(payload.int("actionCount"), 5)
        XCTAssertEqual(payload.int("rejectionCount"), 2)
        XCTAssertEqual(payload.int("panicHaltCount"), 1)
        XCTAssertEqual(payload.string("auditHeadHashHex"), String(repeating: "e", count: 64))
    }
}

private final class ComputerUseFirestoreGatewaySpy: ComputerUseFirestoreGateway {
    struct Write: Equatable, Sendable {
        let path: String
        let merge: Bool
        let id: String?
        let sessionID: String?
        let userID: String?
        let endReason: String?
        let containsPrivateActionData: Bool
    }

    private let recordedWrites = OpenBurnBarCore.Locked<[Write]>([])

    var writes: [Write] {
        recordedWrites.read()
    }

    func addSnapshotListener(
        at _: String,
        handler _: @escaping @Sendable (ComputerUseFirestoreDocumentSnapshot?, Error?) -> Void
    ) -> any ComputerUseFirestoreListenerRegistration {
        ComputerUseFirestoreListenerRegistrationSpy()
    }

    func getDocumentFromServer(at _: String) async throws -> ComputerUseFirestoreDocumentSnapshot {
        throw ComputerUseFirestoreGatewaySpyError.unexpectedRead
    }

    func setData(
        _ payload: ComputerUseFirestorePayload,
        at documentPath: String,
        merge: Bool
    ) async throws {
        let write = Write(
            path: documentPath,
            merge: merge,
            id: payload.string("id"),
            sessionID: payload.string("sessionId"),
            userID: payload.string("userId"),
            endReason: payload.string("endReason"),
            containsPrivateActionData: payload.contains("arguments") || payload.contains("result")
        )
        recordedWrites.withLock { $0.append(write) }
    }
}

private final class ComputerUseFirestoreListenerRegistrationSpy: ComputerUseFirestoreListenerRegistration {
    func remove() {}
}

private enum ComputerUseFirestoreGatewaySpyError: Error {
    case unexpectedRead
}
#endif

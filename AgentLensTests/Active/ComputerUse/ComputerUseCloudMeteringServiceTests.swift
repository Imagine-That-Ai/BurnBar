#if canImport(AppKit) && !DISTRIBUTION_MAS
import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
import XCTest
@testable import OpenBurnBar

@MainActor
final class ComputerUseCloudMeteringServiceTests: XCTestCase {
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
        XCTAssertEqual(payload["macAppVersion"] as? String, String(repeating: "v", count: 80))
        XCTAssertFalse(String(describing: payload).contains("private-"))
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
        XCTAssertNil(first.payload["denyReason"])
        XCTAssertFalse(String(describing: first.payload).contains("private.example"))
        XCTAssertNil(first.payload["arguments"])
        XCTAssertNil(first.payload["result"])
    }

    func testDaemonSessionEndPayloadDoesNotRegressUnknownCounters() {
        let payload = ComputerUseCloudMeteringService.sessionEndPayload(
            endedAt: Date(timeIntervalSince1970: 1_788_000_200),
            reason: .entitlementLost,
            state: nil,
            auditHeadHashHex: String(repeating: "d", count: 64)
        )

        XCTAssertNil(payload["actionCount"])
        XCTAssertNil(payload["rejectionCount"])
        XCTAssertEqual(payload["panicHaltCount"] as? Int, 0)
        XCTAssertEqual(payload["auditHeadHashHex"] as? String, String(repeating: "d", count: 64))
    }
}
#endif

#if canImport(AppKit)
import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarCore

@MainActor
public protocol ComputerUseCloudMeteringRecording: AnyObject {
    func recordSessionStart(
        userID: String,
        request: ComputerUseSessionStartRequest,
        response: ComputerUseSessionStartResponse,
        macAppVersion: String
    ) async throws

    func recordAction(
        userID: String,
        invocation: BurnBarToolInvocation,
        response: ComputerUseInvokeResponse
    ) async throws

    func recordSessionEnd(
        userID: String,
        sessionID: String,
        endedAt: Date,
        reason: ComputerUseEndReason,
        state: ComputerUseSessionState?,
        auditHeadHashHex: String?
    ) async throws
}

#if !DISTRIBUTION_MAS
/// Writes privacy-safe Computer Use headers. Firestore's persistent local cache
/// is the durable delivery queue; the file-backed quota ledger remains the
/// synchronous admission authority when the network is unavailable.
@MainActor
final class ComputerUseCloudMeteringService: ComputerUseCloudMeteringRecording {
    private let firestoreGateway: any ComputerUseFirestoreGateway

    init(firestoreGateway: any ComputerUseFirestoreGateway = ComputerUseFirestoreLiveGateway()) {
        self.firestoreGateway = firestoreGateway
    }

    func recordSessionStart(
        userID: String,
        request: ComputerUseSessionStartRequest,
        response: ComputerUseSessionStartResponse,
        macAppVersion: String
    ) async throws {
        let uid = try validatedUserID(userID)
        let payload = Self.sessionStartPayload(
            userID: uid,
            request: request,
            response: response,
            macAppVersion: macAppVersion
        )
        try await firestoreGateway.setData(
            payload,
            at: sessionPath(uid: uid, sessionID: response.sessionId),
            merge: false
        )
    }

    static func sessionStartPayload(
        userID: String,
        request: ComputerUseSessionStartRequest,
        response: ComputerUseSessionStartResponse,
        macAppVersion: String
    ) -> ComputerUseFirestorePayload {
        ComputerUseFirestorePayload(values: [
            "id": .string(response.sessionId),
            "sessionId": .string(response.sessionId),
            "userId": .string(userID),
            "mode": .string(request.mode),
            "trustMode": .string(request.trustMode),
            "startedAt": .timestamp(response.startedAt),
            "actionCount": .integer(0),
            "approvalCount": .integer(0),
            "rejectionCount": .integer(0),
            "panicHaltCount": .integer(0),
            "visionSpendUSD": .integer(0),
            "manifestHashHex": .string(response.manifestHashHex),
            "macAppVersion": .string(String(macAppVersion.prefix(80))),
            "schemaVersion": .integer(1),
            "updatedAt": .timestamp(response.startedAt)
        ])
    }

    func recordAction(
        userID: String,
        invocation: BurnBarToolInvocation,
        response: ComputerUseInvokeResponse
    ) async throws {
        let uid = try validatedUserID(userID)
        guard let record = Self.actionRecord(invocation: invocation, response: response) else { return }
        try await firestoreGateway.setData(
            record.payload,
            at: "users/\(uid)/computer_use_actions/\(record.id)",
            merge: false
        )
    }

    static func actionRecord(
        invocation: BurnBarToolInvocation,
        response: ComputerUseInvokeResponse
    ) -> (id: String, payload: ComputerUseFirestorePayload)? {
        guard let header = response.meteringHeader else { return nil }
        let actionID = ComputerUseAuditHasher.current.hash(
            data: Data("\(response.sessionId)|\(response.callID)|\(header.entryIndex)".utf8)
        )
        var payload = ComputerUseFirestorePayload(values: [
            "id": .string(actionID),
            "sessionId": .string(response.sessionId),
            "entryIndex": .integer(Int64(header.entryIndex)),
            "toolKind": .string(invocation.tool.rawValue),
            "actionKind": .string(String(header.actionKind.prefix(120))),
            "status": .string(response.status.rawValue),
            "approvedBy": .string(header.approvedBy),
            "parentEntryHashHex": .string(header.parentEntryHashHex),
            "recordedAt": .timestamp(header.recordedAt),
            "schemaVersion": .integer(1)
        ])
        if let scopeRuleID = header.scopeRuleId {
            payload.setString(String(scopeRuleID.prefix(200)), forKey: "scopeRuleId")
        }
        if let denyReason = header.denyReason {
            payload.setString(String(denyReason.prefix(200)), forKey: "denyReason")
        }
        return (actionID, payload)
    }

    func recordSessionEnd(
        userID: String,
        sessionID: String,
        endedAt: Date,
        reason: ComputerUseEndReason,
        state: ComputerUseSessionState?,
        auditHeadHashHex: String?
    ) async throws {
        let uid = try validatedUserID(userID)
        let payload = Self.sessionEndPayload(
            endedAt: endedAt,
            reason: reason,
            state: state,
            auditHeadHashHex: auditHeadHashHex
        )
        try await firestoreGateway.setData(
            payload,
            at: sessionPath(uid: uid, sessionID: sessionID),
            merge: true
        )
    }

    static func sessionEndPayload(
        endedAt: Date,
        reason: ComputerUseEndReason,
        state: ComputerUseSessionState?,
        auditHeadHashHex: String?
    ) -> ComputerUseFirestorePayload {
        var values: [String: ComputerUseFirestorePayload.Value] = [
            "endedAt": .timestamp(endedAt),
            "endReason": .string(reason.rawValue),
            "panicHaltCount": .integer(Self.isPanic(reason) ? 1 : 0),
            "updatedAt": .timestamp(endedAt)
        ]
        if let state {
            values["actionCount"] = .integer(Int64(state.actionsExecuted + state.actionsRejected))
            values["rejectionCount"] = .integer(Int64(state.actionsRejected))
        }
        if let auditHeadHashHex = auditHeadHashHex ?? state?.auditChainHeadHashHex {
            values["auditHeadHashHex"] = .string(auditHeadHashHex)
        }
        return ComputerUseFirestorePayload(values: values)
    }

    private func sessionPath(uid: String, sessionID: String) -> String {
        "users/\(uid)/computer_use_sessions/\(sessionID)"
    }

    private func validatedUserID(_ userID: String) throws -> String {
        let trimmed = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("local-") else {
            throw ComputerUseCloudMeteringError.missingAuthenticatedUser
        }
        return trimmed
    }

    private static func isPanic(_ reason: ComputerUseEndReason) -> Bool {
        switch reason {
        case .panicHotkey, .panicPhoneGesture, .panicMacLock, .panicRemoteConfig,
             .panicAccessibilityRevoked:
            return true
        default:
            return false
        }
    }
}

private enum ComputerUseCloudMeteringError: Error {
    case missingAuthenticatedUser
}
#else
/// Keeps the shared daemon manager constructible while Computer Use execution
/// remains compiled out of the Mac App Store distribution.
@MainActor
final class ComputerUseCloudMeteringService: ComputerUseCloudMeteringRecording {
    func recordSessionStart(
        userID _: String,
        request _: ComputerUseSessionStartRequest,
        response _: ComputerUseSessionStartResponse,
        macAppVersion _: String
    ) async throws {}

    func recordAction(
        userID _: String,
        invocation _: BurnBarToolInvocation,
        response _: ComputerUseInvokeResponse
    ) async throws {}

    func recordSessionEnd(
        userID _: String,
        sessionID _: String,
        endedAt _: Date,
        reason _: ComputerUseEndReason,
        state _: ComputerUseSessionState?,
        auditHeadHashHex _: String?
    ) async throws {}
}
#endif
#endif

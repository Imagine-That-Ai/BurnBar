#if canImport(AppKit) && !DISTRIBUTION_MAS
import FirebaseFirestore
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

/// Writes privacy-safe Computer Use headers. Firestore's persistent local cache
/// is the durable delivery queue; the file-backed quota ledger remains the
/// synchronous admission authority when the network is unavailable.
@MainActor
final class ComputerUseCloudMeteringService: ComputerUseCloudMeteringRecording {
    private let firestoreProvider: () -> Firestore

    init(firestoreProvider: @escaping () -> Firestore = { Firestore.firestore() }) {
        self.firestoreProvider = firestoreProvider
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
        try await sessionReference(uid: uid, sessionID: response.sessionId)
            .setData(payload, merge: false)
    }

    static func sessionStartPayload(
        userID: String,
        request: ComputerUseSessionStartRequest,
        response: ComputerUseSessionStartResponse,
        macAppVersion: String
    ) -> [String: Any] {
        [
            "id": response.sessionId,
            "sessionId": response.sessionId,
            "userId": userID,
            "mode": request.mode,
            "trustMode": request.trustMode,
            "startedAt": Timestamp(date: response.startedAt),
            "actionCount": 0,
            "approvalCount": 0,
            "rejectionCount": 0,
            "panicHaltCount": 0,
            "visionSpendUSD": 0,
            "manifestHashHex": response.manifestHashHex,
            "macAppVersion": String(macAppVersion.prefix(80)),
            "schemaVersion": 1,
            "updatedAt": Timestamp(date: response.startedAt)
        ]
    }

    func recordAction(
        userID: String,
        invocation: BurnBarToolInvocation,
        response: ComputerUseInvokeResponse
    ) async throws {
        let uid = try validatedUserID(userID)
        guard let record = Self.actionRecord(invocation: invocation, response: response) else { return }
        try await firestoreProvider()
            .collection("users").document(uid)
            .collection("computer_use_actions").document(record.id)
            .setData(record.payload, merge: false)
    }

    static func actionRecord(
        invocation: BurnBarToolInvocation,
        response: ComputerUseInvokeResponse
    ) -> (id: String, payload: [String: Any])? {
        guard let header = response.meteringHeader else { return nil }
        let actionID = ComputerUseAuditHasher.current.hash(
            data: Data("\(response.sessionId)|\(response.callID)|\(header.entryIndex)".utf8)
        )
        var payload: [String: Any] = [
            "id": actionID,
            "sessionId": response.sessionId,
            "entryIndex": header.entryIndex,
            "toolKind": invocation.tool.rawValue,
            "actionKind": String(header.actionKind.prefix(120)),
            "status": response.status.rawValue,
            "approvedBy": header.approvedBy,
            "parentEntryHashHex": header.parentEntryHashHex,
            "recordedAt": Timestamp(date: header.recordedAt),
            "schemaVersion": 1
        ]
        if let scopeRuleID = header.scopeRuleId {
            payload["scopeRuleId"] = String(scopeRuleID.prefix(200))
        }
        if let denyReason = header.denyReason {
            payload["denyReason"] = String(denyReason.prefix(200))
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
        try await sessionReference(uid: uid, sessionID: sessionID)
            .setData(payload, merge: true)
    }

    static func sessionEndPayload(
        endedAt: Date,
        reason: ComputerUseEndReason,
        state: ComputerUseSessionState?,
        auditHeadHashHex: String?
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "endedAt": Timestamp(date: endedAt),
            "endReason": reason.rawValue,
            "panicHaltCount": Self.isPanic(reason) ? 1 : 0,
            "updatedAt": Timestamp(date: endedAt)
        ]
        if let state {
            payload["actionCount"] = state.actionsExecuted + state.actionsRejected
            payload["rejectionCount"] = state.actionsRejected
        }
        if let auditHeadHashHex = auditHeadHashHex ?? state?.auditChainHeadHashHex {
            payload["auditHeadHashHex"] = auditHeadHashHex
        }
        return payload
    }

    private func sessionReference(uid: String, sessionID: String) -> DocumentReference {
        firestoreProvider()
            .collection("users").document(uid)
            .collection("computer_use_sessions").document(sessionID)
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

@MainActor
let computerUseCloudMeteringService = ComputerUseCloudMeteringService()
#endif

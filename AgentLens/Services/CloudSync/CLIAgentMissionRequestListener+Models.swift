import Foundation
@preconcurrency import FirebaseFirestore
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
import OSLog

// CLI-agent mission payloads, cloud sealer, device-trust result, persona scope, backend, direct-launch plan.
// Extracted from CLIAgentMissionRequestListener.swift (god-file decomposition) — same module, verbatim.

struct CLIAgentMissionPrivatePayload: Codable {
    var title: String?
    var prompt: String?
    var targetProject: String?
    var liveSummary: String?
    var resultPreview: String?
    var errorMessage: String?
    var approvalTitle: String?
    var approvalMessage: String?
    var personaScopeJSON: String?
    var synthesisSummary: String?
}

struct CLIAgentMissionEventPrivatePayload: Codable {
    var title: String?
    var message: String
    var fullMessage: String?
    var toolName: String?
    var artifactPath: String?
    var changedFilePath: String?
}

enum CLIAgentMissionCloudSealer {
    static let sealedSchemaVersion = 2
    static let sealedStateSchemaVersion = 1

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func missionAADContext(uid: String, requestID: String, field: String) throws -> CloudVaultAADContext {
        try CloudVaultAADContext(
            uid: uid,
            collection: "cli_agent_mission_requests",
            docID: requestID,
            field: field
        )
    }

    static func missionEventAADContext(uid: String, requestID: String, eventID: String) throws -> CloudVaultAADContext {
        try CloudVaultAADContext(
            uid: uid,
            collection: "cli_agent_mission_requests/events",
            docID: "\(requestID)/\(eventID)",
            field: "sealedPayload"
        )
    }

    static func seal<T: Encodable>(
        _ payload: T,
        vaultKey: Data,
        vaultKeyID: String,
        aadContext: CloudVaultAADContext? = nil
    ) throws -> [String: Any] {
        let data = try encoder.encode(payload)
        let sealed = try CloudVaultCrypto.sealPayload(
            data,
            keyData: vaultKey,
            vaultKeyID: vaultKeyID,
            aadContext: aadContext
        )
        return CloudVaultCrypto.sealedPayloadDictionary(sealed)
    }

    static func openPrivatePayload(
        _ data: [String: Any],
        field: String = "sealedPayload",
        uid: String? = nil,
        requestID: String? = nil,
        vaultKey: Data?
    ) -> CLIAgentMissionPrivatePayload? {
        guard let vaultKey,
              let envelope = CloudVaultCrypto.sealedPayload(from: data[field])
        else { return nil }
        do {
            let aadContext: CloudVaultAADContext?
            if let uid, let requestID {
                aadContext = try missionAADContext(uid: uid, requestID: requestID, field: field)
            } else {
                aadContext = nil
            }
            let payload = try CloudVaultCrypto.openPayload(envelope, keyData: vaultKey, aadContext: aadContext)
            return try decoder.decode(CLIAgentMissionPrivatePayload.self, from: payload)
        } catch {
            return nil
        }
    }
}

struct CLIAgentMissionDeviceTrustResult: Equatable, Sendable {
    let isTrusted: Bool
    let message: String

    static var trusted: CLIAgentMissionDeviceTrustResult {
        CLIAgentMissionDeviceTrustResult(
            isTrusted: true,
            message: "Mac is trusted for mobile mission execution."
        )
    }

    static func untrusted(_ message: String) -> CLIAgentMissionDeviceTrustResult {
        CLIAgentMissionDeviceTrustResult(isTrusted: false, message: message)
    }
}

@MainActor
protocol CLIAgentMissionDeviceTrustChecking: AnyObject {
    func prepareAndValidateTrustedExecutor(uid: String, deviceID: String) async -> CLIAgentMissionDeviceTrustResult
}

//
// Hermes Square §6.5 — the phone attaches a `personaScopeJSON` envelope that
// the Mac applies to the spawned CLI subprocess (tool allow-list, file globs,
// shell prefixes, permit-shell / permit-file-edits gates). When the envelope
// is PRESENT but malformed, `CLIAgentMissionPersonaScopeApplier.overrides`
// deliberately throws — because falling back to `.empty` would dispatch the
// mission with NO persona scoping at all (full shell + unrestricted file
// edits), silently widening the sandbox the operator asked to narrow.
//
// This resolver makes that decision explicit and testable: a missing scope
// resolves to `.empty` (the legitimate "no scope" path), but a malformed
// present scope is REFUSED so the listener fails the mission with a clear
// error instead of fail-open dispatching with default permissions.
enum CLIAgentMissionPersonaScopeResolution: Equatable {
    case resolved(CLIAgentMissionPersonaScopeApplier.RuntimeOverrides)
    case refused(String)

    static func resolve(from data: [String: Any]) -> CLIAgentMissionPersonaScopeResolution {
        do {
            return .resolved(try CLIAgentMissionPersonaScopeApplier.overrides(from: data))
        } catch {
            return .refused(
                "The persona scope attached to this mission could not be read, "
                    + "so it was rejected instead of running with broader permissions. "
                    + "Re-send the mission from your device."
            )
        }
    }
}

struct CLIAgentMissionBackend: Equatable, Sendable {
    let rawValue: String
    let displayName: String
    let chatBackend: ChatBackendID?

    init(chatBackend: ChatBackendID) {
        self.rawValue = chatBackend.rawValue
        self.displayName = chatBackend.displayName
        self.chatBackend = chatBackend
    }

    init(rawValue: String, displayName: String) {
        self.rawValue = rawValue
        self.displayName = displayName
        self.chatBackend = nil
    }

    var usesDirectCLI: Bool {
        chatBackend == nil
    }
}

struct CLIAgentMissionDirectLaunchPlan: Equatable, Sendable {
    let executableName: String
    let arguments: [String]
    let extraEnvironment: [String: String]
}

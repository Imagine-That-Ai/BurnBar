import Foundation
@preconcurrency import FirebaseFirestore
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
import OSLog

// CLI-agent mission payloads, cloud sealer, device-trust result, persona scope, backend, direct-launch plan.
// Extracted from CLIAgentMissionRequestListener.swift (god-file decomposition) — same module.

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
// is PRESENT but malformed, the decode boundary refuses it: invalid JSON is
// rejected by `CLIAgentMissionPersonaScopeApplier.overrides`, and non-string
// values are rejected here before reaching that helper. Falling back to
// `.empty` would dispatch without the narrower persona scope requested by the
// operator.
//
// A missing or blank string remains the legitimate no-scope path; every other
// malformed present value fails closed with a clear mission error.
enum CLIAgentMissionPersonaScopeResolution: Equatable {
    case resolved(CLIAgentMissionPersonaScopeApplier.RuntimeOverrides)
    case refused(String)

    private static let refusalMessage = "The persona scope attached to this mission could not be read, "
        + "so it was rejected instead of running with broader permissions. "
        + "Re-send the mission from your device."

    static func resolve(from data: [String: Any]) -> CLIAgentMissionPersonaScopeResolution {
        if let rawScope = data["personaScopeJSON"], !(rawScope is String) {
            return .refused(refusalMessage)
        }
        do {
            return .resolved(try CLIAgentMissionPersonaScopeApplier.overrides(from: data))
        } catch {
            return .refused(refusalMessage)
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

import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import OpenBurnBarCore
import OpenBurnBarSignalCore
import os

// MARK: - CLI mission sealed-payload envelopes + cloud sealer
//
// Split out of `CLIAgentMissionDispatcher.swift` (audit wave 4, item 14
// structural decomposition). Pure move — no behavior change.

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

    init(
        title: String? = nil,
        prompt: String? = nil,
        targetProject: String? = nil,
        liveSummary: String? = nil,
        resultPreview: String? = nil,
        errorMessage: String? = nil,
        approvalTitle: String? = nil,
        approvalMessage: String? = nil,
        personaScopeJSON: String? = nil,
        synthesisSummary: String? = nil
    ) {
        self.title = title
        self.prompt = prompt
        self.targetProject = targetProject
        self.liveSummary = liveSummary
        self.resultPreview = resultPreview
        self.errorMessage = errorMessage
        self.approvalTitle = approvalTitle
        self.approvalMessage = approvalMessage
        self.personaScopeJSON = personaScopeJSON
        self.synthesisSummary = synthesisSummary
    }
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

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func missionAADContext(uid: String, documentID: String, field: String) throws -> CloudVaultAADContext {
        try CloudVaultAADContext(
            uid: uid,
            collection: "cli_agent_mission_requests",
            docID: documentID,
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

    static func signalEnvelopeIfEnabled(
        from sealedData: [String: Any],
        uid: String,
        firestore: Firestore,
        collection: String,
        docId: String,
        resolvedKey: MobileCloudVaultResolvedKey
    ) async throws -> [String: Any]? {
        guard MobileCloudVaultSignalPayloads.signalSealingIsEnabled(domainID: "conversations_chat") else {
            return nil
        }
        guard let legacyEnvelope = CloudVaultCrypto.sealedPayload(from: sealedData["sealedPayload"]) else {
            throw MobileCloudVaultSignalPayloadError.invalidSignalEnvelope
        }
        let aadContext = try missionAADContext(uid: uid, documentID: docId, field: "sealedPayload")
        let plaintext = try CloudVaultCrypto.openPayload(
            legacyEnvelope,
            keyData: resolvedKey.keyData,
            aadContext: aadContext
        )
        return try await MobileCloudVaultSignalPayloads.signalEnvelopeIfEnabled(
            domainID: "conversations_chat",
            uid: uid,
            firestore: firestore,
            collection: collection,
            docId: docId,
            plaintext: plaintext,
            resolvedKey: resolvedKey
        )
    }

    static func openPrivatePayload(
        _ data: [String: Any],
        field: String = "sealedPayload",
        uid: String? = nil,
        documentID: String? = nil,
        vaultKey: Data?,
        signalIdentity: OpenBurnBarSignalIdentityKeypair? = nil
    ) -> CLIAgentMissionPrivatePayload? {
        let signalRequired = MobileCloudVaultSignalPayloads.signalSealingIsRequired(domainID: "conversations_chat")
        if signalRequired && (data["signalEnvelope"] == nil || uid == nil || documentID == nil) {
            return nil
        }
        if field == "sealedPayload", data["signalEnvelope"] != nil, let uid, let documentID {
            do {
                if let payload = try MobileCloudVaultSignalPayloads.openSignalPayloadIfPresent(
                    data,
                    uid: uid,
                    collection: "cli_agent_mission_requests",
                    docId: documentID,
                    signalIdentity: signalIdentity
                ) {
                    return try decoder.decode(CLIAgentMissionPrivatePayload.self, from: payload)
                }
            } catch let signalError as OpenBurnBarSignalCoreError
                where !signalError.allowsLegacyAtRestFallback(senderSetComplete: false) {
                // C1: a stripped / forged sender-auth block (or relocated AAD
                // binding) is a downgrade attack — fail CLOSED, never decode the
                // sender-unauthenticated legacy payload for this mission request.
                return nil
            } catch MobileCloudVaultSignalPayloadError.signalBindingMismatch {
                // Relocated / replayed envelope — fail CLOSED.
                return nil
            } catch {
                // Phase-C rollout keeps legacy AES-GCM `sealedPayload` alongside
                // optional Signal envelopes. A missing local Signal identity or
                // malformed optional envelope must not make the legacy reader lose
                // data while activation remains flag-off.
                if signalRequired { return nil }
            }
        }
        guard let vaultKey,
              let envelope = CloudVaultCrypto.sealedPayload(from: data[field])
        else { return nil }
        do {
            let aadContext: CloudVaultAADContext?
            if let uid, let documentID {
                aadContext = try? missionAADContext(uid: uid, documentID: documentID, field: field)
            } else {
                aadContext = nil
            }
            let payload = try CloudVaultCrypto.openPayload(envelope, keyData: vaultKey, aadContext: aadContext)
            return try decoder.decode(CLIAgentMissionPrivatePayload.self, from: payload)
        } catch {
            // Undecryptable/undecodable mission payload is dropped — log so a key
            // mismatch or schema drift doesn't silently blank the mission feed.
            cliMissionSignalLogger.warning("mission payload open failed doc=\(documentID ?? "?", privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    static func openEventPayload(
        _ data: [String: Any],
        uid: String? = nil,
        requestID: String? = nil,
        eventID: String? = nil,
        vaultKey: Data?
    ) -> CLIAgentMissionEventPrivatePayload? {
        guard let vaultKey,
              let envelope = CloudVaultCrypto.sealedPayload(from: data["sealedPayload"])
        else { return nil }
        do {
            let aadContext: CloudVaultAADContext?
            if let uid, let requestID, let eventID {
                aadContext = try? missionEventAADContext(uid: uid, requestID: requestID, eventID: eventID)
            } else {
                aadContext = nil
            }
            let payload = try CloudVaultCrypto.openPayload(envelope, keyData: vaultKey, aadContext: aadContext)
            return try decoder.decode(CLIAgentMissionEventPrivatePayload.self, from: payload)
        } catch {
            // Undecryptable/undecodable mission event is dropped — log so a key
            // mismatch or schema drift doesn't silently hide mission progress.
            cliMissionSignalLogger.warning("mission event open failed request=\(requestID ?? "?", privacy: .public) event=\(eventID ?? "?", privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

import FirebaseCore
import FirebaseFirestore
import Foundation
import OpenBurnBarCore
import OpenBurnBarSignalCore
import OSLog

protocol ConversationCloudVaultKeyProviding: Sendable {
    func keyForWriting(uid: String, deviceId: String) async throws -> CloudVaultResolvedKey
    func keyForReading(uid: String, deviceId: String) async throws -> CloudVaultResolvedKey?
}

// AUDIT(@unchecked Sendable): stores a non-Sendable Firebase `Firestore` override;
// the SDK is internally thread-safe. sendable-allowlist: firebase-sdk-handle
struct MacConversationCloudVaultKeyProvider: ConversationCloudVaultKeyProviding, @unchecked Sendable {
    private let firestoreOverride: Firestore?

    init(firestore: Firestore? = nil) {
        self.firestoreOverride = firestore
    }

    func keyForWriting(uid: String, deviceId: String) async throws -> CloudVaultResolvedKey {
        guard let firestore else {
            throw CloudVaultAccessError.vaultKeyUnavailable
        }
        return try await MacCloudVaultKeyAccess.keyForWriting(uid: uid, deviceId: deviceId, firestore: firestore)
    }

    func keyForReading(uid: String, deviceId: String) async throws -> CloudVaultResolvedKey? {
        guard let firestore else {
            return nil
        }
        return try await MacCloudVaultKeyAccess.keyForReading(uid: uid, deviceId: deviceId, firestore: firestore)
    }

    private var firestore: Firestore? {
        if let firestoreOverride {
            return firestoreOverride
        }
        guard FirebaseApp.app() != nil else {
            return nil
        }
        return Firestore.firestore()
    }
}

struct ConversationCloudPrivatePayload: Codable, Equatable, Sendable {
    var projectName: String
    var keyFiles: [String]
    var keyCommands: [String]
    var keyTools: [String]
    var inferredTaskTitle: String
    var lastAssistantMessage: String
    var workingDirectory: String?
    var summary: String?
    var summaryTitle: String?
    var summaryProvider: String?
    var summaryModel: String?

    init(
        projectName: String,
        keyFiles: [String],
        keyCommands: [String],
        keyTools: [String],
        inferredTaskTitle: String,
        lastAssistantMessage: String,
        workingDirectory: String?,
        summary: String?,
        summaryTitle: String?,
        summaryProvider: String?,
        summaryModel: String?
    ) {
        self.projectName = projectName
        self.keyFiles = keyFiles
        self.keyCommands = keyCommands
        self.keyTools = keyTools
        self.inferredTaskTitle = inferredTaskTitle
        self.lastAssistantMessage = lastAssistantMessage
        self.workingDirectory = workingDirectory
        self.summary = summary
        self.summaryTitle = summaryTitle
        self.summaryProvider = summaryProvider
        self.summaryModel = summaryModel
    }

    init(record: OpenBurnBarCore.ConversationRecord) {
        self.init(
            projectName: record.projectName,
            keyFiles: record.keyFiles,
            keyCommands: record.keyCommands,
            keyTools: record.keyTools,
            inferredTaskTitle: record.inferredTaskTitle,
            lastAssistantMessage: ConversationCloudSealer.capLastAssistantMessage(record.lastAssistantMessage),
            workingDirectory: record.workingDirectory,
            summary: record.summary,
            summaryTitle: record.summaryTitle,
            summaryProvider: record.summaryProvider,
            summaryModel: record.summaryModel
        )
    }
}

enum ConversationCloudSealer {
    private static let logger = Logger(
        subsystem: "com.openburnbar.cloudsync",
        category: "ConversationCloudVaultPayload"
    )

    static let sealedSchemaVersion = 2

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        JSONDecoder()
    }

    static func seal(
        _ payload: ConversationCloudPrivatePayload,
        key: CloudVaultResolvedKey,
        uid: String,
        docId: String
    ) throws -> [String: Any] {
        let encoded = try encoder.encode(payload)
        let aadContext = try CloudVaultAADContext(
            uid: uid,
            collection: "conversations",
            docID: docId,
            field: "sealedPayload"
        )
        let sealed = try CloudVaultCrypto.sealPayload(
            encoded,
            keyData: key.keyData,
            vaultKeyID: key.vaultKeyID,
            aadContext: aadContext
        )
        return CloudVaultCrypto.sealedPayloadDictionary(sealed)
    }

    /// The exact plaintext bytes `seal` encrypts — exposed so the producer can also at-rest
    /// Signal-seal the SAME payload (item 3 dual-write) without re-deriving the encoding.
    static func encodePlaintext(_ payload: ConversationCloudPrivatePayload) throws -> Data {
        try encoder.encode(payload)
    }

    static func open(
        _ data: [String: Any],
        keyData: Data?,
        uid: String? = nil,
        docId: String? = nil,
        signalIdentity: OpenBurnBarSignalIdentityKeypair? = nil,
        trustedSenderPublicKeys: [String: Data] = [:]
    ) -> ConversationCloudPrivatePayload? {
        guard data["contentSealed"] as? Bool == true || data["sealedPayload"] != nil || data["signalEnvelope"] != nil else {
            return nil
        }
        let signalRequired = MacCloudVaultSignalPayloads.signalSealingIsRequired(domainID: "conversations_chat")
        // Signal-first. A legacy-only row remains readable during migration, but a PRESENT
        // Signal envelope may not downgrade in required mode.
        if data["signalEnvelope"] != nil {
            guard let uid, let docId else {
                if signalRequired { return nil }
                return openLegacy(data, keyData: keyData, uid: uid, docId: docId)
            }
            do {
                if let bytes = try MacCloudVaultSignalPayloads.openSignalPayloadIfPresent(
                    data, uid: uid, collection: "conversations", docId: docId,
                    signalIdentity: signalIdentity, trustedSenderPublicKeys: trustedSenderPublicKeys
                ) {
                    if let payload = try? decoder.decode(ConversationCloudPrivatePayload.self, from: bytes) { // try?-ok(verified payload parse)
                        return payload
                    }
                    if signalRequired { return nil }
                }
            } catch {
                if signalRequired || !MacCloudVaultSignalPayloads.allowsLegacyAtRestFallback(
                    for: error,
                    senderSetComplete: false
                ) {
                    return nil
                }
                logger.warning("Signal conversation payload open fell back to legacy vault payload: \(String(describing: error), privacy: .private)")
            }
        }
        return openLegacy(data, keyData: keyData, uid: uid, docId: docId)
    }

    private static func openLegacy(
        _ data: [String: Any],
        keyData: Data?,
        uid: String?,
        docId: String?
    ) -> ConversationCloudPrivatePayload? {
        guard let keyData,
              let envelope = CloudVaultCrypto.sealedPayload(from: data["sealedPayload"]) else {
            return nil
        }
        do {
            let aadContext: CloudVaultAADContext?
            if let uid, let docId {
                aadContext = try CloudVaultAADContext(
                    uid: uid,
                    collection: "conversations",
                    docID: docId,
                    field: "sealedPayload"
                )
            } else {
                aadContext = nil
            }
            let payloadData = try CloudVaultCrypto.openPayload(
                envelope,
                keyData: keyData,
                aadContext: aadContext
            )
            return try decoder.decode(ConversationCloudPrivatePayload.self, from: payloadData)
        } catch {
            return nil
        }
    }

    static func capLastAssistantMessage(_ text: String) -> String {
        if text.count <= 500 { return text }
        return String(text.prefix(500))
    }

    // Immutable Firestore field-delete sentinel map ([String: Any] can't be Sendable).
    nonisolated(unsafe) static let plaintextFieldDeletes: [String: Any] = [
        "projectName": FieldValue.delete(),
        "keyFiles": FieldValue.delete(),
        "keyCommands": FieldValue.delete(),
        "keyTools": FieldValue.delete(),
        "inferredTaskTitle": FieldValue.delete(),
        "lastAssistantMessage": FieldValue.delete(),
        "workingDirectory": FieldValue.delete(),
        "summary": FieldValue.delete(),
        "summaryTitle": FieldValue.delete(),
        "summaryProvider": FieldValue.delete(),
        "summaryModel": FieldValue.delete()
    ]
}

import FirebaseCore
import FirebaseFirestore
import Foundation
import OpenBurnBarCore
import OpenBurnBarSignalCore

protocol ConversationCloudVaultKeyProviding: Sendable {
    func keyForWriting(uid: String, deviceId: String) async throws -> CloudVaultResolvedKey
    func keyForReading(uid: String, deviceId: String) async throws -> CloudVaultResolvedKey?
}

struct MacConversationCloudVaultKeyProvider: ConversationCloudVaultKeyProviding {
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

    init(record: ConversationRecord) {
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
    static let sealedSchemaVersion = 2

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        JSONDecoder()
    }

    static func seal(_ payload: ConversationCloudPrivatePayload, key: CloudVaultResolvedKey) throws -> [String: Any] {
        let encoded = try encoder.encode(payload)
        let sealed = try CloudVaultCrypto.sealPayload(encoded, keyData: key.keyData, vaultKeyID: key.vaultKeyID)
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
        // Signal-first open (item 3); fall through to legacy AES-GCM on any failure (rollout
        // compatibility, matching iOS/Android). Requires uid + docId (the binding coordinates).
        // trustedSenderPublicKeys enables CROSS-DEVICE sender-auth verification (a doc written
        // by another trusted device); empty => only self-authored docs verify, others fall back.
        if data["signalEnvelope"] != nil, let uid, let docId {
            if let bytes = try? MacCloudVaultSignalPayloads.openSignalPayloadIfPresent(
                data, uid: uid, collection: "conversations", docId: docId,
                signalIdentity: signalIdentity, trustedSenderPublicKeys: trustedSenderPublicKeys
            ), let payload = try? decoder.decode(ConversationCloudPrivatePayload.self, from: bytes) {
                return payload
            }
        }
        guard let keyData,
              let envelope = CloudVaultCrypto.sealedPayload(from: data["sealedPayload"]),
              let payloadData = try? CloudVaultCrypto.openPayload(envelope, keyData: keyData) else {
            return nil
        }
        return try? decoder.decode(ConversationCloudPrivatePayload.self, from: payloadData)
    }

    static func capLastAssistantMessage(_ text: String) -> String {
        if text.count <= 500 { return text }
        return String(text.prefix(500))
    }

    static let plaintextFieldDeletes: [String: Any] = [
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

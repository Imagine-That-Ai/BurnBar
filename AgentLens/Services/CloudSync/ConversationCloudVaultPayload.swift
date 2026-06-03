import FirebaseFirestore
import Foundation
import OpenBurnBarCore

protocol ConversationCloudVaultKeyProviding: Sendable {
    func keyForWriting(uid: String, deviceId: String) async throws -> CloudVaultResolvedKey
    func keyForReading(uid: String, deviceId: String) async throws -> CloudVaultResolvedKey?
}

struct MacConversationCloudVaultKeyProvider: ConversationCloudVaultKeyProviding {
    private let firestore: Firestore

    init(firestore: Firestore = Firestore.firestore()) {
        self.firestore = firestore
    }

    func keyForWriting(uid: String, deviceId: String) async throws -> CloudVaultResolvedKey {
        try await MacCloudVaultKeyAccess.keyForWriting(uid: uid, deviceId: deviceId, firestore: firestore)
    }

    func keyForReading(uid: String, deviceId: String) async throws -> CloudVaultResolvedKey? {
        try await MacCloudVaultKeyAccess.keyForReading(uid: uid, deviceId: deviceId, firestore: firestore)
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
    static let sealedSchemaVersion = 1

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

    static func open(_ data: [String: Any], keyData: Data?) -> ConversationCloudPrivatePayload? {
        guard data["contentSealed"] as? Bool == true || data["sealedPayload"] != nil else { return nil }
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

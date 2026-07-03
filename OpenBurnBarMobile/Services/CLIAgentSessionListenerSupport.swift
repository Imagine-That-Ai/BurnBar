import FirebaseFirestore
import Foundation
import OpenBurnBarCore

struct CLIAgentSessionDocumentChange: @unchecked Sendable {
    enum Kind: Sendable { case upsert, removed }
    let kind: Kind
    let docID: String
    /// Firestore document payload — `@unchecked Sendable` because Firestore
    /// returns `[String: Any]` and deliveries are applied on a serial task chain.
    let payload: [String: Any]?
    let updatedAtMillis: Int64
}

final class CLIAgentSessionDecodeCache: @unchecked Sendable {
    private var memo: [String: (updatedAtMillis: Int64, record: CLIAgentSessionRecord)] = [:]

    func decode(
        documentID: String,
        uid: String,
        data: [String: Any],
        vaultKey: Data?,
        updatedAtMillis: Int64
    ) -> CLIAgentSessionRecord? {
        if let cached = memo[documentID], cached.updatedAtMillis == updatedAtMillis {
            return cached.record
        }
        guard let record = CLIAgentChatFirestoreSource.decodeDocument(
            documentID: documentID,
            uid: uid,
            data: data,
            vaultKey: vaultKey
        ) else {
            memo.removeValue(forKey: documentID)
            return nil
        }
        memo[documentID] = (updatedAtMillis, record)
        return record
    }

    func remove(docID: String) {
        memo.removeValue(forKey: docID)
    }

    func reset() {
        memo.removeAll()
    }
}

final class CLIAgentSessionAccumulator: @unchecked Sendable {
    private var byID: [String: CLIAgentSessionRecord] = [:]

    func upsert(_ record: CLIAgentSessionRecord) {
        byID[record.id] = record
    }

    func remove(docID: String) {
        byID.removeValue(forKey: docID)
    }

    func snapshot() -> [CLIAgentSessionRecord] {
        byID.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    func reset() {
        byID.removeAll()
    }
}

enum CLIAgentSessionListenerSupport {
    static func updatedAtMillis(_ value: Any?) -> Int64 {
        if let timestamp = value as? Timestamp {
            return Int64(timestamp.dateValue().timeIntervalSince1970 * 1_000)
        }
        if let date = value as? Date {
            return Int64(date.timeIntervalSince1970 * 1_000)
        }
        return 0
    }

    static func searchText(for record: CLIAgentSessionRecord) -> String {
        [
            record.title,
            record.preview,
            record.agent.displayName,
            record.modelName ?? "",
            record.workspaceLabel ?? "",
            record.messages.map { message in
                [
                    message.role.rawValue,
                    message.text,
                    message.toolUses.map { "\($0.name) \($0.status) \($0.detail ?? "")" }
                        .joined(separator: " ")
                ].joined(separator: " ")
            }.joined(separator: " ")
        ].joined(separator: " ")
    }
}

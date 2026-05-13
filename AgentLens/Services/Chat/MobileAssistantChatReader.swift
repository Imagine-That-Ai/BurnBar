import Foundation
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import OSLog

// MARK: - Mobile Assistant Chat Reader
//
// Read-only mirror of the `users/{uid}/mobile_assistant_chats/{threadId}`
// collection that the iOS and iPadOS apps write to. The Mac app surfaces these
// threads as an "From your phone" section so a user who chats with Hermes / Pi
// on their iPhone can pick the conversation back up on the desktop.
//
// Symmetric with `MobileChatHistoryStore` on iOS: same document shape, same
// nested attachment + token-usage payload.

/// Plain-data representation of a persisted assistant chat thread, decoded
/// from Firestore. Read-only on macOS in this wave.
struct MobileAssistantChatThread: Identifiable, Equatable, Hashable {
    let id: String
    let runtime: String
    let title: String
    let preview: String
    let modelName: String?
    let createdAt: Date
    let updatedAt: Date
    let messageCount: Int
    let messages: [MobileAssistantChatMessage]
}

struct MobileAssistantChatMessage: Identifiable, Equatable, Hashable {
    let id: String
    let role: String
    let text: String
    let timestamp: Date
    let modelName: String?
    let isError: Bool
    let attachments: [MobileAssistantChatAttachment]
    let toolCalls: [MobileAssistantChatToolCall]
    let usage: MobileAssistantChatTokenUsage?
}

struct MobileAssistantChatAttachment: Identifiable, Equatable, Hashable {
    let id: String
    let kind: String
    let displayName: String
    let mimeType: String
    let byteSize: Int
    let workspaceRelativePath: String
    let extractedTextPreview: String?
}

struct MobileAssistantChatToolCall: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let status: String
}

struct MobileAssistantChatTokenUsage: Equatable, Hashable {
    let outputTokens: Int?
    let totalTokens: Int?
    let source: String?
    let providerGenerationDurationSeconds: TimeInterval?
    let providerTotalDurationSeconds: TimeInterval?
    let responseStartedAt: Date?
    let firstResponseChunkAt: Date?
    let responseCompletedAt: Date?

    /// Tokens-per-second, when we have provider-measured numbers. Mirrors the
    /// "trustworthy rate" logic on iOS so the displayed value matches.
    var tokensPerSecond: Double? {
        guard let outputTokens, outputTokens > 0,
              let providerGenerationDurationSeconds,
              providerGenerationDurationSeconds > 0 else { return nil }
        return Double(outputTokens) / providerGenerationDurationSeconds
    }
}

@MainActor
protocol MobileAssistantChatRemoteSource: AnyObject {
    func fetchAll() async throws -> [MobileAssistantChatThread]
    var isAvailable: Bool { get }
}

/// Observable singleton that pulls the iOS/iPadOS-originated chats into the
/// Mac app on demand. Refresh is idempotent and silent when the user isn't
/// signed in to Firebase.
@MainActor
@Observable
final class MobileAssistantChatReader {
    static let shared = MobileAssistantChatReader()

    private(set) var threads: [MobileAssistantChatThread] = []
    private(set) var isLoading: Bool = false
    private(set) var lastError: String?
    private(set) var lastRefreshedAt: Date?

    private let remote: MobileAssistantChatRemoteSource
    private let logger = Logger(subsystem: "com.openburnbar.agentlens", category: "MobileAssistantChatReader")
    private var authListenerHandle: AuthStateDidChangeListenerHandle?

    init(remote: MobileAssistantChatRemoteSource = MobileAssistantChatFirestoreSource()) {
        self.remote = remote
        attachAuthListener()
    }

    /// Lazy threads grouped by runtime so the Mac surface can show separate
    /// "Hermes" and "Pi" lists. The dictionary's values stay sorted by
    /// `updatedAt` descending — newest first.
    func threadsByRuntime() -> [String: [MobileAssistantChatThread]] {
        Dictionary(grouping: threads, by: \.runtime)
            .mapValues { $0.sorted { $0.updatedAt > $1.updatedAt } }
    }

    func threads(runtime: String) -> [MobileAssistantChatThread] {
        threads
            .filter { $0.runtime == runtime }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Pulls a fresh snapshot. Safe to call from view appear hooks or refresh
    /// buttons; concurrent calls coalesce on the first in-flight fetch.
    func refresh() async {
        guard !isLoading else { return }
        guard remote.isAvailable else { return }
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        do {
            threads = try await remote.fetchAll()
            lastRefreshedAt = Date()
        } catch {
            lastError = error.localizedDescription
            logger.warning("Failed to fetch mobile chats: \(String(describing: error), privacy: .public)")
        }
    }

    private func attachAuthListener() {
        guard FirebaseApp.app() != nil else { return }
        authListenerHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                if user == nil {
                    // New (or absent) user — drop any cached threads from the
                    // previous session.
                    self?.threads = []
                    self?.lastRefreshedAt = nil
                } else {
                    await self?.refresh()
                }
            }
        }
    }
}

// MARK: - Firestore implementation

@MainActor
final class MobileAssistantChatFirestoreSource: MobileAssistantChatRemoteSource {
    private let firestoreProvider: () -> Firestore

    init(firestoreProvider: @escaping () -> Firestore = { Firestore.firestore() }) {
        self.firestoreProvider = firestoreProvider
    }

    var isAvailable: Bool {
        FirebaseApp.app() != nil && Auth.auth().currentUser != nil
    }

    func fetchAll() async throws -> [MobileAssistantChatThread] {
        guard FirebaseApp.app() != nil else { throw NSError(domain: "MobileAssistantChat", code: 1) }
        guard let uid = Auth.auth().currentUser?.uid else {
            throw NSError(domain: "MobileAssistantChat", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Not signed in"])
        }
        let snapshot = try await firestoreProvider()
            .collection("users").document(uid).collection("mobile_assistant_chats")
            .order(by: "updatedAt", descending: true)
            .limit(to: 200)
            .getDocuments()
        return snapshot.documents.compactMap { document in
            Self.decodeThread(documentID: document.documentID, data: document.data())
        }
    }

    static func decodeThread(documentID: String, data: [String: Any]) -> MobileAssistantChatThread? {
        guard let runtime = data["runtime"] as? String, !runtime.isEmpty else { return nil }
        let id = (data["id"] as? String) ?? documentID
        let title = (data["title"] as? String) ?? "Chat"
        let preview = (data["preview"] as? String) ?? ""
        let modelName = data["modelName"] as? String
        let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
        let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() ?? createdAt
        let messageCount = (data["messageCount"] as? Int) ?? ((data["messages"] as? [Any])?.count ?? 0)
        let messages = (data["messages"] as? [[String: Any]] ?? []).compactMap(decodeMessage)
        return MobileAssistantChatThread(
            id: id,
            runtime: runtime,
            title: title,
            preview: preview,
            modelName: modelName,
            createdAt: createdAt,
            updatedAt: updatedAt,
            messageCount: messageCount,
            messages: messages
        )
    }

    static func decodeMessage(_ raw: [String: Any]) -> MobileAssistantChatMessage? {
        guard let role = raw["role"] as? String,
              let text = raw["text"] as? String else { return nil }
        let id = (raw["id"] as? String) ?? UUID().uuidString
        let timestamp = (raw["timestamp"] as? Timestamp)?.dateValue() ?? Date()
        let modelName = raw["modelName"] as? String
        let isError = (raw["isError"] as? Bool) ?? false
        let attachments = (raw["attachments"] as? [[String: Any]] ?? []).compactMap(decodeAttachment)
        let hermes = raw["hermes"] as? [String: Any]
        let toolCalls = (hermes?["toolCalls"] as? [[String: Any]] ?? []).compactMap(decodeToolCall)
        let usage = (hermes?["usage"] as? [String: Any]).flatMap(decodeUsage)
        return MobileAssistantChatMessage(
            id: id,
            role: role,
            text: text,
            timestamp: timestamp,
            modelName: modelName,
            isError: isError,
            attachments: attachments,
            toolCalls: toolCalls,
            usage: usage
        )
    }

    static func decodeAttachment(_ raw: [String: Any]) -> MobileAssistantChatAttachment? {
        guard let id = raw["id"] as? String,
              let kind = raw["kind"] as? String,
              let displayName = raw["displayName"] as? String,
              let mimeType = raw["mimeType"] as? String,
              let byteSize = raw["byteSize"] as? Int,
              let path = raw["workspaceRelativePath"] as? String else { return nil }
        return MobileAssistantChatAttachment(
            id: id,
            kind: kind,
            displayName: displayName,
            mimeType: mimeType,
            byteSize: byteSize,
            workspaceRelativePath: path,
            extractedTextPreview: raw["extractedTextPreview"] as? String
        )
    }

    static func decodeToolCall(_ raw: [String: Any]) -> MobileAssistantChatToolCall? {
        guard let id = raw["id"] as? String,
              let name = raw["name"] as? String,
              let status = raw["status"] as? String else { return nil }
        return MobileAssistantChatToolCall(id: id, name: name, status: status)
    }

    static func decodeUsage(_ raw: [String: Any]) -> MobileAssistantChatTokenUsage? {
        let outputTokens = raw["outputTokens"] as? Int
        let totalTokens = raw["totalTokens"] as? Int
        let source = raw["source"] as? String
        let providerGenerationDurationSeconds = raw["providerGenerationDurationSeconds"] as? TimeInterval
        let providerTotalDurationSeconds = raw["providerTotalDurationSeconds"] as? TimeInterval
        let responseStartedAt = (raw["responseStartedAt"] as? Timestamp)?.dateValue()
        let firstResponseChunkAt = (raw["firstResponseChunkAt"] as? Timestamp)?.dateValue()
        let responseCompletedAt = (raw["responseCompletedAt"] as? Timestamp)?.dateValue()
        if outputTokens == nil && totalTokens == nil && source == nil
            && providerGenerationDurationSeconds == nil && providerTotalDurationSeconds == nil
            && responseStartedAt == nil && firstResponseChunkAt == nil && responseCompletedAt == nil {
            return nil
        }
        return MobileAssistantChatTokenUsage(
            outputTokens: outputTokens,
            totalTokens: totalTokens,
            source: source,
            providerGenerationDurationSeconds: providerGenerationDurationSeconds,
            providerTotalDurationSeconds: providerTotalDurationSeconds,
            responseStartedAt: responseStartedAt,
            firstResponseChunkAt: firstResponseChunkAt,
            responseCompletedAt: responseCompletedAt
        )
    }
}

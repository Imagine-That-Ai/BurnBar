import Foundation
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import OpenBurnBarCore
import OSLog

// MARK: - Models

/// Lightweight, runtime-agnostic representation of an assistant chat thread
/// persisted by the mobile app. Used as the single source of truth for the
/// "chat history" list both `PiConversationListView` and the on-device section
/// of `HermesConversationListView` read from.
struct MobileChatThread: Identifiable, Codable, Equatable {
    let id: String
    let runtime: String
    var title: String
    var preview: String
    var modelName: String?
    var createdAt: Date
    var updatedAt: Date
    var messages: [MobileChatMessage]

    var messageCount: Int { messages.count }
}

struct MobileChatMessage: Identifiable, Codable, Equatable {
    let id: String
    let role: String
    var text: String
    var timestamp: Date
    var modelName: String?
    var isError: Bool
    /// Files the user attached when sending this message. Restored verbatim
    /// from the local store; cloud writes strip `thumbnailPNG` to keep doc
    /// size bounded (the thumbnail is regenerated from the workspace file on
    /// re-render, or shown as a generic glyph for the kind if the source
    /// file is no longer present).
    var attachments: [MobileChatAttachment]
    /// Hermes-specific telemetry: token usage, tool calls, model IDs,
    /// generation timestamps. `nil` for runtimes that don't produce stats
    /// (currently Pi).
    var hermes: MobileChatHermesMetadata?

    init(
        id: String = UUID().uuidString,
        role: String,
        text: String,
        timestamp: Date = Date(),
        modelName: String? = nil,
        isError: Bool = false,
        attachments: [MobileChatAttachment] = [],
        hermes: MobileChatHermesMetadata? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.modelName = modelName
        self.isError = isError
        self.attachments = attachments
        self.hermes = hermes
    }

    // Custom decoder so older JSON files (pre-attachments) load cleanly.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.role = try container.decode(String.self, forKey: .role)
        self.text = try container.decode(String.self, forKey: .text)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.modelName = try container.decodeIfPresent(String.self, forKey: .modelName)
        self.isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        self.attachments = try container.decodeIfPresent([MobileChatAttachment].self, forKey: .attachments) ?? []
        self.hermes = try container.decodeIfPresent(MobileChatHermesMetadata.self, forKey: .hermes)
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, timestamp, modelName, isError, attachments, hermes
    }
}

/// Persisted shape of a user attachment. Mirrors `HermesAttachment` (which
/// lives in `OpenBurnBarCore`) but is stored as a local copy in the chat
/// history file so the message can be restored without re-resolving the
/// workspace, and so the model can extend over time without breaking the
/// shared core type.
struct MobileChatAttachment: Codable, Equatable, Identifiable {
    var id: String
    var kind: String
    var displayName: String
    var mimeType: String
    var byteSize: Int
    var workspaceRelativePath: String
    /// Compact PNG thumbnail. Persisted locally; intentionally dropped from
    /// the Firestore mirror to stay under the 1 MiB document ceiling.
    var thumbnailPNG: Data?
    var extractedTextPreview: String?

    init(
        id: String,
        kind: String,
        displayName: String,
        mimeType: String,
        byteSize: Int,
        workspaceRelativePath: String,
        thumbnailPNG: Data? = nil,
        extractedTextPreview: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.workspaceRelativePath = workspaceRelativePath
        self.thumbnailPNG = thumbnailPNG
        self.extractedTextPreview = extractedTextPreview
    }
}

/// Hermes-only metadata attached to a persisted message. Kept distinct from
/// `MobileChatMessage` proper so the storage model stays runtime-agnostic.
struct MobileChatHermesMetadata: Codable, Equatable {
    var requestedModelID: String?
    var responseModelID: String?
    var toolCalls: [MobileChatToolCall]
    var usage: MobileChatTokenUsage?

    init(
        requestedModelID: String? = nil,
        responseModelID: String? = nil,
        toolCalls: [MobileChatToolCall] = [],
        usage: MobileChatTokenUsage? = nil
    ) {
        self.requestedModelID = requestedModelID
        self.responseModelID = responseModelID
        self.toolCalls = toolCalls
        self.usage = usage
    }
}

struct MobileChatToolCall: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var status: String
}

/// Token-usage + duration telemetry. Mirrors the trustworthy-rate model from
/// `HermesChatMessage` so the UI can render the same "exact vs. estimated"
/// distinction after a thread is reloaded.
struct MobileChatTokenUsage: Codable, Equatable {
    var outputTokens: Int?
    var totalTokens: Int?
    /// `"providerUsage"` or `"estimatedText"`.
    var source: String?
    var providerGenerationDurationSeconds: TimeInterval?
    var providerTotalDurationSeconds: TimeInterval?
    var responseStartedAt: Date?
    var firstResponseChunkAt: Date?
    var responseCompletedAt: Date?
}

/// Disk envelope: the JSON file holds both the live thread list and a set of
/// tombstones for threads deleted while offline. The tombstones survive a
/// cloud refresh so a delete is never silently undone.
struct MobileChatHistorySnapshot: Codable, Equatable {
    var threads: [MobileChatThread]
    var tombstones: [String: Date]

    init(threads: [MobileChatThread] = [], tombstones: [String: Date] = [:]) {
        self.threads = threads
        self.tombstones = tombstones
    }
}

// MARK: - Persistence boundaries

protocol MobileChatLocalStoring: AnyObject {
    /// Switches the active partition (e.g. when the signed-in user changes).
    /// Implementations should isolate data per-key so different accounts on
    /// the same device never share chat history.
    func setActivePartition(_ key: String)
    func load() throws -> MobileChatHistorySnapshot
    func save(_ snapshot: MobileChatHistorySnapshot) throws
}

@MainActor
protocol MobileChatCloudMirroring: AnyObject {
    func upsert(_ thread: MobileChatThread) async throws
    func delete(threadID: String) async throws
    func fetchAll() async throws -> [MobileChatThread]
    /// True when the cloud mirror has an authenticated user it can act on.
    var isAvailable: Bool { get }
    /// Current user identifier, when available. Used to scope local storage so
    /// two accounts on the same device don't share a chat-history file.
    var currentUserID: String? { get }
}

// MARK: - Local file persistence

/// JSON-on-disk persistence under Application Support so chats survive cache
/// eviction. One file per partition key (typically a Firebase uid, or `"local"`
/// when signed out) keeps account data isolated on the device.
final class MobileChatFileLocalStore: MobileChatLocalStoring {
    private let directory: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "mobile-chat-history.local-store", qos: .utility)
    private let logger = Logger(subsystem: "com.openburnbar.mobile", category: "MobileChatLocalStore")
    private var partitionKey: String = "local"

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        let appDir = base.appendingPathComponent("OpenBurnBar", isDirectory: true)
        try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
        self.directory = appDir
    }

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func setActivePartition(_ key: String) {
        let sanitized = Self.sanitizePartitionKey(key)
        queue.sync { partitionKey = sanitized }
    }

    func load() throws -> MobileChatHistorySnapshot {
        try queue.sync {
            let url = fileURL(for: partitionKey)
            guard fileManager.fileExists(atPath: url.path) else { return MobileChatHistorySnapshot() }
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do {
                return try decoder.decode(MobileChatHistorySnapshot.self, from: data)
            } catch {
                // Legacy file shape (a bare array of threads) — read it once
                // and let the next save() upgrade the envelope.
                let legacy = try decoder.decode([MobileChatThread].self, from: data)
                return MobileChatHistorySnapshot(threads: legacy, tombstones: [:])
            }
        }
    }

    func save(_ snapshot: MobileChatHistorySnapshot) throws {
        try queue.sync {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            let url = fileURL(for: partitionKey)
            try data.write(to: url, options: [.atomic])
        }
    }

    private func fileURL(for partition: String) -> URL {
        directory.appendingPathComponent("mobile-chat-history-\(partition).json")
    }

    static func sanitizePartitionKey(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let cleaned = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? "local" : cleaned
    }
}

// MARK: - Firestore mirror

/// Mirrors threads to `users/{uid}/mobile_assistant_chats/{threadId}` with
/// inline messages. Inline messages keep the read path one round-trip; chat
/// docs almost never exceed Firestore's 1 MiB limit on mobile.
@MainActor
final class MobileChatFirestoreStore: MobileChatCloudMirroring {
    private let firestoreProvider: () -> Firestore
    private let logger = Logger(subsystem: "com.openburnbar.mobile", category: "MobileChatFirestoreStore")

    init(firestoreProvider: @escaping () -> Firestore = { Firestore.firestore() }) {
        self.firestoreProvider = firestoreProvider
    }

    var isAvailable: Bool {
        FirebaseApp.app() != nil && Auth.auth().currentUser != nil
    }

    var currentUserID: String? {
        guard FirebaseApp.app() != nil else { return nil }
        return Auth.auth().currentUser?.uid
    }

    private static func collection(for db: Firestore, uid: String) -> CollectionReference {
        db.collection("users").document(uid).collection("mobile_assistant_chats")
    }

    private func resolveUID() throws -> String {
        guard FirebaseApp.app() != nil else { throw FirestoreError.firebaseUnavailable }
        guard let uid = Auth.auth().currentUser?.uid else { throw FirestoreError.notAuthenticated }
        return uid
    }

    func upsert(_ thread: MobileChatThread) async throws {
        let uid = try resolveUID()
        let db = firestoreProvider()
        let payload: [String: Any] = [
            "id": thread.id,
            "runtime": thread.runtime,
            "title": thread.title,
            "preview": thread.preview,
            "modelName": thread.modelName as Any,
            "createdAt": Timestamp(date: thread.createdAt),
            "updatedAt": Timestamp(date: thread.updatedAt),
            "messageCount": thread.messageCount,
            "messages": thread.messages.map(Self.encodeMessageForCloud)
        ]
        try await Self.collection(for: db, uid: uid).document(thread.id).setData(payload, merge: false)
    }

    static func encodeMessageForCloud(_ message: MobileChatMessage) -> [String: Any] {
        var payload: [String: Any] = [
            "id": message.id,
            "role": message.role,
            "text": message.text,
            "timestamp": Timestamp(date: message.timestamp),
            "modelName": message.modelName as Any,
            "isError": message.isError
        ]
        if !message.attachments.isEmpty {
            payload["attachments"] = message.attachments.map(encodeAttachmentForCloud)
        }
        if let hermes = message.hermes {
            payload["hermes"] = encodeHermesMetadataForCloud(hermes)
        }
        return payload
    }

    /// Strips the (possibly large) PNG thumbnail before sending to Firestore.
    /// The thumbnail lives in the local cache; cross-device sync renders a
    /// kind-based placeholder if the receiving device doesn't have the file.
    static func encodeAttachmentForCloud(_ attachment: MobileChatAttachment) -> [String: Any] {
        var dict: [String: Any] = [
            "id": attachment.id,
            "kind": attachment.kind,
            "displayName": attachment.displayName,
            "mimeType": attachment.mimeType,
            "byteSize": attachment.byteSize,
            "workspaceRelativePath": attachment.workspaceRelativePath
        ]
        if let preview = attachment.extractedTextPreview {
            dict["extractedTextPreview"] = preview
        }
        return dict
    }

    static func encodeHermesMetadataForCloud(_ metadata: MobileChatHermesMetadata) -> [String: Any] {
        var dict: [String: Any] = [:]
        if let requested = metadata.requestedModelID { dict["requestedModelID"] = requested }
        if let response = metadata.responseModelID { dict["responseModelID"] = response }
        if !metadata.toolCalls.isEmpty {
            dict["toolCalls"] = metadata.toolCalls.map { ["id": $0.id, "name": $0.name, "status": $0.status] }
        }
        if let usage = metadata.usage {
            var usageDict: [String: Any] = [:]
            if let v = usage.outputTokens { usageDict["outputTokens"] = v }
            if let v = usage.totalTokens { usageDict["totalTokens"] = v }
            if let v = usage.source { usageDict["source"] = v }
            if let v = usage.providerGenerationDurationSeconds { usageDict["providerGenerationDurationSeconds"] = v }
            if let v = usage.providerTotalDurationSeconds { usageDict["providerTotalDurationSeconds"] = v }
            if let v = usage.responseStartedAt { usageDict["responseStartedAt"] = Timestamp(date: v) }
            if let v = usage.firstResponseChunkAt { usageDict["firstResponseChunkAt"] = Timestamp(date: v) }
            if let v = usage.responseCompletedAt { usageDict["responseCompletedAt"] = Timestamp(date: v) }
            if !usageDict.isEmpty { dict["usage"] = usageDict }
        }
        return dict
    }

    func delete(threadID: String) async throws {
        let uid = try resolveUID()
        let db = firestoreProvider()
        try await Self.collection(for: db, uid: uid).document(threadID).delete()
    }

    func fetchAll() async throws -> [MobileChatThread] {
        let uid = try resolveUID()
        let db = firestoreProvider()
        let snapshot = try await Self.collection(for: db, uid: uid)
            .order(by: "updatedAt", descending: true)
            .limit(to: 200)
            .getDocuments()

        return snapshot.documents.compactMap { document in
            Self.decodeThread(documentID: document.documentID, data: document.data())
        }
    }

    static func decodeThread(documentID: String, data: [String: Any]) -> MobileChatThread? {
        let runtime = (data["runtime"] as? String) ?? ""
        guard !runtime.isEmpty else { return nil }
        let id = (data["id"] as? String) ?? documentID
        let title = (data["title"] as? String) ?? "Chat"
        let preview = (data["preview"] as? String) ?? ""
        let modelName = data["modelName"] as? String
        let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
        let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() ?? createdAt
        let rawMessages = (data["messages"] as? [[String: Any]]) ?? []
        let messages = rawMessages.compactMap(decodeMessage)
        return MobileChatThread(
            id: id,
            runtime: runtime,
            title: title,
            preview: preview,
            modelName: modelName,
            createdAt: createdAt,
            updatedAt: updatedAt,
            messages: messages
        )
    }

    static func decodeMessage(_ raw: [String: Any]) -> MobileChatMessage? {
        guard let role = raw["role"] as? String,
              let text = raw["text"] as? String else {
            return nil
        }
        let id = (raw["id"] as? String) ?? UUID().uuidString
        let timestamp = (raw["timestamp"] as? Timestamp)?.dateValue() ?? Date()
        let modelName = raw["modelName"] as? String
        let isError = (raw["isError"] as? Bool) ?? false
        let attachments = (raw["attachments"] as? [[String: Any]] ?? []).compactMap(decodeAttachment)
        let hermes = (raw["hermes"] as? [String: Any]).flatMap(decodeHermesMetadata)
        return MobileChatMessage(
            id: id,
            role: role,
            text: text,
            timestamp: timestamp,
            modelName: modelName,
            isError: isError,
            attachments: attachments,
            hermes: hermes
        )
    }

    static func decodeAttachment(_ raw: [String: Any]) -> MobileChatAttachment? {
        guard let id = raw["id"] as? String,
              let kind = raw["kind"] as? String,
              let displayName = raw["displayName"] as? String,
              let mimeType = raw["mimeType"] as? String,
              let byteSize = raw["byteSize"] as? Int,
              let workspaceRelativePath = raw["workspaceRelativePath"] as? String else {
            return nil
        }
        return MobileChatAttachment(
            id: id,
            kind: kind,
            displayName: displayName,
            mimeType: mimeType,
            byteSize: byteSize,
            workspaceRelativePath: workspaceRelativePath,
            thumbnailPNG: nil,
            extractedTextPreview: raw["extractedTextPreview"] as? String
        )
    }

    static func decodeHermesMetadata(_ raw: [String: Any]) -> MobileChatHermesMetadata? {
        let requested = raw["requestedModelID"] as? String
        let response = raw["responseModelID"] as? String
        let toolCalls = (raw["toolCalls"] as? [[String: Any]] ?? []).compactMap { dict -> MobileChatToolCall? in
            guard let id = dict["id"] as? String,
                  let name = dict["name"] as? String,
                  let status = dict["status"] as? String else { return nil }
            return MobileChatToolCall(id: id, name: name, status: status)
        }
        var usage: MobileChatTokenUsage?
        if let usageDict = raw["usage"] as? [String: Any] {
            usage = MobileChatTokenUsage(
                outputTokens: usageDict["outputTokens"] as? Int,
                totalTokens: usageDict["totalTokens"] as? Int,
                source: usageDict["source"] as? String,
                providerGenerationDurationSeconds: usageDict["providerGenerationDurationSeconds"] as? TimeInterval,
                providerTotalDurationSeconds: usageDict["providerTotalDurationSeconds"] as? TimeInterval,
                responseStartedAt: (usageDict["responseStartedAt"] as? Timestamp)?.dateValue(),
                firstResponseChunkAt: (usageDict["firstResponseChunkAt"] as? Timestamp)?.dateValue(),
                responseCompletedAt: (usageDict["responseCompletedAt"] as? Timestamp)?.dateValue()
            )
        }
        // Avoid creating an empty metadata blob.
        if requested == nil && response == nil && toolCalls.isEmpty && usage == nil {
            return nil
        }
        return MobileChatHermesMetadata(
            requestedModelID: requested,
            responseModelID: response,
            toolCalls: toolCalls,
            usage: usage
        )
    }
}

// MARK: - Store

/// Observable singleton owning the on-device assistant chat history. Source of
/// truth for the conversation lists in `PiConversationListView` and the
/// "On this device" section of `HermesConversationListView`.
///
/// Per-user partitioning: the local file is namespaced by Firebase uid (or
/// `"local"` when signed out) so two accounts on the same device never see
/// each other's chats.
///
/// Tombstones: a delete is recorded as a tombstone before the cloud round-trip.
/// On the next refresh, tombstoned thread ids are subtracted from the remote
/// snapshot, preventing already-deleted threads from coming back as ghosts.
///
/// Backfill: any thread that exists locally but not in the remote snapshot
/// gets pushed up after `refreshFromCloud`, so chats started while offline
/// reach Firestore once the user is online and authenticated.
@MainActor
@Observable
final class MobileChatHistoryStore {
    static let shared = MobileChatHistoryStore()

    private(set) var threads: [MobileChatThread] = []
    private(set) var lastSyncError: String?

    private var tombstones: [String: Date] = [:]
    private let local: MobileChatLocalStoring
    private let cloud: MobileChatCloudMirroring?
    private let logger = Logger(subsystem: "com.openburnbar.mobile", category: "MobileChatHistoryStore")

    private var pendingMirrorTasks: [String: Task<Void, Never>] = [:]
    private var didLoadFromDisk = false
    private var activePartition: String = ""
    private var authListenerHandle: AuthStateDidChangeListenerHandle?

    init(
        local: MobileChatLocalStoring = MobileChatFileLocalStore(),
        cloud: MobileChatCloudMirroring? = MobileChatFirestoreStore()
    ) {
        self.local = local
        self.cloud = cloud
        switchPartition(to: cloud?.currentUserID)
        startObservingAuthIfPossible()
    }
    // No deinit — the store is a process-wide singleton, so the auth listener
    // lives for the lifetime of the app. Removing it would require a
    // nonisolated path that can't safely touch @MainActor state.

    /// Idempotent loader; safe to call on every app launch and from view tasks.
    func bootstrap() {
        loadFromDiskIfNeeded()
        Task { await refreshFromCloud() }
    }

    func loadFromDiskIfNeeded() {
        guard !didLoadFromDisk else { return }
        didLoadFromDisk = true
        loadFromDisk()
    }

    private func loadFromDisk() {
        do {
            let snapshot = try local.load()
            threads = Self.sorted(snapshot.threads.filter { !snapshot.tombstones.keys.contains($0.id) })
            tombstones = snapshot.tombstones
        } catch {
            logger.warning("Failed to load chat history from disk: \(String(describing: error), privacy: .public)")
            threads = []
            tombstones = [:]
        }
    }

    func refreshFromCloud() async {
        guard let cloud, cloud.isAvailable else { return }

        // 1. Pull cloud snapshot.
        let remote: [MobileChatThread]
        do {
            remote = try await cloud.fetchAll()
        } catch FirestoreError.notAuthenticated, FirestoreError.firebaseUnavailable {
            return
        } catch {
            lastSyncError = error.localizedDescription
            logger.warning("Failed to refresh chat history from cloud: \(String(describing: error), privacy: .public)")
            return
        }

        // 2. Tombstones take precedence over remote — drop any remote thread
        // the user already deleted on this device.
        let filteredRemote = remote.filter { !tombstones.keys.contains($0.id) }

        // 3. Merge with local, last-writer-wins on updatedAt.
        let merged = Self.merge(local: threads, remote: filteredRemote)
        threads = merged
        saveLocally()
        lastSyncError = nil

        // 4. Push local-only threads to the cloud so a chat created offline /
        // pre-auth actually reaches Firestore.
        let remoteIDs = Set(remote.map(\.id))
        for thread in merged where !remoteIDs.contains(thread.id) {
            scheduleCloudMirror(for: thread, immediate: true)
        }

        // 5. Retry cloud-side tombstone deletes (in case the original delete
        // happened offline). Local-only deletes for things that never reached
        // the cloud get their tombstone garbage-collected.
        let remoteThatNeedDelete = remoteIDs.intersection(tombstones.keys)
        for threadID in remoteThatNeedDelete {
            Task { [weak self, cloud] in
                do {
                    try await cloud.delete(threadID: threadID)
                    self?.tombstoneCleared(threadID)
                } catch FirestoreError.notAuthenticated, FirestoreError.firebaseUnavailable {
                    return
                } catch {
                    self?.logger.warning("Tombstone retry failed for \(threadID, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
        let neverInCloud = tombstones.keys.filter { !remoteIDs.contains($0) }
        for threadID in neverInCloud { tombstones.removeValue(forKey: threadID) }
        if !neverInCloud.isEmpty { saveLocally() }
    }

    func threads(for runtime: AssistantRuntimeID) -> [MobileChatThread] {
        threads.filter { $0.runtime == runtime.rawValue }
    }

    func thread(id: String) -> MobileChatThread? {
        threads.first { $0.id == id }
    }

    /// Upserts a thread, then mirrors to Firestore asynchronously. Calls during
    /// streaming coalesce per-thread so we don't fan out write storms.
    func upsert(_ thread: MobileChatThread) {
        guard !tombstones.keys.contains(thread.id) else {
            // The user already deleted this thread on this device. Refuse the
            // accidental resurrection from a late-arriving streaming callback.
            return
        }
        var updated = thread
        updated.updatedAt = Date()
        if let idx = threads.firstIndex(where: { $0.id == updated.id }) {
            threads[idx] = updated
        } else {
            threads.append(updated)
        }
        threads = Self.sorted(threads)
        saveLocally()
        scheduleCloudMirror(for: updated)
    }

    func delete(threadID: String) {
        threads.removeAll { $0.id == threadID }
        tombstones[threadID] = Date()
        saveLocally()

        guard let cloud else { return }
        Task { [weak self] in
            do {
                try await cloud.delete(threadID: threadID)
                self?.tombstoneCleared(threadID)
            } catch FirestoreError.notAuthenticated, FirestoreError.firebaseUnavailable {
                // Tombstone stays so we can retry next bootstrap.
                return
            } catch {
                self?.logger.warning("Failed to delete chat history doc \(threadID, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Resets the local cache without touching the cloud — used when the
    /// active Firebase user changes. The new partition is loaded from disk
    /// fresh, and a cloud refresh is kicked off so the new user immediately
    /// sees their own history.
    func switchPartition(to uid: String?) {
        let key = uid?.isEmpty == false ? uid! : "local"
        let sanitized = MobileChatFileLocalStore.sanitizePartitionKey(key)
        guard sanitized != activePartition else { return }
        activePartition = sanitized
        local.setActivePartition(sanitized)
        didLoadFromDisk = false
        threads = []
        tombstones = [:]
        loadFromDiskIfNeeded()
    }

    // MARK: - Internals

    private func tombstoneCleared(_ threadID: String) {
        guard tombstones.removeValue(forKey: threadID) != nil else { return }
        saveLocally()
    }

    private func saveLocally() {
        do {
            try local.save(MobileChatHistorySnapshot(threads: threads, tombstones: tombstones))
        } catch {
            logger.error("Failed to persist chat history to disk: \(String(describing: error), privacy: .public)")
        }
    }

    private func scheduleCloudMirror(for thread: MobileChatThread, immediate: Bool = false) {
        guard let cloud else { return }
        pendingMirrorTasks[thread.id]?.cancel()
        let task = Task { [weak self] in
            if !immediate {
                // Debounce — let rapid streaming updates collapse into one write.
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            if Task.isCancelled { return }
            do {
                try await cloud.upsert(thread)
                await MainActor.run { self?.pendingMirrorTasks[thread.id] = nil }
            } catch FirestoreError.notAuthenticated, FirestoreError.firebaseUnavailable {
                return
            } catch {
                await MainActor.run { self?.lastSyncError = error.localizedDescription }
            }
        }
        pendingMirrorTasks[thread.id] = task
    }

    private func startObservingAuthIfPossible() {
        guard FirebaseApp.app() != nil else { return }
        authListenerHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.switchPartition(to: user?.uid)
                await self?.refreshFromCloud()
            }
        }
    }

    static func sorted(_ threads: [MobileChatThread]) -> [MobileChatThread] {
        threads.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func merge(local: [MobileChatThread], remote: [MobileChatThread]) -> [MobileChatThread] {
        var byID: [String: MobileChatThread] = [:]
        for thread in local { byID[thread.id] = thread }
        for thread in remote {
            if let existing = byID[thread.id] {
                // Keep whichever side has the newer updatedAt. Local writes
                // happen continuously while streaming, so most of the time
                // local wins — but the remote copy carries history from other
                // devices, so we never silently drop it.
                byID[thread.id] = existing.updatedAt >= thread.updatedAt ? existing : thread
            } else {
                byID[thread.id] = thread
            }
        }
        return sorted(Array(byID.values))
    }
}

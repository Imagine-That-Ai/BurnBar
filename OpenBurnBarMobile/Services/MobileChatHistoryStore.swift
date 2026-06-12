import Foundation
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import OpenBurnBarCore
import OpenBurnBarSignalCore
import OSLog

// MARK: - Models

/// Lightweight, runtime-agnostic representation of an assistant chat thread
/// persisted by the mobile app. Used as the single source of truth for the
/// "chat history" list that native mobile assistants read from: Hermes, Pi,
/// and Mac-backed CLI chats such as Codex, Claude Code, and OpenClaw.
struct MobileChatThread: Identifiable, Codable, Equatable {
    let id: String
    let runtime: String
    var title: String
    var preview: String
    var modelName: String?
    var createdAt: Date
    var updatedAt: Date
    var messages: [MobileChatMessage]

    // Custom metadata fields for custom title, HSL label color, pinning, and priority order
    var customTitle: String? = nil
    var labelColorHex: String? = nil
    var isPinned: Bool? = nil
    var priorityOrder: Int? = nil

    var messageCount: Int { messages.count }

    var recentAttachmentPreviews: [HermesAttachment] {
        var previews: [HermesAttachment] = []
        for message in messages.reversed() where !message.attachments.isEmpty {
            for attachment in message.attachments {
                previews.append(attachment.asHermesAttachment)
                if previews.count == 3 { return previews }
            }
        }
        return previews
    }
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
    /// Runtime-agnostic record of the tools the model invoked while producing
    /// this message. Populated by both Hermes and Pi. Pre-existing Hermes
    /// records that stored tool calls under `hermes.toolCalls` are merged into
    /// this list on decode, so reloaded threads always render through a single
    /// path.
    var toolCalls: [MobileChatToolCall]
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
        toolCalls: [MobileChatToolCall] = [],
        hermes: MobileChatHermesMetadata? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.modelName = modelName
        self.isError = isError
        self.attachments = attachments
        self.toolCalls = toolCalls
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
        let topLevelToolCalls = try container.decodeIfPresent([MobileChatToolCall].self, forKey: .toolCalls) ?? []
        let hermes = try container.decodeIfPresent(MobileChatHermesMetadata.self, forKey: .hermes)
        // Legacy threads stored tool calls only under `hermes.toolCalls`. Merge
        // them into the top-level list so callers don't need to look in two
        // places. Dedup by id so a thread written by a new build (which writes
        // to both fields for forward-compat) doesn't double-up.
        if topLevelToolCalls.isEmpty, let legacyToolCalls = hermes?.toolCalls, !legacyToolCalls.isEmpty {
            self.toolCalls = legacyToolCalls
        } else {
            self.toolCalls = topLevelToolCalls
        }
        self.hermes = hermes
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, timestamp, modelName, isError, attachments, toolCalls, hermes
    }
}

extension MobileChatAttachment {
    var asHermesAttachment: HermesAttachment {
        HermesAttachment(
            id: id,
            kind: HermesAttachmentKind(rawValue: kind) ?? .generic,
            displayName: displayName,
            mimeType: mimeType,
            byteSize: byteSize,
            workspaceRelativePath: workspaceRelativePath,
            thumbnailPNG: thumbnailPNG,
            extractedTextPreview: extractedTextPreview
        )
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

/// Persisted record of a single tool the model decided to invoke. `detail` is
/// a short human-readable preview of the arguments (path, command, query) so
/// the pill in a reloaded thread still shows *what* the tool was working on,
/// not just *that* a tool ran.
struct MobileChatToolCall: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var status: String
    var detail: String?

    init(id: String, name: String, status: String, detail: String? = nil) {
        self.id = id
        self.name = name
        self.status = status
        self.detail = detail
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.status = try container.decode(String.self, forKey: .status)
        self.detail = try container.decodeIfPresent(String.self, forKey: .detail)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, status, detail
    }
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
/// eviction.
///
/// Storage layout (finding-178 — per-thread split): instead of one monolithic
/// `mobile-chat-history-<partition>.json` rewritten in full on *every* chat turn
/// (O(total history) per turn, single-file blast radius), each partition gets a
/// directory holding:
///
///   * `index.json` — a compact metadata index (tombstones + a per-thread
///     content digest used to skip unchanged writes). Small and cheap to render
///     a conversation list from.
///   * `thread-<sanitizedID>.json` — one compact file per thread body.
///
/// A `save(_:)` only rewrites the thread files whose body actually changed plus
/// the index, so a streaming turn touches a single small file rather than the
/// whole history. JSON is compact (no `.prettyPrinted` / `.sortedKeys`) to keep
/// the bytes — and therefore the synchronous encode cost — minimal.
///
/// The protocol surface (`MobileChatLocalStoring`) is unchanged: `load()` still
/// returns the full snapshot (callers list from it), and `save(_:)` still takes
/// the full snapshot — we diff it against disk internally. A one-time idempotent
/// migration explodes the legacy single-file snapshot into the new layout on the
/// first `load()` (or `save()`) of a partition.
final class MobileChatFileLocalStore: MobileChatLocalStoring {
    private let directory: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "mobile-chat-history.local-store", qos: .utility)
    private let logger = Logger(subsystem: "com.openburnbar.mobile", category: "MobileChatLocalStore")
    private var partitionKey: String = "local"

    /// Per-partition cache of the last-written content digest for each thread id,
    /// so a `save()` can skip rewriting thread bodies that did not change. Keyed
    /// by partition so switching users never cross-contaminates. Reset lazily
    /// from disk on the first access of a partition.
    private var digestCache: [String: [String: Int]] = [:]
    private var migratedPartitions: Set<String> = []

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
            try migrateLegacyFileIfNeeded(for: partitionKey)
            return try loadSnapshotLocked(for: partitionKey)
        }
    }

    func save(_ snapshot: MobileChatHistorySnapshot) throws {
        try queue.sync {
            // Folding the legacy single-file snapshot in first keeps a save that
            // runs before any load() idempotent and lossless.
            try migrateLegacyFileIfNeeded(for: partitionKey)
            try saveSnapshotLocked(snapshot, for: partitionKey)
        }
    }

    // MARK: - Locked helpers (must run on `queue`)

    private func loadSnapshotLocked(for partition: String) throws -> MobileChatHistorySnapshot {
        let dir = partitionDirectory(for: partition)
        guard fileManager.fileExists(atPath: dir.path) else {
            digestCache[partition] = [:]
            return MobileChatHistorySnapshot()
        }
        let decoder = Self.makeDecoder()
        let index = try loadIndexLocked(for: partition, decoder: decoder)

        var threads: [MobileChatThread] = []
        var digests: [String: Int] = [:]
        threads.reserveCapacity(index.threadIDs.count)
        for threadID in index.threadIDs {
            let url = threadFileURL(for: partition, threadID: threadID)
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let thread = try? decoder.decode(MobileChatThread.self, from: data) else { continue }
            threads.append(thread)
            digests[thread.id] = Self.digest(of: data)
        }
        digestCache[partition] = digests
        return MobileChatHistorySnapshot(threads: threads, tombstones: index.tombstones)
    }

    private func saveSnapshotLocked(_ snapshot: MobileChatHistorySnapshot, for partition: String) throws {
        let dir = partitionDirectory(for: partition)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = Self.makeEncoder()

        var nextDigests: [String: Int] = [:]
        let previousDigests = digestCache[partition] ?? loadDigestsFromDiskLocked(for: partition)
        let liveIDs = Set(snapshot.threads.map(\.id))

        // 1. Write only the thread bodies whose serialized content changed.
        for thread in snapshot.threads {
            let data = try encoder.encode(thread)
            let digest = Self.digest(of: data)
            nextDigests[thread.id] = digest
            if previousDigests[thread.id] == digest,
               fileManager.fileExists(atPath: threadFileURL(for: partition, threadID: thread.id).path) {
                continue // Unchanged body already on disk — skip the rewrite.
            }
            try data.write(to: threadFileURL(for: partition, threadID: thread.id), options: [.atomic])
        }

        // 2. Remove thread files that are no longer part of the snapshot.
        for staleID in previousDigests.keys where !liveIDs.contains(staleID) {
            try? fileManager.removeItem(at: threadFileURL(for: partition, threadID: staleID))
        }

        // 3. Rewrite the small index (cheap regardless of history size).
        let index = MobileChatHistoryIndex(
            threadIDs: snapshot.threads.map(\.id),
            tombstones: snapshot.tombstones
        )
        let indexData = try encoder.encode(index)
        try indexData.write(to: indexFileURL(for: partition), options: [.atomic])

        digestCache[partition] = nextDigests
    }

    private func loadIndexLocked(for partition: String, decoder: JSONDecoder) throws -> MobileChatHistoryIndex {
        let url = indexFileURL(for: partition)
        guard let data = try? Data(contentsOf: url) else {
            // No index yet but the directory exists — recover by scanning the
            // thread files present, so a partially migrated/corrupt partition
            // still surfaces its threads instead of vanishing.
            return MobileChatHistoryIndex(threadIDs: scanThreadIDsLocked(for: partition), tombstones: [:])
        }
        return try decoder.decode(MobileChatHistoryIndex.self, from: data)
    }

    private func loadDigestsFromDiskLocked(for partition: String) -> [String: Int] {
        let dir = partitionDirectory(for: partition)
        guard fileManager.fileExists(atPath: dir.path) else { return [:] }
        var digests: [String: Int] = [:]
        let ids = (try? loadIndexLocked(for: partition, decoder: Self.makeDecoder()).threadIDs)
            ?? scanThreadIDsLocked(for: partition)
        for threadID in ids {
            if let data = try? Data(contentsOf: threadFileURL(for: partition, threadID: threadID)) {
                digests[threadID] = Self.digest(of: data)
            }
        }
        return digests
    }

    private func scanThreadIDsLocked(for partition: String) -> [String] {
        let dir = partitionDirectory(for: partition)
        guard let entries = try? fileManager.contentsOfDirectory(atPath: dir.path) else { return [] }
        return entries.compactMap { name in
            guard name.hasPrefix("thread-"), name.hasSuffix(".json") else { return nil }
            return String(name.dropFirst("thread-".count).dropLast(".json".count))
        }
    }

    /// One-time idempotent migration: explode the legacy single-file snapshot
    /// (`mobile-chat-history-<partition>.json`, either the envelope shape or a
    /// bare thread array) into the per-thread directory layout. Safe to run
    /// twice — once the legacy file is consumed it is deleted, and a partition
    /// already migrated short-circuits. If the new layout already has an index,
    /// the legacy file is treated as stale and removed without clobbering newer
    /// per-thread writes.
    private func migrateLegacyFileIfNeeded(for partition: String) throws {
        guard !migratedPartitions.contains(partition) else { return }
        defer { migratedPartitions.insert(partition) }

        let legacyURL = legacyFileURL(for: partition)
        guard fileManager.fileExists(atPath: legacyURL.path) else { return }

        // If a per-thread index already exists, the new layout is authoritative.
        // Drop the stale legacy file so re-running never resurrects old bodies.
        if fileManager.fileExists(atPath: indexFileURL(for: partition).path) {
            try? fileManager.removeItem(at: legacyURL)
            return
        }

        let decoder = Self.makeDecoder()
        let data = try Data(contentsOf: legacyURL)
        let snapshot: MobileChatHistorySnapshot
        if let envelope = try? decoder.decode(MobileChatHistorySnapshot.self, from: data) {
            snapshot = envelope
        } else if let legacyThreads = try? decoder.decode([MobileChatThread].self, from: data) {
            snapshot = MobileChatHistorySnapshot(threads: legacyThreads, tombstones: [:])
        } else {
            // Unreadable legacy file: leave it in place rather than lose data,
            // but don't block the partition from operating on the new layout.
            digestCache[partition] = [:]
            return
        }

        // Reset any partial state for this partition, then write the new layout.
        digestCache[partition] = [:]
        try saveSnapshotLocked(snapshot, for: partition)
        // Consume the legacy file only after the new layout is durably written.
        try? fileManager.removeItem(at: legacyURL)
    }

    // MARK: - Paths

    private func partitionDirectory(for partition: String) -> URL {
        directory.appendingPathComponent("mobile-chat-history-\(partition)", isDirectory: true)
    }

    private func indexFileURL(for partition: String) -> URL {
        partitionDirectory(for: partition).appendingPathComponent("index.json")
    }

    private func threadFileURL(for partition: String, threadID: String) -> URL {
        let safe = Self.sanitizeThreadFileComponent(threadID)
        return partitionDirectory(for: partition).appendingPathComponent("thread-\(safe).json")
    }

    private func legacyFileURL(for partition: String) -> URL {
        directory.appendingPathComponent("mobile-chat-history-\(partition).json")
    }

    // MARK: - Encoding

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Compact: drop prettyPrinted/sortedKeys to minimize bytes and the
        // synchronous encode cost on the hot per-turn write path.
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Stable content digest of serialized thread bytes. Used only to skip
    /// rewriting unchanged thread bodies; collisions merely cost a redundant
    /// write, never data loss (the snapshot is always the source of truth).
    private static func digest(of data: Data) -> Int {
        var hasher = Hasher()
        hasher.combine(data)
        return hasher.finalize()
    }

    static func sanitizePartitionKey(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let cleaned = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? "local" : cleaned
    }

    /// Maps an arbitrary thread id to a filesystem-safe file component. Unlike
    /// the partition key, thread ids must round-trip 1:1 on load via the index,
    /// so we percent-escape disallowed characters rather than collapse them.
    static func sanitizeThreadFileComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        var out = ""
        out.reserveCapacity(raw.count)
        for scalar in raw.unicodeScalars {
            if allowed.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else {
                out += String(format: "_%04x", scalar.value)
            }
        }
        return out.isEmpty ? "_thread" : out
    }
}

/// Compact metadata index persisted alongside the per-thread body files. Holds
/// only what the conversation list and offline-delete bookkeeping need, so it
/// stays small even as history grows.
private struct MobileChatHistoryIndex: Codable {
    var threadIDs: [String]
    var tombstones: [String: Date]
}

// MARK: - Firestore mirror

/// Mirrors threads to `users/{uid}/mobile_assistant_chats/{threadId}` with
/// private chat content sealed inside `sealedPayload`. Top-level fields are
/// limited to routing/count/list metadata.
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
        let resolvedKey = try await MobileCloudVaultKeyAccess.keyForWriting(uid: uid, firestore: db)
        let cloudThread = Self.threadForCloud(thread)
        let payloadData = try Self.cloudPayloadEncoder.encode(cloudThread)
        let sealedPayload = try CloudVaultCrypto.sealPayload(
            payloadData,
            keyData: resolvedKey.keyData,
            vaultKeyID: resolvedKey.vaultKeyID
        )
        var payload: [String: Any] = [
            "id": thread.id,
            "runtime": thread.runtime,
            "createdAt": Timestamp(date: thread.createdAt),
            "updatedAt": Timestamp(date: thread.updatedAt),
            "messageCount": thread.messageCount,
            "contentSealed": true,
            "sealedSchemaVersion": 2,
            "vaultKeyID": resolvedKey.vaultKeyID,
            "sealedPayload": CloudVaultCrypto.sealedPayloadDictionary(sealedPayload)
        ]
        if let labelColorHex = thread.labelColorHex {
            payload["labelColorHex"] = labelColorHex
        }
        if let isPinned = thread.isPinned {
            payload["isPinned"] = isPinned
        }
        if let priorityOrder = thread.priorityOrder {
            payload["priorityOrder"] = priorityOrder
        }
        if let last = thread.messages.last {
            payload["lastMessageRole"] = last.role
        }
        if let assistant = thread.messages.last(where: { $0.role == "assistant" }) {
            payload["lastAssistantMessageID"] = assistant.id
        }
        // At-rest Signal dual-write (item 3). The legacy AES-GCM sealedPayload above is the
        // FLOOR; the additive Signal envelope is BEST-EFFORT and gated by the
        // conversations_chat sealingScheme. On ANY seal failure (e.g. a trusted device
        // without a published identity) log and write legacy-only rather than abort the
        // upsert — legacy is already end-to-end so no confidentiality is lost. (merge:false
        // below fully overwrites the doc, so an omitted envelope is implicitly cleared.)
        do {
            if let signalEnvelope = try await MobileCloudVaultSignalPayloads.signalEnvelopeIfEnabled(
                domainID: "conversations_chat",
                uid: uid,
                firestore: db,
                collection: "mobile_assistant_chats",
                docId: thread.id,
                plaintext: payloadData,
                resolvedKey: resolvedKey
            ) {
                payload["signalEnvelope"] = signalEnvelope
            }
        } catch {
            logger.error("Signal at-rest seal failed; writing legacy-only: \(String(describing: error), privacy: .public)")
        }
        try await Self.collection(for: db, uid: uid).document(thread.id).setData(payload, merge: false)
    }

    static func encodeThreadForCloud(_ thread: MobileChatThread, vaultKey: Data, vaultKeyID: String) throws -> [String: Any] {
        let cloudThread = threadForCloud(thread)
        let payloadData = try cloudPayloadEncoder.encode(cloudThread)
        let sealedPayload = try CloudVaultCrypto.sealPayload(payloadData, keyData: vaultKey, vaultKeyID: vaultKeyID)
        return [
            "id": thread.id,
            "runtime": thread.runtime,
            "createdAt": Timestamp(date: thread.createdAt),
            "updatedAt": Timestamp(date: thread.updatedAt),
            "messageCount": thread.messageCount,
            "contentSealed": true,
            "sealedSchemaVersion": 2,
            "vaultKeyID": vaultKeyID,
            "sealedPayload": CloudVaultCrypto.sealedPayloadDictionary(sealedPayload)
        ]
    }

    private static func threadForCloud(_ thread: MobileChatThread) -> MobileChatThread {
        var copy = thread
        copy.messages = copy.messages.map { message in
            var next = message
            next.attachments = next.attachments.map { attachment in
                var stripped = attachment
                stripped.thumbnailPNG = nil
                return stripped
            }
            return next
        }
        return copy
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
        if !message.toolCalls.isEmpty {
            payload["toolCalls"] = message.toolCalls.map(encodeToolCallForCloud)
        }
        if let hermes = message.hermes {
            payload["hermes"] = encodeHermesMetadataForCloud(hermes)
        }
        return payload
    }

    static func encodeToolCallForCloud(_ tc: MobileChatToolCall) -> [String: Any] {
        var entry: [String: Any] = [
            "id": tc.id,
            "name": tc.name,
            "status": tc.status
        ]
        if let detail = tc.detail, !detail.isEmpty {
            entry["detail"] = detail
        }
        return entry
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
            dict["toolCalls"] = metadata.toolCalls.map { tc -> [String: Any] in
                var entry: [String: Any] = [
                    "id": tc.id,
                    "name": tc.name,
                    "status": tc.status
                ]
                if let detail = tc.detail, !detail.isEmpty {
                    entry["detail"] = detail
                }
                return entry
            }
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
        let key = try await MobileCloudVaultKeyAccess.keyForReading(uid: uid, firestore: db)
        // Resolve the PINNED trusted-sender set once so a thread written by ANOTHER trusted
        // device verifies its sender signature cross-device (else only self-authored threads
        // verify and peer threads fall back to legacy).
        var trustedSenders: [String: Data] = [:]
        if let identity = key?.signalIdentity {
            trustedSenders = await MobileCloudVaultSignalPayloads.trustedSenderPublicKeys(
                uid: uid, firestore: db, localIdentity: identity
            )
        }

        return snapshot.documents.compactMap { document in
            Self.decodeThread(
                documentID: document.documentID,
                data: document.data(),
                uid: uid,
                vaultKey: key?.keyData,
                signalIdentity: key?.signalIdentity,
                trustedSenderPublicKeys: trustedSenders
            )
        }
    }

    static func decodeThread(
        documentID: String,
        data: [String: Any],
        uid: String? = nil,
        vaultKey: Data? = nil,
        signalIdentity: OpenBurnBarSignalIdentityKeypair? = nil,
        trustedSenderPublicKeys: [String: Data] = [:]
    ) -> MobileChatThread? {
        if data["signalEnvelope"] != nil, let uid {
            do {
                if let payload = try MobileCloudVaultSignalPayloads.openSignalPayloadIfPresent(
                    data,
                    uid: uid,
                    collection: "mobile_assistant_chats",
                    docId: documentID,
                    signalIdentity: signalIdentity,
                    trustedSenderPublicKeys: trustedSenderPublicKeys
                ) {
                    return try cloudPayloadDecoder.decode(MobileChatThread.self, from: payload)
                }
            } catch let signalError as OpenBurnBarSignalCoreError
                where !signalError.allowsLegacyAtRestFallback(senderSetComplete: false) {
                // C1: a stripped / forged sender-auth block (or relocated AAD
                // binding) is a downgrade attack — fail CLOSED. Never decode the
                // sender-unauthenticated legacy payload for this document.
                // senderSetComplete:false keeps an unknown sender rollout-lenient
                // (legacy needs the E2EE vault key an attacker lacks), while the
                // hard sender-auth failures fail closed regardless.
                return nil
            } catch MobileCloudVaultSignalPayloadError.signalBindingMismatch {
                // Relocated / replayed envelope: its self-described binding does
                // not match this document's coordinates — fail CLOSED.
                return nil
            } catch {
                // Rollout compatibility: direct client writes carry legacy AES-GCM
                // `sealedPayload` alongside the optional Signal envelope until
                // Phase-E activation. If Signal open is unavailable or malformed,
                // fall through to the legacy opener instead of dropping the thread.
            }
        }
        if data["contentSealed"] as? Bool == true || data["sealedPayload"] != nil {
            guard let vaultKey,
                  let envelope = CloudVaultCrypto.sealedPayload(from: data["sealedPayload"]) else {
                return nil
            }
            do {
                let payload = try CloudVaultCrypto.openPayload(envelope, keyData: vaultKey)
                return try cloudPayloadDecoder.decode(MobileChatThread.self, from: payload)
            } catch {
                return nil
            }
        }
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

        let customTitle = data["customTitle"] as? String
        let labelColorHex = data["labelColorHex"] as? String
        let isPinned = data["isPinned"] as? Bool
        let priorityOrder = data["priorityOrder"] as? Int

        return MobileChatThread(
            id: id,
            runtime: runtime,
            title: title,
            preview: preview,
            modelName: modelName,
            createdAt: createdAt,
            updatedAt: updatedAt,
            messages: messages,
            customTitle: customTitle,
            labelColorHex: labelColorHex,
            isPinned: isPinned,
            priorityOrder: priorityOrder
        )
    }

    private static var cloudPayloadEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var cloudPayloadDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
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
        let topLevelToolCalls = decodeToolCalls(raw["toolCalls"] as? [[String: Any]])
        let hermes = (raw["hermes"] as? [String: Any]).flatMap(decodeHermesMetadata)
        // Prefer the top-level toolCalls list; fall back to hermes.toolCalls
        // for threads written by older builds that only knew about the Hermes
        // metadata block.
        let mergedToolCalls = !topLevelToolCalls.isEmpty
            ? topLevelToolCalls
            : (hermes?.toolCalls ?? [])
        return MobileChatMessage(
            id: id,
            role: role,
            text: text,
            timestamp: timestamp,
            modelName: modelName,
            isError: isError,
            attachments: attachments,
            toolCalls: mergedToolCalls,
            hermes: hermes
        )
    }

    private static func decodeToolCalls(_ raw: [[String: Any]]?) -> [MobileChatToolCall] {
        (raw ?? []).compactMap { dict -> MobileChatToolCall? in
            guard let id = dict["id"] as? String,
                  let name = dict["name"] as? String,
                  let status = dict["status"] as? String else { return nil }
            return MobileChatToolCall(
                id: id,
                name: name,
                status: status,
                detail: dict["detail"] as? String
            )
        }
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
            return MobileChatToolCall(
                id: id,
                name: name,
                status: status,
                detail: dict["detail"] as? String
            )
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
/// truth for the conversation lists in `PiConversationListView`,
/// `HermesConversationListView`, and the native mobile CLI chat surface.
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

    func updateThreadMetadata(
        id: String,
        customTitle: String? = nil,
        labelColorHex: String? = nil,
        isPinned: Bool? = nil,
        priorityOrder: Int? = nil
    ) {
        guard var thread = thread(id: id) else { return }
        if customTitle != nil {
            thread.customTitle = customTitle
        }
        if let color = labelColorHex {
            thread.labelColorHex = color == "#NONE#" ? nil : color
        }
        if let pin = isPinned {
            thread.isPinned = pin
        }
        if let prio = priorityOrder {
            thread.priorityOrder = prio
        }
        upsert(thread)
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

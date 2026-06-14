import Foundation
import OpenBurnBarCore

/// Default device commit-queue directory the daemon writes prepared Pensieve
/// batches into. Byte-compatible with `defaultCommitQueue` in
/// `tools/openburnbar-mcp-remote/src/memoryHook.ts` (`~/.openburnbar/pensieve-queue`),
/// so the Mac app's `KnowledgeSyncService` and the published shim drain the same
/// sink. The daemon never authenticates to Firebase itself — it produces sealed
/// + cloaked, ready-to-commit batches; the signed-in app does the
/// `commitKnowledgeBatch` call. Plaintext never leaves the device, even within
/// the queue (chunk text + metadata are sealed before they are written).
extension BurnBarDaemonPaths {
    public static var defaultPensieveQueueDirectoryURL: URL {
        if let override = ProcessInfo.processInfo.environment["OPENBURNBAR_PENSIEVE_QUEUE_DIR"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".openburnbar/pensieve-queue", isDirectory: true)
    }

    /// `~/.claude/projects` — Claude Code's session JSONL tree. A `*.jsonl` close
    /// there is a session-end signal Pensieve reacts to.
    public static var defaultClaudeProjectsDirectoryURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }
}

/// One source root the watcher observes. `repo_docs` / `notes` folders are
/// chunked + sealed directly; `chat_memory` (Claude session JSONL) is detected
/// by a settled `.jsonl` write but extraction is deferred to the app (which can
/// spawn the user's model), matching the BYO-inference design.
public struct PensieveWatchRoot: Sendable {
    public let url: URL
    public let sourceKind: PensieveSourceKind
    /// File extensions ingested directly (lowercased, no dot). Empty = all.
    public let includedExtensions: Set<String>

    public init(url: URL, sourceKind: PensieveSourceKind, includedExtensions: Set<String> = []) {
        self.url = url
        self.sourceKind = sourceKind
        self.includedExtensions = includedExtensions
    }
}

/// Serializes the daemon's prepare/enqueue work so a folder-change burst can't
/// run two ingests at once. Mirrors the lightweight process gates in the
/// CloudSync services.
private final class PensieveWatcherGate: Sendable {
    private let running = Locked(false)
    func tryEnter() -> Bool {
        running.withLock { running in
            guard !running else { return false }
            running = true
            return true
        }
    }
    func leave() { running.write(false) }
}

/// FSEvents-style folder watcher for Pensieve. Debounces directory-change events
/// from a `DispatchSource` file-system object source (the same primitive the
/// rest of the daemon uses for liveness signals), then prepares a sealed +
/// cloaked `commitKnowledgeBatch` payload via the shared `PensieveKnowledgeChunker`
/// and drops it into the device commit queue.
///
/// Reuses `BurnBarDaemonHeartbeat` cadence as the periodic backstop so a missed
/// FS event still gets reconciled (the daemon already runs that heartbeat loop;
/// this watcher piggybacks on the same support directory + atomic-write pattern).
///
/// AUDIT(@unchecked Sendable): lifecycle state (dispatch sources, descriptors,
/// debounce/backstop work items, enqueued-ID set) is mutated only on the private
/// serial `workQueue`. TODO(sendable-zero): box this plus the public status vars in
/// `Locked<State>` (every field is Sendable) to make the type plainly Sendable and
/// close the off-queue read race on `lastEnqueueDate`/`lastEnqueuedCount`/`lastError`.
public final class PensieveKnowledgeWatcher: @unchecked Sendable {
    private let roots: [PensieveWatchRoot]
    private let queueDirectoryURL: URL
    private let vaultKeyProvider: @Sendable () -> Data?
    private let debounceInterval: TimeInterval
    private let backstopInterval: TimeInterval
    private let fileSystem: any SendableFileSystem

    private let gate = PensieveWatcherGate()
    private let workQueue = DispatchQueue(label: "com.openburnbar.daemon.pensieve.watch", qos: .utility)
    private var sources: [DispatchSourceFileSystemObject] = []
    private var descriptors: [Int32] = []
    private var debounceWorkItem: DispatchWorkItem?
    private var backstopTimer: DispatchSourceTimer?
    /// vectorId set already enqueued this process run — avoids re-writing
    /// unchanged chunks (the server is idempotent too, but this trims IO).
    private var enqueuedVectorIDs = Set<String>()

    public private(set) var lastEnqueueDate: Date?
    public private(set) var lastEnqueuedCount = 0
    public private(set) var lastError: String?

    public init(
        roots: [PensieveWatchRoot],
        queueDirectoryURL: URL = BurnBarDaemonPaths.defaultPensieveQueueDirectoryURL,
        vaultKeyProvider: @escaping @Sendable () -> Data?,
        debounceInterval: TimeInterval = 2.0,
        backstopInterval: TimeInterval = 15 * 60,
        fileSystem: any SendableFileSystem = DefaultSendableFileSystem()
    ) {
        self.roots = roots
        self.queueDirectoryURL = queueDirectoryURL
        self.vaultKeyProvider = vaultKeyProvider
        self.debounceInterval = debounceInterval
        self.backstopInterval = backstopInterval
        self.fileSystem = fileSystem
    }

    /// Convenience: watch the standard repo-docs / notes / Claude-session roots.
    public static func standardRoots(
        repoDocsURL: URL? = nil,
        notesURL: URL? = nil,
        claudeProjectsURL: URL = BurnBarDaemonPaths.defaultClaudeProjectsDirectoryURL
    ) -> [PensieveWatchRoot] {
        var roots: [PensieveWatchRoot] = []
        if let repoDocsURL {
            roots.append(PensieveWatchRoot(url: repoDocsURL, sourceKind: .repoDocs, includedExtensions: ["md", "mdx", "txt", "rst"]))
        }
        if let notesURL {
            roots.append(PensieveWatchRoot(url: notesURL, sourceKind: .notes, includedExtensions: ["md", "txt"]))
        }
        roots.append(PensieveWatchRoot(url: claudeProjectsURL, sourceKind: .chatMemory, includedExtensions: ["jsonl"]))
        return roots
    }

    // MARK: - Lifecycle

    public func start() {
        workQueue.async { [weak self] in
            self?.installSources()
            self?.installBackstop()
            // Initial reconciliation pass on launch.
            self?.scheduleScan()
        }
    }

    public func stop() {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.debounceWorkItem?.cancel()
            self.backstopTimer?.cancel()
            self.backstopTimer = nil
            for source in self.sources { source.cancel() }
            self.sources.removeAll()
            for fd in self.descriptors where fd >= 0 { close(fd) }
            self.descriptors.removeAll()
        }
    }

    deinit { stop() }

    // MARK: - FS sources

    private func installSources() {
        for root in roots {
            try? fileSystem.createDirectory(at: root.url, withIntermediateDirectories: true)
            let fd = open(root.url.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .rename, .delete],
                queue: workQueue
            )
            source.setEventHandler { [weak self] in self?.scheduleScan() }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
            descriptors.append(fd)
        }
    }

    private func installBackstop() {
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + backstopInterval, repeating: backstopInterval)
        timer.setEventHandler { [weak self] in self?.scheduleScan() }
        timer.resume()
        backstopTimer = timer
    }

    /// Debounce a burst of FS events into one scan.
    private func scheduleScan() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runScan() }
        debounceWorkItem = work
        workQueue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    // MARK: - Scan + prepare

    private func runScan() {
        guard gate.tryEnter() else { return }
        defer { gate.leave() }
        guard let vaultKey = vaultKeyProvider(), vaultKey.count == 32 else {
            lastError = "Pensieve vault key unavailable; deferring knowledge ingest."
            return
        }

        var enqueued = 0
        for root in roots {
            // chat_memory (Claude JSONL) is a session-end SIGNAL only — the daemon
            // touches a sentinel so the app's BYO-inference extractor runs; it does
            // NOT chunk raw transcripts here (extraction needs the user's model).
            if root.sourceKind == .chatMemory {
                enqueued += signalSessionEnds(in: root)
                continue
            }
            enqueued += prepareDocuments(in: root, vaultKey: vaultKey)
        }

        if enqueued > 0 {
            lastEnqueuedCount = enqueued
            lastEnqueueDate = Date()
            lastError = nil
        }
    }

    /// Chunk + seal + cloak each eligible document under a docs/notes root and
    /// write one batch file per source into the queue.
    private func prepareDocuments(in root: PensieveWatchRoot, vaultKey: Data) -> Int {
        guard let files = eligibleFiles(in: root) else { return 0 }
        var enqueued = 0
        for fileURL in files {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let sourcePath = relativePath(of: fileURL, under: root.url)
            let slug = KnowledgeSyncSlug.slugify(sourcePath)
            guard let batch = try? PensieveKnowledgeChunker.prepareBatch(
                text: text,
                sourceKind: root.sourceKind,
                sourcePath: sourcePath,
                sourceSlug: slug,
                vaultKey: vaultKey,
                title: fileURL.deletingPathExtension().lastPathComponent
            ) else { continue }

            // Skip if every chunk in this file was already enqueued this run.
            let novelVectors = batch.vectors.filter { !enqueuedVectorIDs.contains($0.vectorId) }
            guard !novelVectors.isEmpty else { continue }
            for vector in novelVectors { enqueuedVectorIDs.insert(vector.vectorId) }

            let trimmedBatch = PensieveKnowledgeBatch(
                sourceSlug: batch.sourceSlug,
                slugHmac: batch.slugHmac,
                embeddingModelVersion: batch.embeddingModelVersion,
                vectors: novelVectors
            )
            if writeBatch(trimmedBatch) { enqueued += novelVectors.count }
        }
        return enqueued
    }

    /// Write a per-session sentinel for each newly-settled Claude JSONL so the
    /// app's BYO-inference memory hook picks it up. The sentinel records the
    /// session path + last-modified mtime; the app dedupes on it.
    private func signalSessionEnds(in root: PensieveWatchRoot) -> Int {
        guard let files = eligibleFiles(in: root) else { return 0 }
        let sentinelDir = queueDirectoryURL.appendingPathComponent("session-end-signals", isDirectory: true)
        try? fileSystem.createDirectory(at: sentinelDir, withIntermediateDirectories: true)
        var signalled = 0
        for fileURL in files {
            guard let attrs = try? fileSystem.attributesOfItem(atPath: fileURL.path),
                  let modified = attrs[.modificationDate] as? Date else { continue }
            // Only consider sessions that have settled (no write in the last
            // debounce window) — a still-active session keeps getting touched.
            guard Date().timeIntervalSince(modified) >= debounceInterval else { continue }
            let key = PensieveKnowledgeChunker.sha256Hex(fileURL.path + "@" + ISO8601DateFormatter().string(from: modified))
            let sentinelURL = sentinelDir.appendingPathComponent("\(key).json", isDirectory: false)
            guard !fileSystem.fileExists(atPath: sentinelURL.path) else { continue }
            let payload: [String: Any] = [
                "sessionPath": fileURL.path,
                "modifiedAt": ISO8601DateFormatter().string(from: modified),
                "sourceKind": PensieveSourceKind.chatMemory.rawValue,
                "schemaVersion": 1
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
                try? data.write(to: sentinelURL, options: .atomic)
                try? fileSystem.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sentinelURL.path)
                signalled += 1
            }
        }
        return signalled
    }

    /// Atomically write one prepared batch into the commit queue with 0600 perms,
    /// matching the TS `defaultCommitQueue` filename scheme.
    private func writeBatch(_ batch: PensieveKnowledgeBatch) -> Bool {
        try? fileSystem.createDirectory(at: queueDirectoryURL, withIntermediateDirectories: true)
        let idsHash = PensieveKnowledgeChunker.sha256Hex(batch.vectors.map(\.vectorId).joined(separator: ","))
        let fileURL = queueDirectoryURL.appendingPathComponent("\(batch.sourceSlug)-\(idsHash).json", isDirectory: false)
        guard let data = try? JSONSerialization.data(
            withJSONObject: encode(batch),
            options: [.prettyPrinted, .sortedKeys]
        ) else { return false }
        do {
            try data.write(to: fileURL, options: .atomic)
            try? fileSystem.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - File enumeration

    private func eligibleFiles(in root: PensieveWatchRoot) -> [URL]? {
        guard let enumerator = fileSystem.enumerator(
            at: root.url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        var out: [URL] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            if !root.includedExtensions.isEmpty {
                guard root.includedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            }
            out.append(url)
        }
        return out
    }

    private func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        if filePath.hasPrefix(rootPath) {
            let suffix = String(filePath.dropFirst(rootPath.count))
            return suffix.hasPrefix("/") ? String(suffix.dropFirst()) : suffix
        }
        return url.lastPathComponent
    }

    // MARK: - Encoding (commitKnowledgeBatch payload shape)

    private func encode(_ batch: PensieveKnowledgeBatch) -> [String: Any] {
        [
            "sourceSlug": batch.sourceSlug,
            "slugHmac": batch.slugHmac,
            "embeddingModelVersion": batch.embeddingModelVersion,
            "vectors": batch.vectors.map(encode(_:))
        ]
    }

    private func encode(_ vector: PensieveKnowledgeVector) -> [String: Any] {
        [
            "vectorId": vector.vectorId,
            "cloakedVector": vector.cloakedVector,
            "sealedCiphertext": encode(vector.sealedCiphertext),
            "sealedMetadata": encode(vector.sealedMetadata),
            "dedupHash": vector.dedupHash,
            "sourceKind": vector.sourceKind.rawValue,
            "chunkIndex": vector.chunkIndex,
            "byteCount": vector.byteCount
        ]
    }

    private func encode(_ sealed: CloudVaultSealedText) -> [String: Any] {
        // cov:ignore-start -- daemon watcher currently seals uid-less schema-v1 batches; schema-v2 aad preservation is defensive parity with the app writer until daemon uid-bound sealing lands.
        var dict: [String: Any] = [
            "algorithm": sealed.algorithm,
            "keyVersion": sealed.keyVersion,
            "nonce": sealed.nonce,
            "ciphertext": sealed.ciphertext,
            "tag": sealed.tag
        ]
        // Kept in lockstep with KnowledgeSyncService.encode (app target): preserve the
        // path-bound (schemaVersion-2) fields so the writer/reader round-trip is lossless.
        // The daemon watcher seals uid-less (legacy schemaVersion-1), so these are nil here
        // today; carrying them prevents silent drift if the daemon ever gains a uid path.
        if let schemaVersion = sealed.schemaVersion {
            dict["schemaVersion"] = schemaVersion
        }
        if let aad = sealed.aad {
            dict["aad"] = aad
        }
        return dict
        // cov:ignore-end
    }
}

/// Server-compatible slug (matches `slugify` in knowledgeMemory.ts). Kept local
/// to the daemon target since `KnowledgeSyncService` lives in the app target.
enum KnowledgeSyncSlug {
    static func slugify(_ raw: String) -> String {
        let collapsed = raw.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        var slug = String(collapsed)
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let result = String(slug.prefix(120))
        return result.isEmpty ? PensieveKnowledgeChunker.sha256Hex(raw).prefix(16).description : result
    }
}

#if os(Linux)
import Foundation
import Glibc
import OpenBurnBarCore

/// Linux-local source kinds (Core Pensieve chunker/seal path is excluded on Linux).
public enum PensieveSourceKind: String, Codable, Sendable {
    case repoDocs = "repo_docs"
    case notes
    case chatMemory = "chat_memory"
}

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

    public static var defaultClaudeProjectsDirectoryURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }
}

public struct PensieveWatchRoot: Sendable {
    public let url: URL
    public let sourceKind: PensieveSourceKind
    public let includedExtensions: Set<String>

    public init(url: URL, sourceKind: PensieveSourceKind, includedExtensions: Set<String> = []) {
        self.url = url
        self.sourceKind = sourceKind
        self.includedExtensions = includedExtensions
    }
}

/// Linux Pensieve watcher: inotify + debounced change manifests + Claude session-end signals.
public final class PensieveKnowledgeWatcher: Sendable {
    private let roots: [PensieveWatchRoot]
    private let queueDirectoryURL: URL
    private let vaultKeyProvider: @Sendable () -> Data?
    private let debounceInterval: TimeInterval
    private let backstopInterval: TimeInterval
    private let fileSystem: any SendableFileSystem
    private let workQueue = DispatchQueue(label: "com.openburnbar.daemon.pensieve.watch.linux", qos: .utility)

    // sendable-allowlist: serial-queue-confined-watcher
    private final class MutableState: @unchecked Sendable {
        var inotifyFD: Int32 = -1
        var readSource: DispatchSourceRead?
        var watchDescriptorsByPath: [String: Int32] = [:]
        var debounceWorkItem: DispatchWorkItem?
        var backstopTimer: DispatchSourceTimer?
        var lastEnqueueDate: Date?
        var lastEnqueuedCount = 0
        var lastError: String?
        var started = false
        var scanning = false
    }

    private let mutable = MutableState()

    private static let eventBufferSize = 64 * 1_024
    private static let watchMask = UInt32(
        IN_ATTRIB | IN_CLOSE_WRITE | IN_CREATE | IN_DELETE | IN_DELETE_SELF
            | IN_MODIFY | IN_MOVE_SELF | IN_MOVED_FROM | IN_MOVED_TO
    )

    public var lastEnqueueDate: Date? { workQueue.sync { mutable.lastEnqueueDate } }
    public var lastEnqueuedCount: Int { workQueue.sync { mutable.lastEnqueuedCount } }
    public var lastError: String? { workQueue.sync { mutable.lastError } }

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

    public func start() {
        workQueue.async { [weak self] in
            guard let self, !self.mutable.started else { return }
            self.mutable.started = true
            self.installInotify()
            self.installBackstop()
            self.scheduleScan()
        }
    }

    public func stop() {
        workQueue.async { [weak self] in
            guard let self else { return }
            guard self.mutable.started else { return }
            self.mutable.started = false
            self.mutable.debounceWorkItem?.cancel()
            self.mutable.debounceWorkItem = nil
            self.mutable.backstopTimer?.cancel()
            self.mutable.backstopTimer = nil
            let readSource = self.mutable.readSource
            let fileDescriptor = self.mutable.inotifyFD
            self.mutable.readSource = nil
            self.mutable.inotifyFD = -1
            if let readSource {
                readSource.cancel()
            } else if fileDescriptor >= 0 {
                close(fileDescriptor)
            }
            self.mutable.watchDescriptorsByPath.removeAll()
        }
    }

    deinit {
        mutable.debounceWorkItem?.cancel()
        mutable.backstopTimer?.cancel()
        if let readSource = mutable.readSource {
            mutable.inotifyFD = -1
            readSource.cancel()
        } else if mutable.inotifyFD >= 0 {
            close(mutable.inotifyFD)
            mutable.inotifyFD = -1
        }
    }

    private func installInotify() {
        let fd = inotify_init1(Int32(IN_NONBLOCK | IN_CLOEXEC))
        guard fd >= 0 else {
            mutable.lastError = "inotify_init1 failed: \(String(cString: strerror(errno)))"
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: workQueue)
        source.setEventHandler { [weak self] in self?.drainInotify() }
        source.setCancelHandler { close(fd) }
        source.resume()
        mutable.inotifyFD = fd
        mutable.readSource = source

        for root in roots {
            try? fileSystem.createDirectory(at: root.url, withIntermediateDirectories: true)
            addWatchTree(root.url)
        }
        if mutable.watchDescriptorsByPath.isEmpty {
            mutable.lastError = "Pensieve inotify installed no watches (missing roots?)."
        }
    }

    private func addWatchTree(_ root: URL) {
        let fd = mutable.inotifyFD
        guard fd >= 0 else { return }
        var stack = [root]
        while let dir = stack.popLast() {
            let path = dir.path
            let wd = inotify_add_watch(fd, path, Self.watchMask)
            if wd >= 0 {
                mutable.watchDescriptorsByPath[path] = wd
            }
            guard let kids = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for child in kids {
                if (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    stack.append(child)
                }
            }
        }
    }

    private func drainInotify() {
        let fd = mutable.inotifyFD
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: Self.eventBufferSize)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            scheduleScan()
            for root in roots { addWatchTree(root.url) }
        }
    }

    private func installBackstop() {
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + backstopInterval, repeating: backstopInterval)
        timer.setEventHandler { [weak self] in self?.scheduleScan() }
        timer.resume()
        mutable.backstopTimer = timer
    }

    private func scheduleScan() {
        let work = DispatchWorkItem { [weak self] in self?.runScan() }
        mutable.debounceWorkItem?.cancel()
        mutable.debounceWorkItem = work
        workQueue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func runScan() {
        guard mutable.started, !mutable.scanning else { return }
        mutable.scanning = true
        defer { mutable.scanning = false }

        var enqueued = 0
        for root in roots {
            if root.sourceKind == .chatMemory {
                enqueued += signalSessionEnds(in: root)
            } else {
                enqueued += writeChangeManifest(for: root)
            }
        }
        let hasVault = (vaultKeyProvider()?.count == 32)
        if enqueued > 0 {
            mutable.lastEnqueuedCount = enqueued
            mutable.lastEnqueueDate = Date()
        }
        if !hasVault {
            mutable.lastError =
                "Pensieve vault key unavailable; wrote change manifests / session signals only (Linux Core excludes sealed batch prep)."
        } else if enqueued > 0 {
            mutable.lastError = nil
        }
    }

    private func writeChangeManifest(for root: PensieveWatchRoot) -> Int {
        guard let files = eligibleFiles(in: root), !files.isEmpty else { return 0 }
        let dir = queueDirectoryURL.appendingPathComponent("change-manifests", isDirectory: true)
        try? fileSystem.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let name = "\(root.sourceKind.rawValue)-\(stamp.replacingOccurrences(of: ":", with: "-")).json"
        let url = dir.appendingPathComponent(name, isDirectory: false)
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "sourceKind": root.sourceKind.rawValue,
            "rootPath": root.url.path,
            "generatedAt": stamp,
            "files": files.prefix(500).map(\.path),
            "fileCount": files.count,
            "sealRequired": true
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return 0
        }
        do {
            try data.write(to: url, options: Data.WritingOptions.atomic)
            try? fileSystem.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return 1
        } catch {
            mutable.lastError = error.localizedDescription
            return 0
        }
    }

    private func signalSessionEnds(in root: PensieveWatchRoot) -> Int {
        guard let files = eligibleFiles(in: root) else { return 0 }
        let sentinelDir = queueDirectoryURL.appendingPathComponent("session-end-signals", isDirectory: true)
        try? fileSystem.createDirectory(at: sentinelDir, withIntermediateDirectories: true)
        var signalled = 0
        let formatter = ISO8601DateFormatter()
        for fileURL in files {
            guard let attrs = try? fileSystem.attributesOfItem(atPath: fileURL.path),
                  let modified = attrs[.modificationDate] as? Date else { continue }
            guard Date().timeIntervalSince(modified) >= debounceInterval else { continue }
            let keyMaterial = fileURL.path + "@" + formatter.string(from: modified)
            let key = djb2Hex(keyMaterial)
            let sentinelURL = sentinelDir.appendingPathComponent("\(key).json", isDirectory: false)
            guard !fileSystem.fileExists(atPath: sentinelURL.path) else { continue }
            let payload: [String: Any] = [
                "sessionPath": fileURL.path,
                "modifiedAt": formatter.string(from: modified),
                "sourceKind": PensieveSourceKind.chatMemory.rawValue,
                "schemaVersion": 1
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
                try? data.write(to: sentinelURL, options: Data.WritingOptions.atomic)
                try? fileSystem.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sentinelURL.path)
                signalled += 1
            }
        }
        return signalled
    }

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

    private func djb2Hex(_ string: String) -> String {
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(format: "%016llx", hash)
    }
}
#endif

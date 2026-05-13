import Darwin
import Foundation

// MARK: - Constants

enum ICloudSessionMirrorConstants {
    static let containerIdentifier = "iCloud.com.openburnbar.app"
    static let mirrorPathComponents = ["Documents", "OpenBurnBar", "SessionMirror"]
}

// MARK: - Mirror state (persisted)

struct ICloudSessionMirrorStateFile: Codable, Sendable {
    var files: [String: ICloudSessionMirrorFileRecord]
}

struct ICloudSessionMirrorFileRecord: Codable, Sendable, Equatable {
    var modificationTime: TimeInterval
    var size: Int64
}

// MARK: - Snapshot (captured on MainActor, processed off-thread)

struct ICloudSessionMirrorSnapshot: Sendable {
    let containerIdentifier: String
    let mirrorPathComponents: [String]
    let providers: [ICloudSessionProviderSpec]
    let stateFilePath: String
    let containerBaseURL: URL?
}

struct ICloudSessionProviderSpec: Sendable {
    let slug: String
    let rootPath: String
    let filePattern: String
}

struct ICloudSessionMirrorSyncResult: Sendable {
    let lastSyncDate: Date?
    let errorMessage: String?
    let updatedCount: Int
    let removedCount: Int
}

// MARK: - Engine (background)

enum ICloudSessionMirrorEngine {

    static func estimateBytes(_ snapshot: ICloudSessionMirrorSnapshot) async -> Int64 {
        let fm = FileManager()
        var total: Int64 = 0
        for spec in snapshot.providers {
            guard let sources = try? sourceFiles(for: spec, fm: fm) else { continue }
            for url in sources {
                total += (try? fm.fileSize(at: url)) ?? 0
            }
            await Task.yield()
        }
        return total
    }

    static func perform(_ snapshot: ICloudSessionMirrorSnapshot) async -> ICloudSessionMirrorSyncResult {
        let fm = FileManager()

        guard let base =
            snapshot.containerBaseURL
            ?? fm.url(forUbiquityContainerIdentifier: snapshot.containerIdentifier)
            ?? fallbackContainerURL(for: snapshot.containerIdentifier, fm: fm) else {
            return ICloudSessionMirrorSyncResult(
                lastSyncDate: nil,
                errorMessage: "iCloud Drive is not available. Sign in to iCloud and enable iCloud Drive in System Settings.",
                updatedCount: 0,
                removedCount: 0
            )
        }

        let mirrorRoot = snapshot.mirrorPathComponents.reduce(base) { $0.appendingPathComponent($1, isDirectory: true) }

        do {
            try fm.createDirectory(at: mirrorRoot, withIntermediateDirectories: true)
        } catch {
            return ICloudSessionMirrorSyncResult(
                lastSyncDate: nil,
                errorMessage: userFacingMirrorError(error),
                updatedCount: 0,
                removedCount: 0
            )
        }

        var state = loadState(path: snapshot.stateFilePath, fm: fm)
        let previousSnapshot = state.files
        var newRecords: [String: ICloudSessionMirrorFileRecord] = [:]
        var updatedCount = 0
        var fileIndex = 0

        do {
            for spec in snapshot.providers {
                let root = URL(fileURLWithPath: spec.rootPath, isDirectory: true).standardizedFileURL
                let sources = try sourceFiles(for: spec, fm: fm)
                let rootStandard = root

                for source in sources {
                    fileIndex += 1
                    if fileIndex % 32 == 0 { await Task.yield() }

                    let sourcePath = source.standardizedFileURL.path
                    let relative = try relativePath(from: rootStandard, to: source.standardizedFileURL)
                    let dest = mirrorRoot
                        .appendingPathComponent(spec.slug, isDirectory: true)
                        .appendingPathComponent(relative, isDirectory: false)

                    let attrs = try source.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    guard let mod = attrs.contentModificationDate else { continue }
                    let size = Int64(attrs.fileSize ?? 0)
                    let prev = state.files[sourcePath]

                    if let prev,
                       prev.modificationTime == mod.timeIntervalSinceReferenceDate,
                       prev.size == size,
                       fm.fileExists(atPath: dest.path) {
                        newRecords[sourcePath] = prev
                        continue
                    }

                    try copyIntoUbiquity(from: source, to: dest, fm: fm)
                    newRecords[sourcePath] = ICloudSessionMirrorFileRecord(
                        modificationTime: mod.timeIntervalSinceReferenceDate,
                        size: size
                    )
                    updatedCount += 1
                }
            }

            state.files = appendSafeMergedRecords(previous: previousSnapshot, incoming: newRecords)
            try saveState(state, path: snapshot.stateFilePath, fm: fm)

            return ICloudSessionMirrorSyncResult(
                lastSyncDate: Date(),
                errorMessage: nil,
                updatedCount: updatedCount,
                removedCount: 0
            )
        } catch {
            return ICloudSessionMirrorSyncResult(
                lastSyncDate: nil,
                errorMessage: userFacingMirrorError(error),
                updatedCount: updatedCount,
                removedCount: 0
            )
        }
    }

    static func appendSafeMergedRecords(
        previous: [String: ICloudSessionMirrorFileRecord],
        incoming: [String: ICloudSessionMirrorFileRecord]
    ) -> [String: ICloudSessionMirrorFileRecord] {
        previous.merging(incoming) { _, incoming in incoming }
    }

    private static func fallbackContainerURL(for identifier: String, fm: FileManager) -> URL? {
        let containerFolder = identifier.replacingOccurrences(of: ".", with: "~")
        let fallback = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mobile Documents", isDirectory: true)
            .appendingPathComponent(containerFolder, isDirectory: true)
        return fm.fileExists(atPath: fallback.path) ? fallback : nil
    }

    // MARK: - Copy (write coordination only — avoids cross-volume read/write coordinator failures)

    private static func copyIntoUbiquity(from source: URL, to dest: URL, fm: FileManager) throws {
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

        var coordinationError: NSError?
        var innerError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: dest, options: .forReplacing, error: &coordinationError) { writeURL in
            do {
                if fm.fileExists(atPath: writeURL.path) {
                    try fm.removeItem(at: writeURL)
                }
                try fm.copyItem(at: source, to: writeURL)
            } catch {
                innerError = error
            }
        }

        if coordinationError != nil || innerError != nil {
            try copyIntoUbiquityFallback(from: source, to: dest, fm: fm)
        }
    }

    /// Plain copy when `NSFileCoordinator` fails or rejects the operation (common when mixing `~` paths with ubiquity).
    private static func copyIntoUbiquityFallback(from source: URL, to dest: URL, fm: FileManager) throws {
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: source, to: dest)
    }

    private static func userFacingMirrorError(_ error: Error) -> String {
        let ns = error as NSError

        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileWriteNoPermissionError:
                return """
                iCloud blocked writing (permission denied). Fix: in Apple Developer, enable iCloud Documents for app id com.openburnbar.app with container iCloud.com.openburnbar.app, then rebuild with that team/provisioning profile. Also confirm you are signed into iCloud Drive on this Mac.
                """
            case NSFileReadNoPermissionError:
                return "Could not read a session file. If logs are outside your home folder, grant Full Disk Access to OpenBurnBar in System Settings → Privacy & Security."
            default:
                break
            }
        }

        if ns.domain == NSPOSIXErrorDomain {
            switch ns.code {
            case Int(EPERM), Int(EACCES):
                return "The system denied file access (POSIX permission). For iCloud: verify Developer iCloud capability and signing. For ~/.local paths: check Full Disk Access."
            default:
                break
            }
        }

        let description = error.localizedDescription
        if description.localizedCaseInsensitiveContains("insufficient permissions")
            || description.localizedCaseInsensitiveContains("permission denied") {
            return """
            \(description)

            Note: “Missing or insufficient permissions” is often a Firestore security-rules error during refresh. If this appeared right after “Mirror now”, it is more likely an iCloud signing/capability issue—see README iCloud section.
            """
        }

        return description
    }

    private static func sourceFiles(for spec: ICloudSessionProviderSpec, fm: FileManager) throws -> [URL] {
        let standardized = URL(fileURLWithPath: spec.rootPath, isDirectory: true).standardizedFileURL
        guard fm.fileExists(atPath: standardized.path) else { return [] }

        if spec.slug == "Hermes" {
            let hermesHome = standardized.lastPathComponent == "sessions"
                ? standardized.deletingLastPathComponent()
                : standardized
            var files: [URL] = []
            let stateDB = hermesHome.appendingPathComponent("state.db")
            if fm.fileExists(atPath: stateDB.path) {
                files.append(stateDB)
                for suffix in ["-wal", "-shm"] {
                    let sidecar = URL(fileURLWithPath: stateDB.path + suffix)
                    if fm.fileExists(atPath: sidecar.path) {
                        files.append(sidecar)
                    }
                }
            }
            let sessionsDir = hermesHome.appendingPathComponent("sessions", isDirectory: true)
            files.append(contentsOf: try enumerateFiles(in: sessionsDir, matchingExtensions: ["json", "jsonl"], fm: fm))
            return files
        }

        switch spec.filePattern {
        case "state_5.sqlite":
            let f = standardized.appendingPathComponent("state_5.sqlite")
            return fm.fileExists(atPath: f.path) ? [f] : []
        default:
            let exts = Set(mirrorExtensions(for: spec.filePattern))
            return try enumerateFiles(in: standardized, matchingExtensions: exts, fm: fm)
        }
    }

    private static func mirrorExtensions(for filePattern: String) -> [String] {
        switch filePattern {
        case "*.jsonl":
            return ["jsonl", "json"]
        case "*.json":
            return ["json"]
        case "*.db":
            return ["db"]
        default:
            return []
        }
    }

    private static func enumerateFiles(in root: URL, matchingExtensions: Set<String>, fm: FileManager) throws -> [URL] {
        var result: [URL] = []
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return result }

        for case let item as URL in enumerator {
            let isFile = (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isFile else { continue }
            let ext = item.pathExtension.lowercased()
            guard matchingExtensions.contains(ext) else { continue }
            result.append(item)
        }
        return result
    }

    private static func relativePath(from root: URL, to file: URL) throws -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else {
            throw ICloudSessionMirrorError.pathOutsideRoot
        }
        var sub = String(filePath.dropFirst(rootPath.count))
        if sub.hasPrefix("/") { sub.removeFirst() }
        if sub.isEmpty { return file.lastPathComponent }
        return sub
    }

    private static func loadState(path: String, fm: FileManager) -> ICloudSessionMirrorStateFile {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(ICloudSessionMirrorStateFile.self, from: data) else {
            return ICloudSessionMirrorStateFile(files: [:])
        }
        return decoded
    }

    private static func saveState(_ state: ICloudSessionMirrorStateFile, path: String, fm: FileManager) throws {
        let url = URL(fileURLWithPath: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - ICloudSessionMirrorService

/// Incrementally copies agent session files from configured provider paths into the app’s iCloud Drive
/// container (`Documents/OpenBurnBar/SessionMirror/...`). Independent of Firebase.
@Observable
@MainActor
final class ICloudSessionMirrorService {

    private(set) var isSyncing = false
    private(set) var lastSyncDate: Date?
    private(set) var lastSyncError: String?
    /// Files copied or updated in the last completed sync.
    private(set) var lastSyncUpdatedCount: Int = 0
    /// Files removed by explicit mirror delete operations. Incremental sync never
    /// treats a missing local source as an implicit delete.
    private(set) var lastSyncRemovedCount: Int = 0

    private let settingsManager: SettingsManager
    private let fileManager: FileManager

    init(settingsManager: SettingsManager = .shared, fileManager: FileManager = .default) {
        self.settingsManager = settingsManager
        self.fileManager = fileManager
    }

    // MARK: - iCloud availability

    /// `true` when this Mac is signed into iCloud (Drive may still be off; container URL can still appear).
    var hasUbiquityIdentity: Bool {
        fileManager.ubiquityIdentityToken != nil
    }

    /// Root folder shown in Finder for mirrored session files, if the container is available.
    func mirrorRootDirectoryURL() -> URL? {
        guard let base = ubiquityContainerURL() else { return nil }
        return ICloudSessionMirrorConstants.mirrorPathComponents.reduce(base) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    func ubiquityContainerURL() -> URL? {
        if let url = fileManager.url(forUbiquityContainerIdentifier: ICloudSessionMirrorConstants.containerIdentifier) {
            return url
        }
        let containerFolder = ICloudSessionMirrorConstants.containerIdentifier.replacingOccurrences(of: ".", with: "~")
        let fallback = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mobile Documents", isDirectory: true)
            .appendingPathComponent(containerFolder, isDirectory: true)
        return fileManager.fileExists(atPath: fallback.path) ? fallback : nil
    }

    // MARK: - Public API

    /// Rough total size of files that would be mirrored (for setup UI). Runs off the main thread.
    func estimatedTotalBytesToMirror() async -> Int64 {
        let snapshot = makeSnapshot()
        await Task.yield()
        return await Task.detached(priority: .utility) {
            await ICloudSessionMirrorEngine.estimateBytes(snapshot)
        }.value
    }

    func syncIfNeeded() async {
        guard settingsManager.iCloudSessionMirrorEnabled else { return }
        guard !isSyncing else { return }

        isSyncing = true
        lastSyncError = nil
        lastSyncUpdatedCount = 0
        lastSyncRemovedCount = 0

        let snapshot = makeSnapshot()

        let result = await Task.detached(priority: .utility) {
            await ICloudSessionMirrorEngine.perform(snapshot)
        }.value

        lastSyncDate = result.lastSyncDate
        lastSyncError = result.errorMessage
        lastSyncUpdatedCount = result.updatedCount
        lastSyncRemovedCount = result.removedCount
        isSyncing = false
    }

    /// Enumerates mirrored log files in the iCloud container and returns lightweight ConversationRecord stubs.
    /// Uses minimal JSONL parsing — no full token extraction. fullText is always empty.
    func fetchConversations() async -> [ConversationRecord] {
        guard let mirrorRoot = mirrorRootDirectoryURL() else { return [] }
        return await Task.detached(priority: .utility) {
            Self.extractConversations(from: mirrorRoot)
        }.value
    }

    func exportHermesConversationsForMobile(_ conversations: [ConversationRecord]) async throws -> Int {
        guard !conversations.isEmpty, let mirrorRoot = mirrorRootDirectoryURL() else { return 0 }
        let exportRoot = mirrorRoot
            .appendingPathComponent("Hermes", isDirectory: true)
            .appendingPathComponent("OpenBurnBarImports", isDirectory: true)
        try fileManager.createDirectory(at: exportRoot, withIntermediateDirectories: true)

        var exported = 0
        for conversation in conversations where conversation.provider == .hermes {
            let safeName = conversation.sessionId
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_")
            let url = exportRoot.appendingPathComponent("\(safeName).json")
            let payload: [String: Any] = [
                "id": conversation.id,
                "session_id": conversation.sessionId,
                "title": conversation.summaryTitle ?? conversation.inferredTaskTitle,
                "project_name": conversation.projectName,
                "updated_at": ISO8601DateFormatter().string(from: conversation.endTime ?? conversation.startTime ?? Date()),
                "messages": [
                    [
                        "role": "transcript",
                        "content": conversation.fullText
                    ]
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: [.atomic])
            exported += 1
        }
        return exported
    }

    // MARK: - iCloud lightweight extractor

    private nonisolated static func extractConversations(from mirrorRoot: URL) -> [ConversationRecord] {
        let fm = FileManager()
        guard let slugDirs = try? fm.contentsOfDirectory(
            at: mirrorRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var latestByCanonicalID: [String: ConversationRecord] = [:]

        for slugDir in slugDirs {
            let isDir = (try? slugDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }

            let slug = slugDir.lastPathComponent
            guard let provider = AgentProvider.allCases.first(where: {
                $0.rawValue.replacingOccurrences(of: "/", with: "-") == slug
            }) else { continue }

            guard let enumerator = fm.enumerator(
                at: slugDir,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                let isFile = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                guard isFile else { continue }
                let ext = fileURL.pathExtension.lowercased()
                guard ext == "jsonl" || ext == "json" else { continue }
                guard !shouldSkipMirroredFile(fileURL, provider: provider) else { continue }
                if let record = lightweightParse(file: fileURL, provider: provider) {
                    let canonicalID = "\(provider.rawValue)|\(record.sessionId)"
                    if let existing = latestByCanonicalID[canonicalID] {
                        let existingDate = existing.endTime ?? existing.startTime ?? existing.indexedAt
                        let incomingDate = record.endTime ?? record.startTime ?? record.indexedAt
                        if incomingDate > existingDate {
                            latestByCanonicalID[canonicalID] = record
                        }
                    } else {
                        latestByCanonicalID[canonicalID] = record
                    }
                }
            }
        }

        let records = Array(latestByCanonicalID.values)
        return records.sorted { ($0.startTime ?? .distantPast) > ($1.startTime ?? .distantPast) }
    }

    private nonisolated static func lightweightParse(file: URL, provider: AgentProvider) -> ConversationRecord? {
        let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey])

        let sessionId = file.deletingPathExtension().lastPathComponent
        let projectName = file.deletingLastPathComponent().lastPathComponent
        let activityTime = attrs?.contentModificationDate

        return ConversationRecord(
            id: ConversationRecord.stableId(provider: provider, sessionId: sessionId),
            provider: provider,
            sessionId: sessionId,
            projectName: projectName,
            startTime: activityTime,
            endTime: activityTime,
            messageCount: 0,
            userWordCount: 0,
            assistantWordCount: 0,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: sessionId,
            lastAssistantMessage: "",
            fullText: "",
            indexedAt: Date(),
            fileModifiedAt: nil,
            summary: nil,
            sourceType: .providerLog
        )
    }

    private nonisolated static func shouldSkipMirroredFile(_ fileURL: URL, provider: AgentProvider) -> Bool {
        let lowerPath = fileURL.path.lowercased()

        if lowerPath.hasSuffix(".settings.json")
            || lowerPath.hasSuffix(".metadata.json")
            || lowerPath.hasSuffix(".meta.json") {
            return true
        }

        // Claude subagent logs are fragments of a parent session and blow up list size.
        if provider == .claudeCode, lowerPath.contains("/subagents/") {
            return true
        }

        return false
    }

    // MARK: - Snapshot

    private func makeSnapshot() -> ICloudSessionMirrorSnapshot {
        let providers: [ICloudSessionProviderSpec] = mirrorEligibleProviders().compactMap { p in
            guard let u = settingsManager.resolvedPath(for: p) else { return nil }
            return ICloudSessionProviderSpec(
                slug: filesystemSlug(p.rawValue),
                rootPath: u.path,
                filePattern: p.filePattern
            )
        }
        return ICloudSessionMirrorSnapshot(
            containerIdentifier: ICloudSessionMirrorConstants.containerIdentifier,
            mirrorPathComponents: ICloudSessionMirrorConstants.mirrorPathComponents,
            providers: providers,
            stateFilePath: stateFileURL.path,
            containerBaseURL: nil
        )
    }

    private func mirrorEligibleProviders() -> [AgentProvider] {
        AgentProvider.allCases.filter { $0.supportLevel != .unsupported }
    }

    private func filesystemSlug(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-")
    }

    private var stateFileURL: URL {
        let base = (try? OpenBurnBarMigration.prepareSupportDirectory(fileManager: fileManager))
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OpenBurnBar", isDirectory: true)
        return base.appendingPathComponent("ICloudSessionMirrorState.json", isDirectory: false)
    }
}

// MARK: - Errors

private enum ICloudSessionMirrorError: Error {
    case pathOutsideRoot
}

// MARK: - FileManager

private extension FileManager {
    func fileSize(at url: URL) throws -> Int64 {
        let v = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(v.fileSize ?? 0)
    }
}

import Foundation
import CryptoKit
import GRDB

// MARK: - Artifact Discovery

protocol ArtifactDiscoverySettingsProviding: AnyObject {
    var artifactDiscoveryEnabled: Bool { get }
    var artifactDiscoveryRegisteredRoots: [String] { get }
    var artifactDiscoveryAdditionalKnownPatterns: [String] { get }
}

enum ArtifactDiscoveryIssueCode: String, Codable, Sendable {
    case noRegisteredRoots = "DISCOVERY_NO_REGISTERED_ROOTS"
    case rootMissing = "DISCOVERY_ROOT_MISSING"
    case rootNotDirectory = "DISCOVERY_ROOT_NOT_DIRECTORY"
    case rootUnreadable = "DISCOVERY_ROOT_UNREADABLE"
    case pathOutsideRegisteredRoot = "DISCOVERY_PATH_OUTSIDE_REGISTERED_ROOT"
    case fileReadFailed = "DISCOVERY_FILE_READ_FAILED"
    case invalidTextEncoding = "DISCOVERY_INVALID_TEXT_ENCODING"
}

struct ArtifactDiscoveryIssue: Equatable, Sendable {
    let code: ArtifactDiscoveryIssueCode
    let message: String
    let path: String?
}

struct ArtifactDiscoveryRunReport: Equatable, Sendable {
    var enabled: Bool
    var scannedRoots: Int
    var discoveredArtifacts: Int
    var insertedArtifacts: Int
    var updatedArtifacts: Int
    var restoredArtifacts: Int
    var unchangedArtifacts: Int
    var deletedArtifacts: Int
    var queuedJobs: Int
    var issues: [ArtifactDiscoveryIssue]

    static let disabled = ArtifactDiscoveryRunReport(
        enabled: false,
        scannedRoots: 0,
        discoveredArtifacts: 0,
        insertedArtifacts: 0,
        updatedArtifacts: 0,
        restoredArtifacts: 0,
        unchangedArtifacts: 0,
        deletedArtifacts: 0,
        queuedJobs: 0,
        issues: []
    )
}

struct ArtifactDiscoveryMatch: Equatable, Sendable {
    let sourceKind: SearchSourceKind
    let provenance: String
}

struct ArtifactDiscoveryRules: Sendable {
    private let additionalPatterns: [String]

    init(additionalPatterns: [String] = []) {
        self.additionalPatterns = additionalPatterns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }
    }

    /// A registered root is always honored. Only descendants are pruned.
    static func skipsDirectory(named name: String) -> Bool {
        if ["node_modules", ".git", ".build", ".derived-data", ".spm-cache-new", "__pycache__"].contains(name) {
            return true
        }
        return name.hasPrefix(".") && ![".factory", ".agents", ".claude", ".cursor"].contains(name)
    }

    func match(relativePath: String) -> ArtifactDiscoveryMatch? {
        let normalized = relativePath
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard normalized.isEmpty == false else { return nil }
        let normalizedUpper = normalized.uppercased()
        let basenameUpper = (normalized as NSString).lastPathComponent.uppercased()

        if Self.skillBasenames.contains(basenameUpper) {
            return ArtifactDiscoveryMatch(sourceKind: .skillDoc, provenance: "basename:\(basenameUpper)")
        }

        if Self.agentBasenames.contains(basenameUpper) {
            return ArtifactDiscoveryMatch(sourceKind: .agentDoc, provenance: "basename:\(basenameUpper)")
        }

        if normalizedUpper.hasPrefix(".FACTORY/DROIDS/"), basenameUpper.hasSuffix(".MD") {
            return ArtifactDiscoveryMatch(sourceKind: .agentDoc, provenance: "path:.factory/droids/*.md")
        }

        for pattern in additionalPatterns where Self.matchesWildcard(value: basenameUpper, pattern: pattern) {
            let sourceKind: SearchSourceKind = pattern.contains("SKILL") ? .skillDoc : .agentDoc
            return ArtifactDiscoveryMatch(sourceKind: sourceKind, provenance: "custom:\(pattern)")
        }

        return nil
    }

    private static func matchesWildcard(value: String, pattern: String) -> Bool {
        if pattern.contains("*") == false {
            return value == pattern
        }
        let escaped = NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*")
        let regex = "^\(escaped)$"
        return value.range(of: regex, options: [.regularExpression]) != nil
    }

    private static let skillBasenames: Set<String> = [
        "SKILL.MD",
        "SKILLS.MD"
    ]

    private static let agentBasenames: Set<String> = [
        "AGENTS.MD",
        "AGENT.MD",
        "CLAUDE.MD",
        "BURNBAR_AGENT_PROMPT_PACK.MD",
        "BURNBAR_AGENT_ASSIGNMENT_MATRIX.MD",
        "BURNBAR_SUBAGENT_PROMPTS.MD",
        "BURNBAR_CURSOR_AGENT_SPEC.MD",
        "BURNBAR_CURSOR_AGENT_ONBOARDING.MD",
        "BURNBAR_FULL_AGENT_EXECUTION_PLAN.MD"
    ]
}

protocol ArtifactDiscoveryDataStoring: Sendable {
    func upsertSourceArtifact(_ artifact: SourceArtifactRecord) async throws -> SourceArtifactWriteDisposition
    func fetchSourceArtifacts(
        includeDeleted: Bool,
        rootPaths: [String]?,
        sourceKinds: [SearchSourceKind]
    ) async throws -> [SourceArtifactRecord]
    func markSourceArtifactDeleted(id: String, deletedAt: Date) async throws -> Bool
    func upsertRetrievalHealth(_ health: RetrievalHealthRecord) async throws
    func fetchRetrievalHealth() async throws -> [RetrievalHealthRecord]
    func enqueueProjectionJob(_ job: ProjectionJobRecord) async throws
}

struct DataStoreArtifactDiscoveryStore: ArtifactDiscoveryDataStoring {
    private let dataStore: DataStore

    init(dataStore: DataStore) {
        self.dataStore = dataStore
    }

    func upsertSourceArtifact(_ artifact: SourceArtifactRecord) async throws -> SourceArtifactWriteDisposition {
        try await dataStore.upsertSourceArtifact(artifact)
    }

    func fetchSourceArtifacts(
        includeDeleted: Bool,
        rootPaths: [String]?,
        sourceKinds: [SearchSourceKind]
    ) async throws -> [SourceArtifactRecord] {
        try await dataStore.fetchSourceArtifacts(
            includeDeleted: includeDeleted,
            rootPaths: rootPaths,
            sourceKinds: sourceKinds
        )
    }

    func markSourceArtifactDeleted(id: String, deletedAt: Date) async throws -> Bool {
        try await dataStore.markSourceArtifactDeleted(id: id, deletedAt: deletedAt)
    }

    func upsertRetrievalHealth(_ health: RetrievalHealthRecord) async throws {
        try await dataStore.upsertRetrievalHealth(health)
    }

    func fetchRetrievalHealth() async throws -> [RetrievalHealthRecord] {
        try await dataStore.fetchRetrievalHealth()
    }

    func enqueueProjectionJob(_ job: ProjectionJobRecord) async throws {
        try await dataStore.enqueueProjectionJob(job)
    }
}

actor ArtifactDiscoveryService {
    private let store: any ArtifactDiscoveryDataStoring
    private let settingsProvider: any ArtifactDiscoverySettingsProviding
    private let fileManager: FileManager
    private let nowProvider: @Sendable () -> Date
    private var scanTask: Task<ArtifactDiscoveryRunReport, Error>?
    private var streams: [String: FileTreeEventStream] = [:]
    private let eventQueue = DispatchQueue(label: "ai.burnbar.artifacts.watch", qos: .utility)
    private var watchedRoots: [String] = []
    private var watchedPatterns: [String] = []
    private var dirtyRevision: UInt64 = 0
    private var scannedRevision: UInt64?
    private var lastSuccessfulScan: Date?
    private var watchingSuspended = false
    private var hasPublishedDisabledHealth = false
    static let reconciliationInterval: TimeInterval = 30 * 60

    deinit {
        for stream in streams.values { stream.stop() }
        scanTask?.cancel()
    }

    init(
        dataStore: DataStore,
        settingsProvider: any ArtifactDiscoverySettingsProviding,
        fileManager: FileManager = .default,
        nowProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = DataStoreArtifactDiscoveryStore(dataStore: dataStore)
        self.settingsProvider = settingsProvider
        self.fileManager = fileManager
        self.nowProvider = nowProvider
    }

    init(
        store: any ArtifactDiscoveryDataStoring,
        settingsProvider: any ArtifactDiscoverySettingsProviding,
        fileManager: FileManager = .default,
        nowProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.settingsProvider = settingsProvider
        self.fileManager = fileManager
        self.nowProvider = nowProvider
    }

    @discardableResult
    func discoverAndIngest(force: Bool = true) async throws -> ArtifactDiscoveryRunReport {
        try Task.checkCancellation()
        if let scanTask { return try await scanTask.value }
        let enabled = settingsProvider.artifactDiscoveryEnabled
        if !enabled, hasPublishedDisabledHealth { return .disabled }
        let roots = enabled ? normalizedRegisteredRoots(settingsProvider.artifactDiscoveryRegisteredRoots) : []
        let patterns = enabled ? settingsProvider.artifactDiscoveryAdditionalKnownPatterns : []
        configureWatchers(roots: roots, patterns: patterns, allowStart: !force)
        if enabled { hasPublishedDisabledHealth = false }
        if !force, watchingSuspended {
            var report = ArtifactDiscoveryRunReport.disabled
            report.enabled = enabled
            return report
        }
        let reconciliationDue = lastSuccessfulScan.map {
            nowProvider().timeIntervalSince($0) >= Self.reconciliationInterval
        } ?? true
        if !force, enabled, !reconciliationDue, scannedRevision == dirtyRevision,
           streams.count == roots.count, !roots.isEmpty {
            var report = ArtifactDiscoveryRunReport.disabled
            report.enabled = true
            return report
        }
        let revision = dirtyRevision
        // An interrupted or failed pass must remain due, even when it was a
        // forced rescan with no event revision change.
        scannedRevision = nil
        let task = Task { try await self.performDiscovery() }
        scanTask = task
        defer { scanTask = nil }
        let report = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        if report.enabled && report.issues.isEmpty {
            scannedRevision = revision
            lastSuccessfulScan = nowProvider()
        } else {
            scannedRevision = nil
            hasPublishedDisabledHealth = !report.enabled
        }
        return report
    }

    func setWatchingSuspended(_ suspended: Bool) {
        watchingSuspended = suspended
        if suspended {
            stopWatching()
            scanTask?.cancel()
        } else {
            // Since-now streams cannot account for changes during sleep.
            dirtyRevision &+= 1
        }
    }

    func stopWatching() {
        for stream in streams.values { stream.stop() }
        streams.removeAll()
    }

    private func configureWatchers(roots: [String], patterns: [String], allowStart: Bool) {
        if roots != watchedRoots || patterns != watchedPatterns {
            stopWatching()
            watchedRoots = roots
            watchedPatterns = patterns
            dirtyRevision &+= 1
        }
        guard allowStart, !watchingSuspended else { return }
        for root in roots where streams[root] == nil {
            let stream = FileTreeEventStream(root: URL(fileURLWithPath: root), queue: eventQueue) { [weak self] paths in
                Task { await self?.recordFileEvents(paths, root: root) }
            }
            if stream.start() {
                streams[root] = stream
                dirtyRevision &+= 1
            }
        }
    }

    func recordFileEvents(_ paths: [String], root: String) {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        if paths.contains(where: { path in
            guard path.hasPrefix(prefix) else { return true } // root replacement or lost-event rescan
            let components = path.dropFirst(prefix.count).split(separator: "/").map(String.init)
            return !components.dropLast().contains(where: ArtifactDiscoveryRules.skipsDirectory)
        }) {
            dirtyRevision &+= 1
        }
    }

    private func performDiscovery() async throws -> ArtifactDiscoveryRunReport {
        guard settingsProvider.artifactDiscoveryEnabled else {
            let report = ArtifactDiscoveryRunReport.disabled
            try await upsertHealth(from: report)
            return report
        }

        var report = ArtifactDiscoveryRunReport(
            enabled: true,
            scannedRoots: 0,
            discoveredArtifacts: 0,
            insertedArtifacts: 0,
            updatedArtifacts: 0,
            restoredArtifacts: 0,
            unchangedArtifacts: 0,
            deletedArtifacts: 0,
            queuedJobs: 0,
            issues: []
        )

        let registeredRoots = normalizedRegisteredRoots(settingsProvider.artifactDiscoveryRegisteredRoots)
        guard registeredRoots.isEmpty == false else {
            report.issues.append(
                ArtifactDiscoveryIssue(
                    code: .noRegisteredRoots,
                    message: "Artifact discovery is enabled but no registered roots were configured.",
                    path: nil
                )
            )
            try await upsertHealth(from: report)
            return report
        }

        let rules = ArtifactDiscoveryRules(additionalPatterns: settingsProvider.artifactDiscoveryAdditionalKnownPatterns)
        var discoveredSourceIDs = Set<String>()
        var successfullyScannedRoots = Set<String>()

        // Fetched once up front so the scan can skip re-reading and re-hashing
        // files whose (mtime, size) signature is unchanged — the same gate the
        // log parsers use. Also reused for the deletion sweep below.
        let existingArtifacts = try await store.fetchSourceArtifacts(
            includeDeleted: false,
            rootPaths: nil,
            sourceKinds: [.skillDoc, .agentDoc]
        )
        let existingByID = Dictionary(uniqueKeysWithValues: existingArtifacts.map { ($0.id, $0) })

        for rootPath in registeredRoots {
            try Task.checkCancellation()
            let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: rootPath, isDirectory: &isDirectory) else {
                report.issues.append(
                    ArtifactDiscoveryIssue(
                        code: .rootMissing,
                        message: "Registered discovery root does not exist.",
                        path: rootPath
                    )
                )
                continue
            }
            guard isDirectory.boolValue else {
                report.issues.append(
                    ArtifactDiscoveryIssue(
                        code: .rootNotDirectory,
                        message: "Registered discovery root is not a directory.",
                        path: rootPath
                    )
                )
                continue
            }
            var enumerationFailed = false
            guard let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsPackageDescendants],
                errorHandler: { url, _ in
                    enumerationFailed = true
                    report.issues.append(ArtifactDiscoveryIssue(
                        code: .rootUnreadable,
                        message: "Part of this folder could not be read. Existing indexed files were preserved.",
                        path: url.path
                    ))
                    return true
                }
            ) else {
                report.issues.append(
                    ArtifactDiscoveryIssue(
                        code: .rootUnreadable,
                        message: "Could not enumerate registered discovery root.",
                        path: rootPath
                    )
                )
                continue
            }

            report.scannedRoots += 1
            while let candidateURL = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                let resourceValues: URLResourceValues
                do {
                    resourceValues = try candidateURL.resourceValues(
                        forKeys: [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
                    )
                } catch {
                    enumerationFailed = true
                    report.issues.append(ArtifactDiscoveryIssue(
                        code: .rootUnreadable,
                        message: "Part of this folder could not be read. Existing indexed files were preserved.",
                        path: candidateURL.path
                    ))
                    continue
                }
                if resourceValues.isDirectory == true {
                    if ArtifactDiscoveryRules.skipsDirectory(named: candidateURL.lastPathComponent) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                let canonicalCandidatePath = canonicalPath(for: candidateURL)
                guard isWithinRoot(candidatePath: canonicalCandidatePath, rootPath: rootPath) else {
                    report.issues.append(
                        ArtifactDiscoveryIssue(
                            code: .pathOutsideRegisteredRoot,
                            message: "Skipped candidate that resolved outside registered root.",
                            path: canonicalCandidatePath
                        )
                    )
                    continue
                }

                guard resourceValues.isRegularFile == true else { continue }

                let relativePath = relativePath(from: canonicalCandidatePath, rootPath: rootPath)
                guard let match = rules.match(relativePath: relativePath) else { continue }

                // Signature gate: identical (mtime, size) means identical
                // content for our purposes — skip the read + SHA-256 entirely.
                let candidateID = stableSourceID(for: canonicalCandidatePath)
                // A present but unreadable/invalid file is not a deletion.
                discoveredSourceIDs.insert(candidateID)
                if let existing = existingByID[candidateID],
                   let storedModifiedAt = existing.fileModifiedAt,
                   let candidateModifiedAt = resourceValues.contentModificationDate,
                   let candidateSize = resourceValues.fileSize,
                   existing.fileSizeBytes == candidateSize,
                   abs(storedModifiedAt.timeIntervalSince(candidateModifiedAt)) < 0.001 {
                    report.discoveredArtifacts += 1
                    report.unchangedArtifacts += 1
                    continue
                }

                let fileData: Data
                do {
                    fileData = try Data(contentsOf: candidateURL)
                } catch {
                    report.issues.append(
                        ArtifactDiscoveryIssue(
                            code: .fileReadFailed,
                            message: "Failed to read discovered artifact file: \(error.localizedDescription)",
                            path: canonicalCandidatePath
                        )
                    )
                    continue
                }

                guard let body = String(data: fileData, encoding: .utf8) else {
                    report.issues.append(
                        ArtifactDiscoveryIssue(
                            code: .invalidTextEncoding,
                            message: "Discovered artifact file is not valid UTF-8 text.",
                            path: canonicalCandidatePath
                        )
                    )
                    continue
                }

                let now = nowProvider()
                let artifact = SourceArtifactRecord(
                    id: stableSourceID(for: canonicalCandidatePath),
                    sourceKind: match.sourceKind,
                    canonicalPath: canonicalCandidatePath,
                    rootPath: rootPath,
                    relativePath: relativePath,
                    provenance: match.provenance,
                    title: inferredTitle(from: body, fallbackPath: canonicalCandidatePath),
                    body: body,
                    contentHash: sha256Hex(fileData),
                    fileSizeBytes: resourceValues.fileSize ?? fileData.count,
                    fileModifiedAt: resourceValues.contentModificationDate,
                    status: .active,
                    discoveredAt: now,
                    deletedAt: nil,
                    createdAt: now,
                    updatedAt: now
                )

                let disposition = try await store.upsertSourceArtifact(artifact)
                report.discoveredArtifacts += 1

                switch disposition {
                case .inserted:
                    report.insertedArtifacts += 1
                    try await enqueueProjectionJob(for: artifact, jobType: .project, sourceVersionID: artifact.contentHash, now: now)
                    report.queuedJobs += 1
                case .updated:
                    report.updatedArtifacts += 1
                    try await enqueueProjectionJob(for: artifact, jobType: .reproject, sourceVersionID: artifact.contentHash, now: now)
                    report.queuedJobs += 1
                case .restored:
                    report.restoredArtifacts += 1
                    try await enqueueProjectionJob(for: artifact, jobType: .reproject, sourceVersionID: artifact.contentHash, now: now)
                    report.queuedJobs += 1
                case .unchanged:
                    report.unchangedArtifacts += 1
                }
            }
            if !enumerationFailed { successfullyScannedRoots.insert(rootPath) }
        }

        try Task.checkCancellation()
        let registeredRootSet = Set(registeredRoots)
        for existing in existingArtifacts {
            try Task.checkCancellation()
            if registeredRootSet.contains(existing.rootPath) == false {
                let now = nowProvider()
                if try await store.markSourceArtifactDeleted(id: existing.id, deletedAt: now) {
                    report.deletedArtifacts += 1
                    try await enqueueProjectionJob(for: existing, jobType: .purge, sourceVersionID: "deleted", now: now)
                    report.queuedJobs += 1
                }
                continue
            }

            guard successfullyScannedRoots.contains(existing.rootPath) else { continue }
            guard discoveredSourceIDs.contains(existing.id) == false else { continue }

            let now = nowProvider()
            if try await store.markSourceArtifactDeleted(id: existing.id, deletedAt: now) {
                report.deletedArtifacts += 1
                try await enqueueProjectionJob(for: existing, jobType: .purge, sourceVersionID: "deleted", now: now)
                report.queuedJobs += 1
            }
        }

        try await upsertHealth(from: report)
        return report
    }

    private func upsertHealth(from report: ArtifactDiscoveryRunReport) async throws {
        let now = nowProvider()
        let status: RetrievalHealthStatus = report.issues.isEmpty ? .healthy : .degraded
        let errorCode = report.issues.first?.code.rawValue
        let errorMessage = report.issues.first?.message
        let details = ArtifactDiscoveryHealthDetails(report: report)
        let detailsData = try JSONEncoder().encode(details)
        let detailsJSON = String(data: detailsData, encoding: .utf8)

        // Change-gate (same pattern as InsightEngine): at idle — and always
        // while the feature is disabled — this row is byte-identical every
        // refresh tick; skip the pointless writer transaction.
        let existing: RetrievalHealthRecord?
        do {
            existing = try await store.fetchRetrievalHealth()
                .first(where: { $0.subsystem == .discovery })
        } catch {
            AppLogger.dataStore.silentFailure("artifact_discovery_health_fetch_failed", error: error)
            existing = nil
        }
        if let existing,
           existing.status == status,
           existing.detailsJSON == detailsJSON,
           existing.errorCode == errorCode,
           existing.errorMessage == errorMessage {
            return
        }

        try await store.upsertRetrievalHealth(
            RetrievalHealthRecord(
                subsystem: .discovery,
                status: status,
                errorCode: errorCode,
                errorMessage: errorMessage,
                detailsJSON: detailsJSON,
                observedAt: now,
                updatedAt: now
            )
        )
    }

    private func enqueueProjectionJob(
        for artifact: SourceArtifactRecord,
        jobType: ProjectionJobType,
        sourceVersionID: String,
        now: Date
    ) async throws {
        let payload = ArtifactProjectionPayload(
            canonicalPath: artifact.canonicalPath,
            rootPath: artifact.rootPath,
            relativePath: artifact.relativePath,
            provenance: artifact.provenance,
            sourceKind: artifact.sourceKind.rawValue,
            contentHash: artifact.contentHash,
            deleted: jobType == .purge
        )
        let payloadJSON = String(data: try JSONEncoder().encode(payload), encoding: .utf8)
        let jobID = projectionJobID(jobType: jobType, sourceID: artifact.id, sourceVersionID: sourceVersionID)
        let priority = (jobType == .purge) ? 2 : 10

        try await store.enqueueProjectionJob(
            ProjectionJobRecord(
                id: jobID,
                jobType: jobType,
                sourceKind: artifact.sourceKind,
                sourceID: artifact.id,
                sourceVersionID: sourceVersionID,
                status: .queued,
                priority: priority,
                attempts: 0,
                maxAttempts: 5,
                payloadJSON: payloadJSON,
                scheduledAt: now,
                availableAt: now,
                createdAt: now,
                updatedAt: now
            )
        )
    }

    private func normalizedRegisteredRoots(_ roots: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for rawRoot in roots {
            let trimmed = rawRoot.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { continue }
            let expanded = (trimmed as NSString).expandingTildeInPath
            let canonical = canonicalPath(for: URL(fileURLWithPath: expanded, isDirectory: true))
            guard seen.insert(canonical).inserted else { continue }
            ordered.append(canonical)
        }
        return ordered
    }

    private func canonicalPath(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func isWithinRoot(candidatePath: String, rootPath: String) -> Bool {
        if candidatePath == rootPath { return true }
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
        return candidatePath.hasPrefix(rootPrefix)
    }

    private func relativePath(from candidatePath: String, rootPath: String) -> String {
        guard candidatePath != rootPath else { return "" }
        let prefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
        guard candidatePath.hasPrefix(prefix) else {
            return (candidatePath as NSString).lastPathComponent
        }
        return String(candidatePath.dropFirst(prefix.count))
    }

    private func inferredTitle(from body: String, fallbackPath: String) -> String {
        for line in body.split(whereSeparator: \.isNewline) {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("#") else { continue }
            let heading = trimmed.drop(while: { $0 == "#" || $0.isWhitespace })
            if heading.isEmpty == false {
                return String(heading)
            }
        }
        return URL(fileURLWithPath: fallbackPath).deletingPathExtension().lastPathComponent
    }

    private func stableSourceID(for canonicalPath: String) -> String {
        "artifact-\(sha256Hex(Data(canonicalPath.lowercased().utf8)))"
    }

    private func projectionJobID(jobType: ProjectionJobType, sourceID: String, sourceVersionID: String) -> String {
        "artifact-\(jobType.rawValue)-\(sourceID)-\(sourceVersionID)"
    }

    private func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct ArtifactProjectionPayload: Codable {
    let canonicalPath: String
    let rootPath: String
    let relativePath: String
    let provenance: String
    let sourceKind: String
    let contentHash: String
    let deleted: Bool
}

private struct ArtifactDiscoveryHealthDetails: Codable {
    struct IssueDetail: Codable {
        let code: String
        let message: String
        let path: String?
    }

    let enabled: Bool
    let scannedRoots: Int
    let discoveredArtifacts: Int
    let insertedArtifacts: Int
    let updatedArtifacts: Int
    let restoredArtifacts: Int
    let unchangedArtifacts: Int
    let deletedArtifacts: Int
    let queuedJobs: Int
    let issues: [IssueDetail]

    init(report: ArtifactDiscoveryRunReport) {
        enabled = report.enabled
        scannedRoots = report.scannedRoots
        discoveredArtifacts = report.discoveredArtifacts
        insertedArtifacts = report.insertedArtifacts
        updatedArtifacts = report.updatedArtifacts
        restoredArtifacts = report.restoredArtifacts
        unchangedArtifacts = report.unchangedArtifacts
        deletedArtifacts = report.deletedArtifacts
        queuedJobs = report.queuedJobs
        issues = report.issues.map {
            IssueDetail(code: $0.code.rawValue, message: $0.message, path: $0.path)
        }
    }
}

extension SettingsManager: @preconcurrency ArtifactDiscoverySettingsProviding {}

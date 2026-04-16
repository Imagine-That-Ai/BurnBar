import Foundation
import CryptoKit
import GRDB

// MARK: - Artifact Discovery

@MainActor
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

@MainActor
final class ArtifactDiscoveryService {
    private let dataStore: DataStore
    private let settingsProvider: any ArtifactDiscoverySettingsProviding
    private let fileManager: FileManager
    private let nowProvider: () -> Date

    init(
        dataStore: DataStore,
        settingsProvider: any ArtifactDiscoverySettingsProviding,
        fileManager: FileManager = .default,
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.dataStore = dataStore
        self.settingsProvider = settingsProvider
        self.fileManager = fileManager
        self.nowProvider = nowProvider
    }

    @discardableResult
    func discoverAndIngest() throws -> ArtifactDiscoveryRunReport {
        guard settingsProvider.artifactDiscoveryEnabled else {
            let report = ArtifactDiscoveryRunReport.disabled
            try upsertHealth(from: report)
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
            try upsertHealth(from: report)
            return report
        }

        let rules = ArtifactDiscoveryRules(additionalPatterns: settingsProvider.artifactDiscoveryAdditionalKnownPatterns)
        var discoveredSourceIDs = Set<String>()
        var successfullyScannedRoots = Set<String>()

        for rootPath in registeredRoots {
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
            guard let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
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
            successfullyScannedRoots.insert(rootPath)

            for case let candidateURL as URL in enumerator {
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

                let resourceValues = try? candidateURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey])
                guard resourceValues?.isRegularFile == true else { continue }

                let relativePath = relativePath(from: canonicalCandidatePath, rootPath: rootPath)
                guard let match = rules.match(relativePath: relativePath) else { continue }

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
                    fileSizeBytes: resourceValues?.fileSize ?? fileData.count,
                    fileModifiedAt: resourceValues?.contentModificationDate,
                    status: .active,
                    discoveredAt: now,
                    deletedAt: nil,
                    createdAt: now,
                    updatedAt: now
                )

                let disposition = try dataStore.upsertSourceArtifact(artifact)
                discoveredSourceIDs.insert(artifact.id)
                report.discoveredArtifacts += 1

                switch disposition {
                case .inserted:
                    report.insertedArtifacts += 1
                    try enqueueProjectionJob(for: artifact, jobType: .project, sourceVersionID: artifact.contentHash, now: now)
                    report.queuedJobs += 1
                case .updated:
                    report.updatedArtifacts += 1
                    try enqueueProjectionJob(for: artifact, jobType: .reproject, sourceVersionID: artifact.contentHash, now: now)
                    report.queuedJobs += 1
                case .restored:
                    report.restoredArtifacts += 1
                    try enqueueProjectionJob(for: artifact, jobType: .reproject, sourceVersionID: artifact.contentHash, now: now)
                    report.queuedJobs += 1
                case .unchanged:
                    report.unchangedArtifacts += 1
                }
            }
        }

        let existingArtifacts = try dataStore.fetchSourceArtifacts(
            includeDeleted: false,
            rootPaths: nil,
            sourceKinds: [.skillDoc, .agentDoc]
        )
        let registeredRootSet = Set(registeredRoots)
        for existing in existingArtifacts {
            if registeredRootSet.contains(existing.rootPath) == false {
                let now = nowProvider()
                if try dataStore.markSourceArtifactDeleted(id: existing.id, deletedAt: now) {
                    report.deletedArtifacts += 1
                    try enqueueProjectionJob(for: existing, jobType: .purge, sourceVersionID: "deleted", now: now)
                    report.queuedJobs += 1
                }
                continue
            }

            guard successfullyScannedRoots.contains(existing.rootPath) else { continue }
            guard discoveredSourceIDs.contains(existing.id) == false else { continue }

            let now = nowProvider()
            if try dataStore.markSourceArtifactDeleted(id: existing.id, deletedAt: now) {
                report.deletedArtifacts += 1
                try enqueueProjectionJob(for: existing, jobType: .purge, sourceVersionID: "deleted", now: now)
                report.queuedJobs += 1
            }
        }

        try upsertHealth(from: report)
        return report
    }

    private func upsertHealth(from report: ArtifactDiscoveryRunReport) throws {
        let now = nowProvider()
        let status: RetrievalHealthStatus = report.issues.isEmpty ? .healthy : .degraded
        let errorCode = report.issues.first?.code.rawValue
        let errorMessage = report.issues.first?.message
        let details = ArtifactDiscoveryHealthDetails(report: report)
        let detailsData = try JSONEncoder().encode(details)
        let detailsJSON = String(data: detailsData, encoding: .utf8)

        try dataStore.upsertRetrievalHealth(
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
    ) throws {
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

        try dataStore.enqueueProjectionJob(
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

extension SettingsManager: ArtifactDiscoverySettingsProviding {}

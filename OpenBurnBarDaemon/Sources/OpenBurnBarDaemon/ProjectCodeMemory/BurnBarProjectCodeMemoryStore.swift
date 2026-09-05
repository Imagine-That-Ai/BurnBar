#if canImport(CoreServices)
import CoreServices
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import OpenBurnBarEngine
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

let projectCodeMemorySQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
// DispatchSpecificKey is not Sendable; access is confined to the project-code serial queue.
nonisolated(unsafe) let projectCodeMemoryQueueKey = DispatchSpecificKey<UUID>()

enum BurnBarProjectCodeMemoryStoreError: Error, LocalizedError {
    case emptyText
    case emptyQuery
    case memoryNotFound(String)
    case invalidMemoryReviewStatus(String)
    case projectPathUnavailable(String)
    case secretRejected(labels: [String])
    case databaseSnapshotUnavailable(String)
    case databaseSnapshotInvalidPath(String)
    case databaseSnapshotTooLarge(Int)
    case databaseSnapshotPermissions(String)
    case databaseSnapshotFailed(String)
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "Memory text is empty."
        case .emptyQuery:
            return "Query is empty."
        case .memoryNotFound(let memoryID):
            return "Memory was not found in the selected project: \(memoryID)"
        case .invalidMemoryReviewStatus(let status):
            return "Unsupported memory review status: \(status)"
        case .projectPathUnavailable(let path):
            return "Project path is not readable: \(path)"
        case .secretRejected(let labels):
            return "Rejected before persistence by the project memory secret scanner: \(labels.joined(separator: ", "))."
        case .databaseSnapshotUnavailable(let reason):
            return "Encrypted database snapshots are unavailable: \(reason)"
        case .databaseSnapshotInvalidPath(let path):
            return "Database snapshot path is not allowed: \(path)"
        case .databaseSnapshotTooLarge(let bytes):
            return "Database snapshot exceeds the configured byte limit (\(bytes) bytes)."
        case .databaseSnapshotPermissions(let path):
            return "Database snapshot permissions are unsafe: \(path)"
        case .databaseSnapshotFailed(let reason):
            return "Database snapshot operation failed: \(reason)"
        case .sqlite(let message):
            return message
        }
    }

}

// AUDIT(@unchecked Sendable): raw SQLite access is serialized through `dbQueue`.
// sendable-allowlist: sqlite-raw-pointer
final class BurnBarProjectCodeMemoryStore: @unchecked Sendable {
    struct SQLiteRow {
        let values: [String?]
        let blobs: [Data?]
    }

    struct SQLiteSymbolRow {
        let id: String
        let artifactID: String
        let filePath: String
        let name: String
        let kind: String
        let range: BurnBarProjectCodeRange
        let confidenceTier: String
        let blobSHA: String
        let tierEvidenceJSON: String?
    }

    struct IndexedArtifact {
        let id: String
        let filePath: String
        let blobSHA: String
    }

    struct ProjectIdentity {
        let projectID: String
        let canonicalPath: String
        let pathHash: String
        let fingerprint: String
    }

    struct CodeSearchEvaluation {
        let hits: [BurnBarProjectCodeSearchHit]
        let staleCandidateCount: Int
        let totalCandidateCount: Int
        let degradation: BurnBarProjectCodeDegradation?
    }

    struct CodeContextSelection {
        let text: String
        let contentKind: String
        let confidenceTier: String
        let symbolName: String?
        let contentHash: String?
    }

    struct MemoryIndexRow {
        let id: String
        let projectID: String
        let kind: String
        let scope: String
        let confidence: Double
        let bodyReference: String
        let tags: [String]
        let sourcePath: String?
        let updatedAt: String
        let reviewStatus: MemoryReviewStatus
    }

    struct MemoryRecallCandidate {
        let row: MemoryIndexRow
        let body: String
        let searchableTokens: [String]
    }

    static let agentMemoryPageID = "agent-notes"
    static let codeSourceKind = "code"
    static let codeProvider = "local-code"
    static let ignoredDirectories: Set<String> = [
        ".git", ".build", ".swiftpm", ".deriveddata", "DerivedData", "node_modules",
        "build", "dist", ".next", ".gradle", ".idea", ".vscode", ".serena",
        ".codex", ".claude", ".venv", "target", "Vendor"
    ]
    static let indexedExtensions: Set<String> = [
        "swift", "kt", "kts", "java",
        "ts", "tsx", "js", "jsx",
        "py", "rs", "go",
        "m", "mm", "h", "hpp", "c", "cc", "cpp",
        "json", "md", "yml", "yaml"
    ]
    static let defaultProjectStorageBudgetBytes = 512 * 1_024 * 1_024
    static let maximumProjectStorageBudgetBytes = 10 * 1_024 * 1_024 * 1_024
    static let minimumSemanticCodeCosineScore = 0.20
    /// Bump when the code-store schema changes; surfaced by operator diagnostics so an
    /// operator can confirm which schema generation a daemon's index DB is running.
    static let schemaVersion = 3

    var db: OpaquePointer?
    let dbQueue = DispatchQueue(label: "com.openburnbar.daemon.project-code-memory.sqlite")
    let dbQueueID = UUID()
    let logger: BurnBarDaemonLogger
    let databasePath: String
    let jsonEncoder = JSONEncoder()
    let jsonDecoder = JSONDecoder()
    var projectWatchers: [String: ProjectWatcher] = [:]
    /// Daemon-owned code embedder (default: the OS NaturalLanguage sentence model).
    /// Injectable so tests can use a deterministic provider for version-floor / RRF checks.
    let embeddingProvider: BurnBarCodeEmbeddingProvider

    init(
        databasePath: String,
        logger: BurnBarDaemonLogger,
        embeddingProvider: BurnBarCodeEmbeddingProvider = NLSentenceEmbeddingProvider()
    ) throws {
        self.databasePath = databasePath
        self.logger = logger
        self.embeddingProvider = embeddingProvider
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(databasePath, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite error"
            if let handle { sqlite3_close(handle) }
            throw BurnBarProjectCodeMemoryStoreError.sqlite("Failed to open project code memory SQLite database: \(message)")
        }
        do {
            try BurnBarDaemonDatabaseCipher.applyKeyIfAvailable(to: handle)
        } catch {
            sqlite3_close(handle)
            throw error
        }
        sqlite3_busy_timeout(handle, 5000)
        db = handle
        dbQueue.setSpecific(key: projectCodeMemoryQueueKey, value: dbQueueID)
        try databaseSync {
            try bootstrapSchema()
            try backfillMemoryEmbeddings()
        }
        // The code-memory store contains indexed source text and memory
        // references. Tighten the primary file on every open so snapshot export
        // never has to copy a group/world-readable database.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: databasePath
        )
    }

    deinit {
        projectWatchers.values.forEach { $0.timer.cancel() }
        guard let db else { return }
        _ = databaseSync {
            sqlite3_close(db)
        }
    }

    /// Whether `search_chunks` carries the `ftsRowid` mapping column added by
    /// the app-side `v55_search_chunks_fts_rowid` migration on the shared
    /// schema. Probed once per process (the column never disappears; a
    /// mid-run app migration is picked up on the next daemon start, and rows
    /// written meanwhile stay correct via the NULL-rowid legacy delete path).
    var cachedSearchChunksHasFtsRowid: Bool?

    func projectCodeMemoryProductionReadinessReasons() -> [String] {
        var reasons = [
            "PROJECT_CODE_MEMORY_PRODUCTION_READY=false",
            "real local embeddings are not configured; semanticAvailable=false",
            "hosted code sync remains disabled unless an explicit code asset-class flag is enabled"
        ]
        if Self.staticParserExecutablePath() == nil {
            reasons.append("static parser helper is unavailable")
        }
        if BurnBarDaemonDatabaseCipher.isCipherAvailable() == false {
            reasons.append("SQLCipher codec not linked; Project Code Memory release readiness is blocked")
        }
        if BurnBarDaemonDatabaseCipher.isEncryptedDatabaseFile(at: databasePath) == false {
            reasons.append("database file is not encrypted for this daemon handle")
        }
        return reasons
    }
}

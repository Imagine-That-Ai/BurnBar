import Foundation

public struct BurnBarProjectSelector: Codable, Hashable, Sendable {
    public let projectPath: String?
    public let includeCrossProject: Bool

    public init(projectPath: String? = nil, includeCrossProject: Bool = false) {
        self.projectPath = projectPath
        self.includeCrossProject = includeCrossProject
    }
}

public struct BurnBarProjectMemoryRememberRequest: Codable, Hashable, Sendable {
    public let text: String
    public let projectPath: String?
    public let kind: String
    public let scope: String
    public let tags: [String]
    public let confidence: Double
    public let sourcePath: String?

    public init(
        text: String,
        projectPath: String? = nil,
        kind: String = "note",
        scope: String = "personal",
        tags: [String] = [],
        confidence: Double = 1.0,
        sourcePath: String? = nil
    ) {
        self.text = text
        self.projectPath = projectPath
        self.kind = kind
        self.scope = scope
        self.tags = tags
        self.confidence = confidence
        self.sourcePath = sourcePath
    }
}

public struct BurnBarProjectMemoryRememberResponse: Codable, Hashable, Sendable {
    public let traceID: String
    public let projectID: String
    public let memoryID: String
    public let auditHash: String

    public init(traceID: String, projectID: String, memoryID: String, auditHash: String) {
        self.traceID = traceID
        self.projectID = projectID
        self.memoryID = memoryID
        self.auditHash = auditHash
    }
}

public struct BurnBarProjectMemoryRecallRequest: Codable, Hashable, Sendable {
    public let query: String
    public let projectPath: String?
    public let limit: Int
    public let scope: String
    public let includeCrossProject: Bool

    public init(
        query: String,
        projectPath: String? = nil,
        limit: Int = 20,
        scope: String = "all",
        includeCrossProject: Bool = false
    ) {
        self.query = query
        self.projectPath = projectPath
        self.limit = limit
        self.scope = scope
        self.includeCrossProject = includeCrossProject
    }
}

public struct BurnBarProjectMemoryHit: Codable, Hashable, Sendable {
    public let memoryID: String
    public let projectID: String
    public let kind: String
    public let scope: String
    public let confidence: Double
    public let bodyRedacted: String
    public let tags: [String]
    public let sourcePath: String?
    public let snippet: String
    public let rank: Double?

    public init(
        memoryID: String,
        projectID: String,
        kind: String,
        scope: String,
        confidence: Double,
        bodyRedacted: String,
        tags: [String],
        sourcePath: String?,
        snippet: String,
        rank: Double?
    ) {
        self.memoryID = memoryID
        self.projectID = projectID
        self.kind = kind
        self.scope = scope
        self.confidence = confidence
        self.bodyRedacted = bodyRedacted
        self.tags = tags
        self.sourcePath = sourcePath
        self.snippet = snippet
        self.rank = rank
    }
}

public struct BurnBarProjectMemoryRecallResponse: Codable, Hashable, Sendable {
    public let traceID: String
    public let projectID: String
    public let hits: [BurnBarProjectMemoryHit]

    public init(traceID: String, projectID: String, hits: [BurnBarProjectMemoryHit]) {
        self.traceID = traceID
        self.projectID = projectID
        self.hits = hits
    }
}

public struct BurnBarProjectMemoryForgetRequest: Codable, Hashable, Sendable {
    public let memoryID: String
    public let projectPath: String?
    public let requireCloudDelete: Bool

    public init(memoryID: String, projectPath: String? = nil, requireCloudDelete: Bool = false) {
        self.memoryID = memoryID
        self.projectPath = projectPath
        self.requireCloudDelete = requireCloudDelete
    }
}

public struct BurnBarProjectMemoryForgetResponse: Codable, Hashable, Sendable {
    public let traceID: String
    public let projectID: String
    public let memoryID: String
    public let localDeleted: Bool
    public let cloudDeletePending: Bool
    public let auditHash: String

    public init(
        traceID: String,
        projectID: String,
        memoryID: String,
        localDeleted: Bool,
        cloudDeletePending: Bool,
        auditHash: String
    ) {
        self.traceID = traceID
        self.projectID = projectID
        self.memoryID = memoryID
        self.localDeleted = localDeleted
        self.cloudDeletePending = cloudDeletePending
        self.auditHash = auditHash
    }
}

public struct BurnBarProjectMemoryAuditTrailRequest: Codable, Hashable, Sendable {
    public let projectPath: String?
    public let limit: Int

    public init(projectPath: String? = nil, limit: Int = 50) {
        self.projectPath = projectPath
        self.limit = limit
    }
}

public struct BurnBarProjectMemoryAuditEvent: Codable, Hashable, Sendable {
    public let seq: Int64
    public let ts: String
    public let actor: String
    public let action: String
    public let domain: String
    public let projectID: String?
    public let subjectID: String?
    public let labels: [String]
    public let prevHash: String?
    public let hash: String

    public init(
        seq: Int64,
        ts: String,
        actor: String,
        action: String,
        domain: String,
        projectID: String?,
        subjectID: String?,
        labels: [String],
        prevHash: String?,
        hash: String
    ) {
        self.seq = seq
        self.ts = ts
        self.actor = actor
        self.action = action
        self.domain = domain
        self.projectID = projectID
        self.subjectID = subjectID
        self.labels = labels
        self.prevHash = prevHash
        self.hash = hash
    }
}

public struct BurnBarProjectMemoryAuditTrailResponse: Codable, Hashable, Sendable {
    public let traceID: String
    public let projectID: String
    public let events: [BurnBarProjectMemoryAuditEvent]

    public init(traceID: String, projectID: String, events: [BurnBarProjectMemoryAuditEvent]) {
        self.traceID = traceID
        self.projectID = projectID
        self.events = events
    }
}

public struct BurnBarProjectMemoryAnalyticsRequest: Codable, Hashable, Sendable {
    public let projectPath: String?

    public init(projectPath: String? = nil) {
        self.projectPath = projectPath
    }
}

public struct BurnBarProjectMemoryAnalyticsResponse: Codable, Hashable, Sendable {
    public let traceID: String
    public let projectID: String
    public let total: Int
    public let byKind: [String: Int]
    public let byScope: [String: Int]
    public let lastAuditHash: String?

    public init(
        traceID: String,
        projectID: String,
        total: Int,
        byKind: [String: Int],
        byScope: [String: Int],
        lastAuditHash: String?
    ) {
        self.traceID = traceID
        self.projectID = projectID
        self.total = total
        self.byKind = byKind
        self.byScope = byScope
        self.lastAuditHash = lastAuditHash
    }
}

public struct BurnBarProjectCodeRange: Codable, Hashable, Sendable {
    public let startLine: Int
    public let endLine: Int
    public let startColumn: Int?
    public let endColumn: Int?

    public init(startLine: Int, endLine: Int, startColumn: Int? = nil, endColumn: Int? = nil) {
        self.startLine = startLine
        self.endLine = endLine
        self.startColumn = startColumn
        self.endColumn = endColumn
    }
}

public struct BurnBarProjectCodeIndexProjectRequest: Codable, Hashable, Sendable {
    public let projectPath: String?
    public let maxFiles: Int
    public let maxFileBytes: Int
    public let storageBudgetBytes: Int?

    public init(
        projectPath: String? = nil,
        maxFiles: Int = 2_500,
        maxFileBytes: Int = 512_000,
        storageBudgetBytes: Int? = nil
    ) {
        self.projectPath = projectPath
        self.maxFiles = maxFiles
        self.maxFileBytes = maxFileBytes
        self.storageBudgetBytes = storageBudgetBytes
    }
}

public struct BurnBarProjectCodeRejectedFile: Codable, Hashable, Sendable {
    public let filePath: String
    public let labels: [String]

    public init(filePath: String, labels: [String]) {
        self.filePath = filePath
        self.labels = labels
    }
}

public struct BurnBarProjectCodeIndexProjectResponse: Codable, Hashable, Sendable {
    public let traceID: String
    public let projectID: String
    public let projectRoot: String
    public let indexedFiles: Int
    public let chunkCount: Int
    public let symbolCount: Int
    public let rejectedFiles: [BurnBarProjectCodeRejectedFile]
    public let commitSHA: String?
    public let auditHash: String

    public init(
        traceID: String,
        projectID: String,
        projectRoot: String,
        indexedFiles: Int,
        chunkCount: Int,
        symbolCount: Int,
        rejectedFiles: [BurnBarProjectCodeRejectedFile],
        commitSHA: String?,
        auditHash: String
    ) {
        self.traceID = traceID
        self.projectID = projectID
        self.projectRoot = projectRoot
        self.indexedFiles = indexedFiles
        self.chunkCount = chunkCount
        self.symbolCount = symbolCount
        self.rejectedFiles = rejectedFiles
        self.commitSHA = commitSHA
        self.auditHash = auditHash
    }
}

public struct BurnBarProjectCodeSearchRequest: Codable, Hashable, Sendable {
    public let query: String
    public let projectPath: String?
    public let limit: Int

    public init(query: String, projectPath: String? = nil, limit: Int = 20) {
        self.query = query
        self.projectPath = projectPath
        self.limit = limit
    }
}

public struct BurnBarProjectCodeSearchHit: Codable, Hashable, Sendable {
    public let chunkID: String
    public let filePath: String
    public let snippet: String
    public let rank: Double?

    public init(chunkID: String, filePath: String, snippet: String, rank: Double?) {
        self.chunkID = chunkID
        self.filePath = filePath
        self.snippet = snippet
        self.rank = rank
    }
}

public struct BurnBarProjectCodeSearchResponse: Codable, Hashable, Sendable {
    public let traceID: String
    public let projectID: String
    public let hits: [BurnBarProjectCodeSearchHit]

    public init(traceID: String, projectID: String, hits: [BurnBarProjectCodeSearchHit]) {
        self.traceID = traceID
        self.projectID = projectID
        self.hits = hits
    }
}

public struct BurnBarProjectCodeContextPackRequest: Codable, Hashable, Sendable {
    public let query: String
    public let projectPath: String?
    public let limit: Int
    public let maxBytes: Int

    public init(query: String, projectPath: String? = nil, limit: Int = 10, maxBytes: Int = 24_000) {
        self.query = query
        self.projectPath = projectPath
        self.limit = limit
        self.maxBytes = maxBytes
    }
}

public struct BurnBarProjectCodeContextPackResponse: Codable, Hashable, Sendable {
    public let traceID: String
    public let projectID: String
    public let context: String
    public let hits: [BurnBarProjectCodeSearchHit]
    public let truncated: Bool

    public init(
        traceID: String,
        projectID: String,
        context: String,
        hits: [BurnBarProjectCodeSearchHit],
        truncated: Bool
    ) {
        self.traceID = traceID
        self.projectID = projectID
        self.context = context
        self.hits = hits
        self.truncated = truncated
    }
}

public struct BurnBarProjectCodeSymbolRequest: Codable, Hashable, Sendable {
    public let name: String
    public let projectPath: String?
    public let limit: Int

    public init(name: String, projectPath: String? = nil, limit: Int = 20) {
        self.name = name
        self.projectPath = projectPath
        self.limit = limit
    }
}

public struct BurnBarProjectCodeTierEvidence: Codable, Hashable, Sendable {
    public let parser: String?
    public let language: String?
    public let blobSHA: String?
    public let shaMatch: Bool?
    public let lspResponded: Bool?
    public let details: [String: String]

    public init(
        parser: String? = nil,
        language: String? = nil,
        blobSHA: String? = nil,
        shaMatch: Bool? = nil,
        lspResponded: Bool? = nil,
        details: [String: String] = [:]
    ) {
        self.parser = parser
        self.language = language
        self.blobSHA = blobSHA
        self.shaMatch = shaMatch
        self.lspResponded = lspResponded
        self.details = details
    }
}

public struct BurnBarProjectCodeSymbol: Codable, Hashable, Sendable {
    public let symbolID: String
    public let name: String
    public let kind: String
    public let filePath: String
    public let range: BurnBarProjectCodeRange
    public let confidenceTier: String
    public let tierEvidence: BurnBarProjectCodeTierEvidence?

    public init(
        symbolID: String,
        name: String,
        kind: String,
        filePath: String,
        range: BurnBarProjectCodeRange,
        confidenceTier: String,
        tierEvidence: BurnBarProjectCodeTierEvidence? = nil
    ) {
        self.symbolID = symbolID
        self.name = name
        self.kind = kind
        self.filePath = filePath
        self.range = range
        self.confidenceTier = confidenceTier
        self.tierEvidence = tierEvidence
    }
}

public struct BurnBarProjectCodeSymbolResponse: Codable, Hashable, Sendable {
    public let traceID: String
    public let projectID: String
    public let symbols: [BurnBarProjectCodeSymbol]

    public init(traceID: String, projectID: String, symbols: [BurnBarProjectCodeSymbol]) {
        self.traceID = traceID
        self.projectID = projectID
        self.symbols = symbols
    }
}

public struct BurnBarProjectCodeReferencesResponse: Codable, Hashable, Sendable {
    public let traceID: String
    public let projectID: String
    public let references: [BurnBarProjectCodeReference]

    public init(traceID: String, projectID: String, references: [BurnBarProjectCodeReference]) {
        self.traceID = traceID
        self.projectID = projectID
        self.references = references
    }
}

public struct BurnBarProjectCodeReference: Codable, Hashable, Sendable {
    public let referenceID: String
    public let fromFilePath: String
    public let targetSymbol: BurnBarProjectCodeSymbol
    public let range: BurnBarProjectCodeRange
    public let confidenceTier: String

    public init(
        referenceID: String,
        fromFilePath: String,
        targetSymbol: BurnBarProjectCodeSymbol,
        range: BurnBarProjectCodeRange,
        confidenceTier: String
    ) {
        self.referenceID = referenceID
        self.fromFilePath = fromFilePath
        self.targetSymbol = targetSymbol
        self.range = range
        self.confidenceTier = confidenceTier
    }
}

public struct BurnBarProjectCodeCallGraphResponse: Codable, Hashable, Sendable {
    public let traceID: String
    public let projectID: String
    public let edges: [BurnBarProjectCodeCallEdge]

    public init(traceID: String, projectID: String, edges: [BurnBarProjectCodeCallEdge]) {
        self.traceID = traceID
        self.projectID = projectID
        self.edges = edges
    }
}

public struct BurnBarProjectCodeCallEdge: Codable, Hashable, Sendable {
    public let edgeID: String
    public let caller: BurnBarProjectCodeSymbol
    public let callee: BurnBarProjectCodeSymbol
    public let confidenceTier: String

    public init(
        edgeID: String,
        caller: BurnBarProjectCodeSymbol,
        callee: BurnBarProjectCodeSymbol,
        confidenceTier: String
    ) {
        self.edgeID = edgeID
        self.caller = caller
        self.callee = callee
        self.confidenceTier = confidenceTier
    }
}

public struct BurnBarProjectCodeDiagnosticsRequest: Codable, Hashable, Sendable {
    public let projectPath: String?
    public let filePath: String?

    public init(projectPath: String? = nil, filePath: String? = nil) {
        self.projectPath = projectPath
        self.filePath = filePath
    }
}

public struct BurnBarProjectCodeDiagnostic: Codable, Hashable, Sendable {
    public let filePath: String
    public let tool: String
    public let payloadJSON: String
    public let cachedAt: String

    public init(filePath: String, tool: String, payloadJSON: String, cachedAt: String) {
        self.filePath = filePath
        self.tool = tool
        self.payloadJSON = payloadJSON
        self.cachedAt = cachedAt
    }
}

public struct BurnBarProjectCodeDiagnosticsResponse: Codable, Hashable, Sendable {
    public let traceID: String
    public let projectID: String
    public let diagnostics: [BurnBarProjectCodeDiagnostic]

    public init(traceID: String, projectID: String, diagnostics: [BurnBarProjectCodeDiagnostic]) {
        self.traceID = traceID
        self.projectID = projectID
        self.diagnostics = diagnostics
    }
}

public struct BurnBarProjectCodeIndexStatusRequest: Codable, Hashable, Sendable {
    public let projectPath: String?

    public init(projectPath: String? = nil) {
        self.projectPath = projectPath
    }
}

public struct BurnBarProjectCodeIndexStatusResponse: Codable, Hashable, Sendable {
    public let traceID: String
    public let projectID: String
    public let projectRoot: String?
    public let indexedAt: String?
    public let artifactCount: Int
    public let chunkCount: Int
    public let symbolCount: Int
    public let referenceCount: Int
    public let callEdgeCount: Int
    public let rejectedCount: Int
    public let lastCommitSHA: String?
    public let pendingForgetCount: Int
    public let storageByteCount: Int
    public let storageBudgetBytes: Int
    public let storageWithinBudget: Bool
    public let lastVacuumedAt: String?

    public init(
        traceID: String,
        projectID: String,
        projectRoot: String?,
        indexedAt: String?,
        artifactCount: Int,
        chunkCount: Int,
        symbolCount: Int,
        referenceCount: Int,
        callEdgeCount: Int,
        rejectedCount: Int,
        lastCommitSHA: String?,
        pendingForgetCount: Int,
        storageByteCount: Int = 0,
        storageBudgetBytes: Int = 0,
        storageWithinBudget: Bool = true,
        lastVacuumedAt: String? = nil
    ) {
        self.traceID = traceID
        self.projectID = projectID
        self.projectRoot = projectRoot
        self.indexedAt = indexedAt
        self.artifactCount = artifactCount
        self.chunkCount = chunkCount
        self.symbolCount = symbolCount
        self.referenceCount = referenceCount
        self.callEdgeCount = callEdgeCount
        self.rejectedCount = rejectedCount
        self.lastCommitSHA = lastCommitSHA
        self.pendingForgetCount = pendingForgetCount
        self.storageByteCount = storageByteCount
        self.storageBudgetBytes = storageBudgetBytes
        self.storageWithinBudget = storageWithinBudget
        self.lastVacuumedAt = lastVacuumedAt
    }
}

public struct BurnBarProjectCodeWatchProjectRequest: Codable, Hashable, Sendable {
    public let projectPath: String?
    public let maxFiles: Int
    public let maxFileBytes: Int
    public let storageBudgetBytes: Int?
    public let pollIntervalSeconds: Double

    public init(
        projectPath: String? = nil,
        maxFiles: Int = 2_500,
        maxFileBytes: Int = 512_000,
        storageBudgetBytes: Int? = nil,
        pollIntervalSeconds: Double = 2.0
    ) {
        self.projectPath = projectPath
        self.maxFiles = maxFiles
        self.maxFileBytes = maxFileBytes
        self.storageBudgetBytes = storageBudgetBytes
        self.pollIntervalSeconds = pollIntervalSeconds
    }
}

public struct BurnBarProjectCodeWatchProjectResponse: Codable, Hashable, Sendable {
    public let traceID: String
    public let projectID: String
    public let projectRoot: String
    public let watching: Bool
    public let pollIntervalSeconds: Double
    public let signature: String
    public let indexedFiles: Int

    public init(
        traceID: String,
        projectID: String,
        projectRoot: String,
        watching: Bool,
        pollIntervalSeconds: Double,
        signature: String,
        indexedFiles: Int
    ) {
        self.traceID = traceID
        self.projectID = projectID
        self.projectRoot = projectRoot
        self.watching = watching
        self.pollIntervalSeconds = pollIntervalSeconds
        self.signature = signature
        self.indexedFiles = indexedFiles
    }
}

public struct BurnBarProjectCodeExploreRequest: Codable, Hashable, Sendable {
    public let projectPath: String?
    public let query: String?
    public let limit: Int
    public let maxBytes: Int

    public init(projectPath: String? = nil, query: String? = nil, limit: Int = 50, maxBytes: Int = 24_000) {
        self.projectPath = projectPath
        self.query = query
        self.limit = limit
        self.maxBytes = maxBytes
    }
}

public struct BurnBarProjectCodeExploreFile: Codable, Hashable, Sendable {
    public let filePath: String
    public let lang: String?
    public let symbolCount: Int

    public init(filePath: String, lang: String?, symbolCount: Int) {
        self.filePath = filePath
        self.lang = lang
        self.symbolCount = symbolCount
    }
}

public struct BurnBarProjectCodeExploreResponse: Codable, Hashable, Sendable {
    public let traceID: String
    public let projectID: String
    public let files: [BurnBarProjectCodeExploreFile]
    public let context: String?
    public let hits: [BurnBarProjectCodeSearchHit]
    public let truncated: Bool

    public init(
        traceID: String,
        projectID: String,
        files: [BurnBarProjectCodeExploreFile],
        context: String? = nil,
        hits: [BurnBarProjectCodeSearchHit] = [],
        truncated: Bool = false
    ) {
        self.traceID = traceID
        self.projectID = projectID
        self.files = files
        self.context = context
        self.hits = hits
        self.truncated = truncated
    }
}

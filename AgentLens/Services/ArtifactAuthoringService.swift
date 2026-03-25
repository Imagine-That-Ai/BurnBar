import Foundation

enum ArtifactAuthoringOperation: String, Codable, CaseIterable, Sendable {
    case draft
    case refine
}

struct ArtifactAuthoringReference: Identifiable, Equatable, Sendable {
    let rank: Int
    let sourceKind: SearchSourceKind
    let sourceID: String
    let documentID: String
    let chunkID: String
    let title: String
    let subtitle: String?
    let projectName: String?
    let sectionPath: String?
    let snippet: String
    let startOffset: Int
    let endOffset: Int
    let rerankScore: Double

    var id: String { chunkID }
}

struct ArtifactAuthoringDraft: Identifiable, Equatable, Sendable {
    let id: String
    let sourceKind: SearchSourceKind
    let operation: ArtifactAuthoringOperation
    let request: String
    let retrievalQuery: String
    let projectName: String?
    let systemPrompt: String
    let userPrompt: String
    let content: String
    let references: [ArtifactAuthoringReference]
    let generatedAt: Date

    var provenanceSummary: String {
        if references.isEmpty {
            return "No prior references were retrieved."
        }
        return references.map {
            "[R\($0.rank)] \($0.sourceKind.rawValue) · \($0.title) · \($0.sourceID)"
        }.joined(separator: "\n")
    }
}

struct ArtifactAuthoringSaveResult: Equatable, Sendable {
    let artifact: SourceArtifactRecord
    let disposition: SourceArtifactWriteDisposition
    let projectionJobEnqueued: Bool
    let projectionJobID: String?
}

enum ArtifactAuthoringError: LocalizedError {
    case unsupportedSourceKind(SearchSourceKind)
    case emptyRequest
    case emptyGeneratedContent
    case noRegisteredRoots
    case pathOutsideRegisteredRoots(String)
    case pathDoesNotMatchKnownPatterns(String)
    case sourceKindMismatch(path: String, expected: SearchSourceKind, actual: SearchSourceKind)
    case invalidUTF8
    case cliUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedSourceKind(let kind):
            return "Artifact authoring only supports skill and agent docs (received \(kind.rawValue))."
        case .emptyRequest:
            return "Draft/refine request cannot be empty."
        case .emptyGeneratedContent:
            return "The authoring model returned empty content."
        case .noRegisteredRoots:
            return "No registered roots are configured for artifact authoring."
        case .pathOutsideRegisteredRoots(let path):
            return "Artifact path is outside registered roots: \(path)"
        case .pathDoesNotMatchKnownPatterns(let path):
            return "Artifact path does not match known skill/agent patterns: \(path)"
        case .sourceKindMismatch(let path, let expected, let actual):
            return "Artifact path \(path) resolved to \(actual.rawValue), but \(expected.rawValue) was requested."
        case .invalidUTF8:
            return "Artifact content could not be encoded as UTF-8."
        case .cliUnavailable:
            return "No `claude` or `codex` CLI backend is available for authoring."
        }
    }
}

@MainActor
protocol ArtifactAuthoringTextGenerating: AnyObject {
    func generate(systemPrompt: String, userPrompt: String) async throws -> String
}

@MainActor
final class CLIArtifactAuthoringTextGenerator: ArtifactAuthoringTextGenerating {
    private let cliBridge: CLIBridge

    init(cliBridge: CLIBridge = CLIBridge()) {
        self.cliBridge = cliBridge
    }

    func generate(systemPrompt: String, userPrompt: String) async throws -> String {
        await cliBridge.detect()
        guard cliBridge.detectedBackend != nil else {
            throw ArtifactAuthoringError.cliUnavailable
        }

        var text = ""
        for try await event in cliBridge.chat(systemPrompt: systemPrompt, userMessage: userPrompt) {
            guard case let .text(chunk) = event, chunk.isEmpty == false else { continue }
            text += chunk
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw ArtifactAuthoringError.emptyGeneratedContent
        }
        return trimmed
    }
}

@MainActor
final class ArtifactAuthoringService {
    private let dataStore: DataStore
    private let retrievalService: SearchService
    private let settingsProvider: any ArtifactDiscoverySettingsProviding
    private let textGenerator: any ArtifactAuthoringTextGenerating
    private let fileManager: FileManager
    private let nowProvider: () -> Date

    init(
        dataStore: DataStore,
        retrievalService: SearchService? = nil,
        settingsProvider: any ArtifactDiscoverySettingsProviding = SettingsManager.shared,
        textGenerator: any ArtifactAuthoringTextGenerating = CLIArtifactAuthoringTextGenerator(),
        fileManager: FileManager = .default,
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.dataStore = dataStore
        self.retrievalService = retrievalService ?? SearchService.makeConversationSearchService(dataStore: dataStore)
        self.settingsProvider = settingsProvider
        self.textGenerator = textGenerator
        self.fileManager = fileManager
        self.nowProvider = nowProvider
    }

    func draftSkill(
        request: String,
        projectName: String? = nil,
        retrievalQuery: String? = nil,
        contextLimit: Int = 6
    ) async throws -> ArtifactAuthoringDraft {
        try await generateDraft(
            sourceKind: .skillDoc,
            operation: .draft,
            request: request,
            existingMarkdown: nil,
            projectName: projectName,
            retrievalQuery: retrievalQuery,
            contextLimit: contextLimit
        )
    }

    func refineSkill(
        existingMarkdown: String,
        instructions: String,
        projectName: String? = nil,
        retrievalQuery: String? = nil,
        contextLimit: Int = 6
    ) async throws -> ArtifactAuthoringDraft {
        try await generateDraft(
            sourceKind: .skillDoc,
            operation: .refine,
            request: instructions,
            existingMarkdown: existingMarkdown,
            projectName: projectName,
            retrievalQuery: retrievalQuery,
            contextLimit: contextLimit
        )
    }

    func draftAgentDoc(
        request: String,
        projectName: String? = nil,
        retrievalQuery: String? = nil,
        contextLimit: Int = 6
    ) async throws -> ArtifactAuthoringDraft {
        try await generateDraft(
            sourceKind: .agentDoc,
            operation: .draft,
            request: request,
            existingMarkdown: nil,
            projectName: projectName,
            retrievalQuery: retrievalQuery,
            contextLimit: contextLimit
        )
    }

    func refineAgentDoc(
        existingMarkdown: String,
        instructions: String,
        projectName: String? = nil,
        retrievalQuery: String? = nil,
        contextLimit: Int = 6
    ) async throws -> ArtifactAuthoringDraft {
        try await generateDraft(
            sourceKind: .agentDoc,
            operation: .refine,
            request: instructions,
            existingMarkdown: existingMarkdown,
            projectName: projectName,
            retrievalQuery: retrievalQuery,
            contextLimit: contextLimit
        )
    }

    func saveDraft(_ draft: ArtifactAuthoringDraft, to destinationPath: String) throws -> ArtifactAuthoringSaveResult {
        try saveAuthoredArtifact(
            sourceKind: draft.sourceKind,
            markdown: draft.content,
            destinationPath: destinationPath,
            operation: draft.operation,
            references: draft.references
        )
    }

    func saveAuthoredArtifact(
        sourceKind: SearchSourceKind,
        markdown: String,
        destinationPath: String,
        operation: ArtifactAuthoringOperation,
        references: [ArtifactAuthoringReference] = []
    ) throws -> ArtifactAuthoringSaveResult {
        guard sourceKind == .skillDoc || sourceKind == .agentDoc else {
            throw ArtifactAuthoringError.unsupportedSourceKind(sourceKind)
        }

        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw ArtifactAuthoringError.emptyGeneratedContent
        }

        let expandedDestination = (destinationPath as NSString).expandingTildeInPath
        let destinationURL = URL(fileURLWithPath: expandedDestination)
        let parentURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)

        guard let encoded = markdown.data(using: .utf8) else {
            throw ArtifactAuthoringError.invalidUTF8
        }
        try encoded.write(to: destinationURL, options: .atomic)

        let canonicalPath = canonicalPath(for: destinationURL)
        let rootPath = try resolveRegisteredRoot(for: canonicalPath)
        let relativePath = relativePath(from: canonicalPath, rootPath: rootPath)
        let rules = ArtifactDiscoveryRules(additionalPatterns: settingsProvider.artifactDiscoveryAdditionalKnownPatterns)
        guard let match = rules.match(relativePath: relativePath) else {
            throw ArtifactAuthoringError.pathDoesNotMatchKnownPatterns(relativePath)
        }
        guard match.sourceKind == sourceKind else {
            throw ArtifactAuthoringError.sourceKindMismatch(
                path: relativePath,
                expected: sourceKind,
                actual: match.sourceKind
            )
        }

        let now = nowProvider()
        let sourceID = stableSourceID(for: canonicalPath)
        let existing = try dataStore.fetchSourceArtifact(id: sourceID, includeDeleted: true)
        let attributes = try? fileManager.attributesOfItem(atPath: canonicalPath)
        let modifiedAt = attributes?[.modificationDate] as? Date
        let sizeBytes = (attributes?[.size] as? NSNumber)?.intValue ?? encoded.count
        let artifact = SourceArtifactRecord(
            id: sourceID,
            sourceKind: sourceKind,
            canonicalPath: canonicalPath,
            rootPath: rootPath,
            relativePath: relativePath,
            provenance: authoredProvenance(
                operation: operation,
                baseProvenance: match.provenance,
                references: references
            ),
            title: inferredTitle(from: markdown, fallbackPath: canonicalPath),
            body: markdown,
            contentHash: ProjectionIdentity.sha256Hex(markdown),
            fileSizeBytes: sizeBytes,
            fileModifiedAt: modifiedAt,
            status: .active,
            discoveredAt: now,
            deletedAt: nil,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )

        let disposition = try dataStore.upsertSourceArtifact(artifact)
        var queuedJobID: String?
        var projectionEnqueued = false
        switch disposition {
        case .inserted:
            queuedJobID = try enqueueProjectionJob(for: artifact, jobType: .project)
            projectionEnqueued = true
        case .updated, .restored:
            queuedJobID = try enqueueProjectionJob(for: artifact, jobType: .reproject)
            projectionEnqueued = true
        case .unchanged:
            break
        }

        return ArtifactAuthoringSaveResult(
            artifact: artifact,
            disposition: disposition,
            projectionJobEnqueued: projectionEnqueued,
            projectionJobID: queuedJobID
        )
    }

    private func generateDraft(
        sourceKind: SearchSourceKind,
        operation: ArtifactAuthoringOperation,
        request: String,
        existingMarkdown: String?,
        projectName: String?,
        retrievalQuery: String?,
        contextLimit: Int
    ) async throws -> ArtifactAuthoringDraft {
        guard sourceKind == .skillDoc || sourceKind == .agentDoc else {
            throw ArtifactAuthoringError.unsupportedSourceKind(sourceKind)
        }

        let normalizedRequest = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedRequest.isEmpty == false else {
            throw ArtifactAuthoringError.emptyRequest
        }

        let query = makeRetrievalQuery(
            explicitQuery: retrievalQuery,
            request: normalizedRequest,
            existingMarkdown: existingMarkdown
        )
        let references = await retrieveContext(
            query: query,
            projectName: projectName,
            contextLimit: contextLimit
        )
        let systemPrompt = makeSystemPrompt(sourceKind: sourceKind, operation: operation)
        let userPrompt = makeUserPrompt(
            sourceKind: sourceKind,
            operation: operation,
            request: normalizedRequest,
            projectName: projectName,
            retrievalQuery: query,
            references: references,
            existingMarkdown: existingMarkdown
        )

        let generated = try await textGenerator.generate(systemPrompt: systemPrompt, userPrompt: userPrompt)
        let now = nowProvider()
        return ArtifactAuthoringDraft(
            id: UUID().uuidString,
            sourceKind: sourceKind,
            operation: operation,
            request: normalizedRequest,
            retrievalQuery: query,
            projectName: projectName?.trimmingCharacters(in: .whitespacesAndNewlines),
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            content: generated,
            references: references,
            generatedAt: now
        )
    }

    private func retrieveContext(
        query: String,
        projectName: String?,
        contextLimit: Int
    ) async -> [ArtifactAuthoringReference] {
        let boundedContextLimit = max(1, min(contextLimit, 12))
        let trimmedProject = projectName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let filters = RetrievalFilters(
            provider: nil,
            projectName: trimmedProject?.isEmpty == true ? nil : trimmedProject,
            artifactTypes: Set(SearchSourceKind.allCases),
            dateRange: nil,
            ownership: .any,
            sourceIDs: nil,
            conversationSources: nil
        )
        let results = await retrievalService.retrieve(
            RetrievalQuery(
                text: query,
                filters: filters,
                lexicalCandidateLimit: 100,
                semanticCandidateLimit: 100,
                rerankCandidateLimit: 160,
                resultLimit: boundedContextLimit
            )
        )

        return results.enumerated().map { index, result in
            ArtifactAuthoringReference(
                rank: index + 1,
                sourceKind: result.sourceKind,
                sourceID: result.sourceID,
                documentID: result.documentID,
                chunkID: result.chunkID,
                title: result.title,
                subtitle: result.subtitle,
                projectName: result.projectName,
                sectionPath: result.sectionPath,
                snippet: condensedSnippet(result.snippet, maxCharacters: 320),
                startOffset: result.startOffset,
                endOffset: result.endOffset,
                rerankScore: result.rerankScore
            )
        }
    }

    private func makeRetrievalQuery(
        explicitQuery: String?,
        request: String,
        existingMarkdown: String?
    ) -> String {
        if let explicit = explicitQuery?.trimmingCharacters(in: .whitespacesAndNewlines), explicit.isEmpty == false {
            return explicit
        }

        if let existing = existingMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines), existing.isEmpty == false {
            let header = existing
                .split(whereSeparator: \.isNewline)
                .prefix(2)
                .map(String.init)
                .joined(separator: " ")
            if header.isEmpty == false {
                return "\(request) \(header)"
            }
        }

        return request
    }

    private func makeSystemPrompt(sourceKind: SearchSourceKind, operation: ArtifactAuthoringOperation) -> String {
        let docLabel = sourceKind == .skillDoc ? "SKILL.md" : "AGENTS.md"
        let operationVerb = operation == .draft ? "draft" : "refine"
        return """
        You are BurnBar's artifact authoring assistant.
        Produce a high-signal \(docLabel) markdown document.
        Use only supplied context references as grounding and cite them in a final "## Grounding" section using [R#] labels.
        Keep context bounded, avoid fabricated provenance, and return markdown only.
        Task mode: \(operationVerb).
        """
    }

    private func makeUserPrompt(
        sourceKind: SearchSourceKind,
        operation: ArtifactAuthoringOperation,
        request: String,
        projectName: String?,
        retrievalQuery: String,
        references: [ArtifactAuthoringReference],
        existingMarkdown: String?
    ) -> String {
        let docLabel = sourceKind == .skillDoc ? "SKILL.md" : "AGENTS.md"
        let boundedExisting = boundedText(existingMarkdown ?? "", limit: 16_000)
        var lines: [String] = []
        lines.append("Target document: \(docLabel)")
        lines.append("Operation: \(operation.rawValue)")
        lines.append("Request: \(request)")
        if let project = projectName?.trimmingCharacters(in: .whitespacesAndNewlines), project.isEmpty == false {
            lines.append("Project preference: \(project)")
        }
        lines.append("Retrieval query: \(retrievalQuery)")
        lines.append("")

        if operation == .refine {
            lines.append("Existing markdown to refine:")
            if boundedExisting.isEmpty {
                lines.append("(none provided)")
            } else {
                lines.append("```markdown")
                lines.append(boundedExisting)
                lines.append("```")
            }
            lines.append("")
        }

        lines.append("Retrieved prior-work context (\(references.count) reference(s), bounded):")
        if references.isEmpty {
            lines.append("- No references were retrieved.")
        } else {
            for reference in references {
                lines.append("[R\(reference.rank)] kind=\(reference.sourceKind.rawValue) sourceID=\(reference.sourceID)")
                lines.append("Title: \(reference.title)")
                if let subtitle = reference.subtitle, subtitle.isEmpty == false {
                    lines.append("Subtitle: \(subtitle)")
                }
                if let project = reference.projectName, project.isEmpty == false {
                    lines.append("Project: \(project)")
                }
                if let sectionPath = reference.sectionPath, sectionPath.isEmpty == false {
                    lines.append("Section: \(sectionPath)")
                }
                lines.append("Offsets: \(reference.startOffset)-\(reference.endOffset)")
                lines.append("Snippet: \(reference.snippet)")
                lines.append("")
            }
        }

        lines.append("Output rules:")
        lines.append("- Return markdown only.")
        lines.append("- Keep sections concise and operational.")
        lines.append("- Include a final `## Grounding` section that maps key claims to [R#] references.")
        lines.append("- If context is insufficient, state assumptions explicitly in the markdown.")

        return lines.joined(separator: "\n")
    }

    private func enqueueProjectionJob(for artifact: SourceArtifactRecord, jobType: ProjectionJobType) throws -> String {
        let now = nowProvider()
        let sourceVersionID = ProjectionIdentity.artifactSourceVersionID(contentHash: artifact.contentHash)
        let jobID = ProjectionIdentity.jobID(
            jobType: jobType,
            sourceKind: artifact.sourceKind,
            sourceID: artifact.id,
            sourceVersionID: sourceVersionID
        )
        let priority = jobType == .project ? 8 : 10
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
                payloadJSON: nil,
                scheduledAt: now,
                availableAt: now,
                startedAt: nil,
                completedAt: nil,
                leaseOwner: nil,
                leaseExpiresAt: nil,
                createdAt: now,
                updatedAt: now
            )
        )
        return jobID
    }

    private func resolveRegisteredRoot(for canonicalPath: String) throws -> String {
        let roots = normalizedRegisteredRoots(settingsProvider.artifactDiscoveryRegisteredRoots)
        guard roots.isEmpty == false else {
            throw ArtifactAuthoringError.noRegisteredRoots
        }
        if let match = roots
            .filter({ isWithinRoot(candidatePath: canonicalPath, rootPath: $0) })
            .max(by: { $0.count < $1.count }) {
            return match
        }
        throw ArtifactAuthoringError.pathOutsideRegisteredRoots(canonicalPath)
    }

    private func normalizedRegisteredRoots(_ roots: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for root in roots {
            let trimmed = root.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func stableSourceID(for canonicalPath: String) -> String {
        "artifact-\(ProjectionIdentity.sha256Hex(canonicalPath.lowercased()))"
    }

    private func inferredTitle(from markdown: String, fallbackPath: String) -> String {
        for line in markdown.split(whereSeparator: \.isNewline) {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("#") else { continue }
            let heading = trimmed.drop(while: { $0 == "#" || $0.isWhitespace })
            if heading.isEmpty == false {
                return String(heading)
            }
        }
        return URL(fileURLWithPath: fallbackPath).deletingPathExtension().lastPathComponent
    }

    private func authoredProvenance(
        operation: ArtifactAuthoringOperation,
        baseProvenance: String,
        references: [ArtifactAuthoringReference]
    ) -> String {
        let payload = references.map(\.sourceID).joined(separator: "|")
        let digest = payload.isEmpty ? "none" : String(ProjectionIdentity.sha256Hex(payload).prefix(12))
        return "authoring:\(operation.rawValue)|\(baseProvenance)|ctx:\(digest)"
    }

    private func boundedText(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n…"
    }

    private func condensedSnippet(_ text: String, maxCharacters: Int) -> String {
        let compact = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count > maxCharacters else { return compact }
        return String(compact.prefix(maxCharacters)) + "…"
    }
}

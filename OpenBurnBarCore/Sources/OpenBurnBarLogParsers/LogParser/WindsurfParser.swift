import Foundation
import OpenBurnBarKernel
import OpenBurnBarSQLiteReader

// MARK: - Windsurf Parser

/// Parses Windsurf (Codeium) Cascade sessions from local storage.
///
/// Windsurf stores session data in two locations:
/// - **Protobuf files**: `~/.codeium/windsurf-next/cascade/*.pb` — one per session (binary, schema undocumented)
/// - **SQLite state**: `~/Library/Application Support/Windsurf - Next/User/globalStorage/state.vscdb`
///   and per-workspace `state.vscdb` files with trajectory summaries and metadata.
///
/// Since the protobuf schema is proprietary, this parser extracts session metadata from:
/// 1. `.pb` file attributes (session ID from filename, timestamps from filesystem)
/// 2. `state.vscdb` JSON values for model/workspace info
/// 3. Heuristic token estimation based on `.pb` file size
public final class WindsurfParser: LogParser, Sendable {
    public let cascadeDirectoryOverride: String?
    public let globalStorageOverride: String?
    private let fileManager: FileManager
    private let cacheStore: ParserDiskCacheStore<CachedUsageBundleEntry<WindsurfCacheSignature>>
    private let sessionScanCount = Locked(0)
    private let sessionCacheHitCount = Locked(0)

    /// Protobuf session file plus the global `state.vscdb` (including WAL)
    /// so a model/workspace rewrite cannot reuse a cached row.
    private struct WindsurfCacheSignature: Codable, Equatable, Sendable {
        let protobuf: FileSignature
        let stateDB: FileSetSignature?
    }

    /// - Parameters:
    ///   - cascadeDirectoryOverride: Override for `~/.codeium/windsurf-next/cascade`.
    ///     On Windows the G2 harness passes the synthetic home root; otherwise the
    ///     parser resolves `~` against the real user home (POSIX `HOME` /
    ///     Windows `USERPROFILE`).
    ///   - globalStorageOverride: Override for
    ///     `~/Library/Application Support/Windsurf - Next/User/globalStorage`.
    ///     Same rationale; the macOS-only `Library/Application Support` path has no
    ///     Windows analog so the harness injects the synthetic path explicitly.
    public init(
        cascadeDirectoryOverride: String? = nil,
        globalStorageOverride: String? = nil,
        fileManager: FileManager = .default,
        appPaths: OpenBurnBarAppPaths = .live()
    ) {
        self.cascadeDirectoryOverride = cascadeDirectoryOverride
        self.globalStorageOverride = globalStorageOverride
        self.fileManager = fileManager
        let cacheURL: URL
        if let override = cascadeDirectoryOverride {
            cacheURL = URL(fileURLWithPath: override).appendingPathComponent(".obb-windsurf-parser-cache.plist")
        } else {
            cacheURL = appPaths.windsurfParserCacheURL
        }
        self.cacheStore = ParserDiskCacheStore(
            cacheURL: cacheURL,
            fileManager: fileManager,
            schemaVersion: 1,
            logLabel: "WindsurfParser"
        )
    }

    var lastSessionScanCount: Int { sessionScanCount.read() }
    var lastSessionCacheHitCount: Int { sessionCacheHitCount.read() }

    public let provider: AgentProvider = .windsurf

    // MARK: - Paths

    private func candidateCascadeDirectories() -> [String] {
        if let override = cascadeDirectoryOverride {
            return [(override as NSString).expandingTildeInPath]
        }
        return [
            ("~/.codeium/windsurf-next/cascade" as NSString).expandingTildeInPath,
            ("~/.codeium/windsurf/cascade" as NSString).expandingTildeInPath
        ]
    }

    private func candidateGlobalStoragePaths() -> [String] {
        if let override = globalStorageOverride {
            return [(override as NSString).expandingTildeInPath]
        }
        return [
            ("~/Library/Application Support/Windsurf - Next/User/globalStorage" as NSString).expandingTildeInPath,
            ("~/Library/Application Support/Windsurf/User/globalStorage" as NSString).expandingTildeInPath,
            ("~/.config/Windsurf - Next/User/globalStorage" as NSString).expandingTildeInPath,
            ("~/.config/Windsurf/User/globalStorage" as NSString).expandingTildeInPath
        ]
    }

    private static let cascadeDirectory = "~/.codeium/windsurf-next/cascade"
    private static let globalStoragePath = "~/Library/Application Support/Windsurf - Next/User/globalStorage"
    private static let workspaceStoragePath = "~/Library/Application Support/Windsurf - Next/User/workspaceStorage"

    // MARK: - Estimation Constants

    /// Average bytes per token in protobuf-encoded Cascade data.
    /// Protobuf is compact; a typical Cascade session with 50k tokens is ~800KB.
    private static let estimatedBytesPerToken: Double = 16.0

    /// Typical input/output ratio for agentic sessions (more input than output).
    private static let inputOutputRatio: Double = 3.0

    // MARK: - Parse

    public func parse() async throws -> ParseResult {
        try await parse(options: .default)
    }

    public func parse(options: LogParseOptions) async throws -> ParseResult {
        sessionScanCount.write(0)
        sessionCacheHitCount.write(0)
        let gate = ParserFileReadGate(options: options, fileManager: fileManager)
        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []
        var parseCache = cacheStore.load()
        var activePaths = Set<String>()
        var cacheMutated = false
        defer {
            if cacheMutated {
                cacheStore.persist(parseCache)
            }
        }

        let primaryGlobalPath = candidateGlobalStoragePaths().first(where: { fileManager.fileExists(atPath: $0) })
            ?? ((globalStorageOverride ?? Self.globalStoragePath) as NSString).expandingTildeInPath
        let stateDBURL = URL(fileURLWithPath: (primaryGlobalPath as NSString).appendingPathComponent("state.vscdb"))
        let stateDBSignature = FileSetSignature(databaseURL: stateDBURL, using: fileManager)
        let stateDBWasCached = Self.stateDBCache.withLock {
            $0.entriesByDBPath[stateDBURL.path]?.signature == stateDBSignature && $0.entriesByDBPath[stateDBURL.path] != nil
        }
        let canReadStateDB: Bool
        if stateDBWasCached {
            canReadStateDB = true
        } else if fileManager.fileExists(atPath: stateDBURL.path) {
            canReadStateDB = try gate.shouldRead(stateDBURL)
        } else {
            canReadStateDB = false
        }

        for cascadeDir in candidateCascadeDirectories() {
            guard fileManager.fileExists(atPath: cascadeDir) else { continue }
            let cascadeURL = URL(fileURLWithPath: cascadeDir, isDirectory: true)
            let allFiles = (try? fileManager.contentsOfDirectory(
                at: cascadeURL,
                includingPropertiesForKeys: [
                    .fileSizeKey,
                    .contentModificationDateKey,
                    .creationDateKey,
                    .isRegularFileKey
                ]
            )) ?? []
            let pbFiles = allFiles.filter { $0.pathExtension.lowercased() == "pb" }

            for pbURL in pbFiles {
                try options.resourceGovernor?.checkpoint()
                options.metrics?.recordCandidate()
                options.metrics?.recordMetadataStat()
                let cacheKey = pbURL.standardizedFileURL.path
                activePaths.insert(cacheKey)
                let sessionId = pbURL.deletingPathExtension().lastPathComponent

                let values = try? pbURL.resourceValues(forKeys: [
                    .fileSizeKey,
                    .contentModificationDateKey,
                    .creationDateKey,
                    .isRegularFileKey
                ])
                guard let values, values.isRegularFile == true else {
                    options.resourceGovernor?.recordDeferredFile()
                    options.metrics?.recordDeferred(.metadataUnavailable)
                    continue
                }
                let created = values.creationDate ?? Date()
                let modified = values.contentModificationDate ?? created
                let fileSize = values.fileSize ?? 0
                let attrs: [FileAttributeKey: Any] = [
                    .size: fileSize,
                    .modificationDate: modified,
                    .creationDate: created
                ]
                let discoveredFile = ParserDiscoveredFile.capture(
                    for: pbURL,
                    attributes: attrs
                )
                let isNewlyDiscovered = options.fileDiscoveryTracker?.record(discoveredFile) ?? false

                guard fileSize > 100 else { continue }
                if let cutoff = options.minimumFileModificationDate,
                   modified < cutoff,
                   !isNewlyDiscovered {
                    continue
                }
                options.fileDiscoveryTracker?.recordAdmitted(discoveredFile)

                let protobufSignature = FileSignature(resourceValues: values)
                let signature = protobufSignature.map {
                    WindsurfCacheSignature(protobuf: $0, stateDB: stateDBSignature)
                }
                if !options.includeConversationBodies,
                   let signature,
                   let cached = parseCache.fileEntries[cacheKey],
                   cached.signature == signature {
                    sessionCacheHitCount.withLock { $0 += 1 }
                    usages.append(contentsOf: cached.sessions.map { $0.makeUsage(provider: .windsurf) })
                    continue
                }

                sessionScanCount.withLock { $0 += 1 }
                let model = canReadStateDB ? (extractModelFromStateDB(sessionId: sessionId) ?? "unknown") : "unknown"

                let estimatedTotalTokens = Int(Double(fileSize) / Self.estimatedBytesPerToken)
                let inputTokens = Int(Double(estimatedTotalTokens) * Self.inputOutputRatio / (Self.inputOutputRatio + 1.0))
                let outputTokens = estimatedTotalTokens - inputTokens

                let pricing = ModelPricing.lookup(model: model)
                let cost = try pricing.cost(
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheCreationTokens: 0,
                    cacheReadTokens: 0
                )

                let projectName = canReadStateDB ? (extractWorkspaceName(sessionId: sessionId) ?? sessionId) : sessionId
                let usage = TokenUsage(
                    provider: provider,
                    sessionId: sessionId,
                    projectName: projectName,
                    model: model,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheCreationTokens: 0,
                    cacheReadTokens: 0,
                    costUSD: cost,
                    startTime: created,
                    endTime: modified,
                    provenanceMethod: .heuristicEstimate,
                    provenanceConfidence: .lowConfidenceEstimate,
                    estimatorVersion: "windsurf-v1"
                )
                usages.append(usage)
                if let signature {
                    parseCache.fileEntries[cacheKey] = CachedUsageBundleEntry(
                        signature: signature,
                        usages: [usage]
                    )
                    cacheMutated = true
                }

                if options.includeConversationBodies,
                   options.fileDiscoveryTracker == nil || isNewlyDiscovered {
                    let title = canReadStateDB ? (extractSessionTitle(sessionId: sessionId) ?? "Windsurf Cascade Session") : "Windsurf Cascade Session"
                    conversations.append(ConversationRecord(
                        id: ConversationRecord.stableId(provider: provider, sessionId: sessionId),
                        provider: provider,
                        sessionId: sessionId,
                        projectName: usage.projectName,
                        startTime: created,
                        endTime: modified,
                        messageCount: 0,
                        userWordCount: 0,
                        assistantWordCount: 0,
                        keyFiles: [],
                        keyCommands: [],
                        keyTools: [],
                        inferredTaskTitle: title,
                        lastAssistantMessage: "",
                        fullText: "",
                        indexedAt: Date(),
                        fileModifiedAt: modified,
                        summary: nil
                    ))
                }
            }
        }

        let stalePaths = Set(parseCache.fileEntries.keys).subtracting(activePaths)
        if !stalePaths.isEmpty {
            for stalePath in stalePaths {
                parseCache.fileEntries.removeValue(forKey: stalePath)
            }
            cacheMutated = true
        }

        return ParseResult(usages: usages, conversations: conversations)
    }

    // MARK: - State DB Helpers

    /// Cached model/workspace lookups from state.vscdb.
    private struct StateDBCache {
        var entriesByDBPath: [String: Cached] = [:]

        struct Cached {
            var signature: FileSetSignature?
            var entry: Entry
        }

        struct Entry {
            var models: [String: String]
            var workspaces: [String: String]
            var titles: [String: String]
        }
    }
    private static let stateDBCache = Locked(StateDBCache())

    private func extractModelFromStateDB(sessionId: String) -> String? {
        let entry = ensureStateDBCache()
        return entry.models[sessionId]
    }

    private func extractWorkspaceName(sessionId: String) -> String? {
        let entry = ensureStateDBCache()
        return entry.workspaces[sessionId]
    }

    private func extractSessionTitle(sessionId: String) -> String? {
        let entry = ensureStateDBCache()
        return entry.titles[sessionId]
    }

    private func ensureStateDBCache() -> StateDBCache.Entry {
        for globalPath in candidateGlobalStoragePaths() {
            let dbPath = (globalPath as NSString).appendingPathComponent("state.vscdb")
            guard fileManager.fileExists(atPath: dbPath) else { continue }
            let dbURL = URL(fileURLWithPath: dbPath)
            let signature = FileSetSignature(databaseURL: dbURL, using: fileManager)
            if let cached = Self.stateDBCache.withLock({
                $0.entriesByDBPath[dbPath]
            }), cached.signature == signature {
                return cached.entry
            }

            var models: [String: String] = [:]
            var workspaces: [String: String] = [:]
            var titles: [String: String] = [:]

            _ = readStateDBKeys(atPath: dbPath, models: &models, workspaces: &workspaces, titles: &titles)

            let entry = StateDBCache.Entry(models: models, workspaces: workspaces, titles: titles)
            return Self.stateDBCache.withLock {
                if let cached = $0.entriesByDBPath[dbPath], cached.signature == signature {
                    return cached.entry
                }
                $0.entriesByDBPath[dbPath] = StateDBCache.Cached(signature: signature, entry: entry)
                return entry
            }
        }
        return StateDBCache.Entry(models: [:], workspaces: [:], titles: [:])
    }

    /// Reads the `codeium.windsurf` key from a state.vscdb and extracts trajectory metadata.
    private func readStateDBKeys(
        atPath dbPath: String,
        models: inout [String: String],
        workspaces: inout [String: String],
        titles: inout [String: String]
    ) -> Bool {
        let reader: SQLiteConnection
        do {
            reader = try SQLiteConnection.openReadOnly(path: dbPath)
        } catch {
            return false
        }
        defer { reader.close() }

        let rows: [SQLiteRow]
        do {
            rows = try reader.query(
                "SELECT value FROM ItemTable WHERE key = ?",
                arguments: [.text("codeium.windsurf")]
            )
        } catch {
            return false
        }

        guard let valueString = rows.first?.string("value") else { return false }
        guard let jsonData = valueString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { // try?-ok(parse 3rd-party JSON)
            return false
        }

        // Extract trajectory summaries and workspace info
        for (key, value) in json {
            guard key.hasPrefix("windsurf.state.cachedTrajectorySummaries:") else { continue }
            guard let trajectoryData = value as? String,
                  let data = Data(base64Encoded: trajectoryData) else { continue }

            // Try to extract readable strings from the protobuf-encoded data
            let rawStrings = extractStringsFromProtobuf(data: data)

            // The protobuf contains: session title, cascade ID, model name (e.g. "MODEL_GPT_5_2_LOW")
            // Look for model identifiers
            let modelString = rawStrings.first(where: { $0.hasPrefix("MODEL_") }) ?? "unknown"
            let normalizedModel = Self.normalizeWindsurfModel(modelString)

            // Extract workspace path from the corresponding workspace info key
            let workspaceKey = "windsurf.state.cachedWorkspaceInfosResponse:" + key
                .replacingOccurrences(of: "windsurf.state.cachedTrajectorySummaries:", with: "")
            if let workspaceValue = json[workspaceKey] as? String,
               let wsData = Data(base64Encoded: workspaceValue) {
                let wsStrings = extractStringsFromProtobuf(data: wsData)
                // Workspace info contains file:// paths
                if let path = wsStrings.first(where: { $0.hasPrefix("file://") }) {
                    let workspaceName = URL(string: path)?.lastPathComponent ?? path
                    // Map all cascade IDs found to this workspace
                    for id in rawStrings where id.count == 36 && id.contains("-") {
                        workspaces[id] = workspaceName
                    }
                }
            }

            // Map cascade IDs to models and titles
            for id in rawStrings where id.count == 36 && id.contains("-") {
                models[id] = normalizedModel
            }

            // First non-UUID, non-MODEL_ string is likely the title
            if let title = rawStrings.first(where: { !$0.hasPrefix("MODEL_") && $0.count > 5 && !$0.contains("-") && $0.count != 36 }) {
                for id in rawStrings where id.count == 36 && id.contains("-") {
                    titles[id] = title
                }
            }
        }

        return true
    }

    // MARK: - Protobuf String Extraction

    /// Extracts readable UTF-8 strings from raw protobuf data.
    /// Works by scanning for length-delimited string fields.
    private func extractStringsFromProtobuf(data: Data) -> [String] {
        var strings: [String] = []
        var i = 0

        while i < data.count {
            // Try to read a string starting at this position
            if let (length, string) = tryReadProtobufString(data: data, offset: i) {
                if length > 3 { // Skip very short strings
                    strings.append(string)
                }
                i += length
            } else {
                i += 1
            }
        }

        return strings
    }

    /// Attempts to read a protobuf length-delimited string at the given offset.
    private func tryReadProtobufString(data: Data, offset: Int) -> (length: Int, string: String)? {
        guard offset < data.count - 1 else { return nil }

        // Look for a varint length followed by valid UTF-8 bytes
        let (varintValue, varintLength) = readVarint(data: data, offset: offset)
        guard varintLength > 0,
              varintValue > 3, // minimum useful string length
              varintValue < 10000, // reasonable max
              offset + varintLength + Int(varintValue) <= data.count else {
            return nil
        }

        let stringStart = offset + varintLength
        let stringData = data[stringStart..<stringStart + Int(varintValue)]

        guard let string = String(data: stringData, encoding: .utf8),
              string.count == varintValue, // no partial UTF-8
              string.allSatisfy({ $0.isPrintable || $0.isNewline || $0 == "\t" }) else {
            return nil
        }

        return (varintLength + Int(varintValue), string)
    }

    /// Reads a protobuf varint at the given offset.
    private func readVarint(data: Data, offset: Int) -> (value: UInt64, length: Int) {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var i = offset

        while i < data.count {
            let byte = data[i]
            value |= UInt64(byte & 0x7F) << shift
            i += 1
            if byte & 0x80 == 0 {
                return (value, i - offset)
            }
            shift += 7
            if shift > 63 { break }
        }

        return (0, 0)
    }

    // MARK: - Model Normalization

    /// Normalizes Windsurf model identifiers to human-readable names.
    private static func normalizeWindsurfModel(_ model: String) -> String {
        // Windsurf uses identifiers like "MODEL_GPT_5_2_LOW", "gemini-3-1-pro-high"
        let lower = model.lowercased()
            .replacingOccurrences(of: "model_", with: "")

        if lower.contains("claude") || lower.contains("anthropic") {
            if lower.contains("opus") { return "Claude Opus" }
            if lower.contains("sonnet") { return "Claude Sonnet" }
            if lower.contains("haiku") { return "Claude Haiku" }
            return "Claude"
        }
        if lower.contains("gpt") || lower.contains("openai") {
            if lower.contains("4.5") || lower.contains("4_5") { return "GPT-4.5" }
            if lower.contains("5") { return "GPT-5" }
            if lower.contains("4o") { return "GPT-4o" }
            return "GPT"
        }
        if lower.contains("gemini") {
            if lower.contains("2.5") || lower.contains("2_5") { return "Gemini 2.5" }
            if lower.contains("3") { return "Gemini 3" }
            return "Gemini"
        }
        if lower.contains("deepseek") { return "DeepSeek" }
        if lower.contains("o1") { return "o1" }
        if lower.contains("o3") { return "o3" }
        if lower.contains("o4") { return "o4" }
        if lower.contains("swe") { return "SWE-1.5" }

        return model
    }
}

// MARK: - Character Helpers

private extension Character {
    var isPrintable: Bool {
        let printable = CharacterSet(charactersIn: " ")
            .union(.alphanumerics)
            .union(.punctuationCharacters)
            .union(.symbols)
        return unicodeScalars.allSatisfy { printable.contains($0) }
    }
}

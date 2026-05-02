import Foundation
import OpenBurnBarCore
import SQLite3

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
final class WindsurfParser: LogParser, Sendable {
    let provider: AgentProvider = .windsurf

    // MARK: - Paths

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

    func parse() async throws -> ParseResult {
        let fm = FileManager.default
        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        // 1. Parse .pb files from cascade directory
        let cascadeDir = (Self.cascadeDirectory as NSString).expandingTildeInPath
        if fm.fileExists(atPath: cascadeDir) {
            let allFiles = (try? fm.contentsOfDirectory(atPath: cascadeDir)) ?? []
            let pbFiles = allFiles
                .filter { $0.hasSuffix(".pb") }
                .map { (cascadeDir as NSString).appendingPathComponent($0) }

            for pbFile in pbFiles {
                let sessionId = (pbFile as NSString).deletingPathExtension
                    .components(separatedBy: "/").last ?? UUID().uuidString

                let attrs = try? fm.attributesOfItem(atPath: pbFile)
                let created = (attrs?[.creationDate] as? Date) ?? Date()
                let modified = (attrs?[.modificationDate] as? Date) ?? created
                let fileSize = (attrs?[.size] as? Int) ?? 0

                guard fileSize > 100 else { continue }

                let model = extractModelFromStateDB(sessionId: sessionId) ?? "unknown"

                let estimatedTotalTokens = Int(Double(fileSize) / Self.estimatedBytesPerToken)
                let inputTokens = Int(Double(estimatedTotalTokens) * Self.inputOutputRatio / (Self.inputOutputRatio + 1.0))
                let outputTokens = estimatedTotalTokens - inputTokens

                let pricing = ModelPricing.lookup(model: model)
                let cost = pricing.cost(
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheCreationTokens: 0,
                    cacheReadTokens: 0
                )

                let usage = TokenUsage(
                    provider: provider,
                    sessionId: sessionId,
                    projectName: extractWorkspaceName(sessionId: sessionId) ?? sessionId,
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

                let conversation = ConversationRecord(
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
                    inferredTaskTitle: extractSessionTitle(sessionId: sessionId) ?? "Windsurf Cascade Session",
                    lastAssistantMessage: "",
                    fullText: "",
                    indexedAt: Date(),
                    fileModifiedAt: modified,
                    summary: nil
                )
                conversations.append(conversation)
            }
        }

        return ParseResult(usages: usages, conversations: conversations)
    }

    // MARK: - State DB Helpers

    /// Cached model/workspace lookups from state.vscdb.
    private struct StateDBCache {
        var models: [String: String]?
        var workspaces: [String: String]?
        var titles: [String: String]?
    }
    private static let stateDBCache = Locked(StateDBCache())

    private func extractModelFromStateDB(sessionId: String) -> String? {
        ensureStateDBCache()
        return Self.stateDBCache.withLock { $0.models?[sessionId] }
    }

    private func extractWorkspaceName(sessionId: String) -> String? {
        ensureStateDBCache()
        return Self.stateDBCache.withLock { $0.workspaces?[sessionId] }
    }

    private func extractSessionTitle(sessionId: String) -> String? {
        ensureStateDBCache()
        return Self.stateDBCache.withLock { $0.titles?[sessionId] }
    }

    private func ensureStateDBCache() {
        let alreadyCached = Self.stateDBCache.withLock { $0.models != nil }
        if alreadyCached { return }

        var models: [String: String] = [:]
        var workspaces: [String: String] = [:]
        var titles: [String: String] = [:]

        let globalPath = (Self.globalStoragePath as NSString).expandingTildeInPath
        let dbPath = (globalPath as NSString).appendingPathComponent("state.vscdb")

        if FileManager.default.fileExists(atPath: dbPath) {
            _ = readStateDBKeys(atPath: dbPath, models: &models, workspaces: &workspaces, titles: &titles)
        }

        Self.stateDBCache.withLock {
            $0.models = models
            $0.workspaces = workspaces
            $0.titles = titles
        }
    }

    /// Reads the `codeium.windsurf` key from a state.vscdb and extracts trajectory metadata.
    private func readStateDBKeys(
        atPath dbPath: String,
        models: inout [String: String],
        workspaces: inout [String: String],
        titles: inout [String: String]
    ) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else { return false }
        defer { sqlite3_close(db) }

        let query = "SELECT value FROM ItemTable WHERE key = 'codeium.windsurf';"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let valuePtr = sqlite3_column_text(stmt, 0) else { return false }

        let valueString = String(cString: valuePtr)
        guard let jsonData = valueString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
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

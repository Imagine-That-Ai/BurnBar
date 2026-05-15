import Foundation
import FirebaseFirestore
import OpenBurnBarCore

// MARK: - Mobile Tool Catalog
//
// Tool-calling support for the mobile Hermes/Pi chat surfaces. The catalog is
// the single source of truth for which tools the iOS app advertises to the
// upstream LLM in `/v1/chat/completions` requests. Each tool is a small,
// strongly-typed unit that:
//
//   1. Publishes an OpenAI-compatible "function" descriptor (name + JSON
//      Schema for arguments) consumed by the upstream model.
//   2. Decodes streamed `tool_call.arguments` JSON, executes against the
//      on-device app surface, and returns a short textual result.
//
// The catalog itself is stateless; per-tool state lives behind a
// `MobileToolContext`. Adding a new tool means writing a single struct that
// conforms to `MobileTool` and registering it in
// `MobileToolCatalog.default.tools` (or a custom builder for tests).

// MARK: - Result + Error Types

/// Outcome of a single tool invocation. The textual `content` is what
/// becomes the body of the `role: "tool"` message we send back to the
/// upstream model so it can produce the final natural-language reply.
///
/// Errors are *never* thrown across the tool-call boundary; they are
/// folded into `content` (with `isError = true`) so the model can see
/// the failure, apologize, and try a different approach.
public struct MobileToolExecutionResult: Sendable, Equatable {
    /// The `tool_call_id` echoed back to the model. Must match the call
    /// id the model emitted so the API can pair request and response.
    public let toolCallID: String
    /// Tool name (for logging + UI summary).
    public let toolName: String
    /// Whether the tool itself reported a failure. We still emit a
    /// `role: "tool"` message — the model needs to see the error to
    /// respond intelligently.
    public let isError: Bool
    /// Plain text or compact JSON sent back to the model. Capped at
    /// `MobileToolExecutionResult.maxContentBytes` UTF-8 bytes by
    /// `truncatedForWire(_:)` before transmission.
    public let content: String

    public init(toolCallID: String, toolName: String, isError: Bool, content: String) {
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.isError = isError
        self.content = content
    }

    /// Wire-safe ceiling for tool result bodies. Keeps a single tool
    /// invocation from blowing through the context window. Matches the
    /// 16 KB convention used by most OpenAI-compatible relays.
    public static let maxContentBytes = 16 * 1024

    /// Trim a body to `maxContentBytes` UTF-8 bytes, preserving the head
    /// and signalling truncation so the model can ask for more.
    public static func truncatedForWire(_ text: String) -> String {
        let bytes = text.utf8.count
        guard bytes > maxContentBytes else { return text }
        let head = text.prefix(maxContentBytes - 64)
        return "\(head)\n[…tool output truncated…]"
    }
}

/// Errors raised inside a tool's `execute(...)`. Always converted to a
/// textual error body before being sent back to the model — the model
/// never sees Swift error objects, only readable strings.
public enum MobileToolError: Error, Equatable, Sendable, LocalizedError {
    /// JSON arguments couldn't be decoded into the expected shape.
    case invalidArguments(String)
    /// Tool name didn't match any registered tool.
    case unknownTool(String)
    /// Tool was disabled at request time (user preference, runtime gate, …).
    case toolDisabled(String)
    /// Tool ran but failed to fulfil the request.
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArguments(let message): return "Invalid arguments: \(message)"
        case .unknownTool(let name):         return "Unknown tool: \(name)"
        case .toolDisabled(let name):        return "Tool disabled: \(name)"
        case .executionFailed(let message):  return message
        }
    }

    /// JSON body the model sees when a tool fails. The shape is
    /// deliberately small and predictable so the model can pattern-match
    /// on it across providers.
    public var wireContent: String {
        let payload: [String: Any] = [
            "error": errorDescription ?? "tool failed"
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "{\"error\":\"tool failed\"}"
    }
}

// MARK: - Tool Protocol

/// One tool the iOS app makes available to an upstream LLM. Each tool is a
/// small value type with a stable name, a JSON Schema descriptor, and a
/// `@MainActor async` execute method that runs on-device.
///
/// Tools must be `Sendable` so they can be safely held by the catalog
/// (which the service captures across async boundaries). Implementations
/// keep no mutable state — they read from `MobileToolContext`.
@MainActor
public protocol MobileTool: Sendable {
    /// Stable identifier used as the `function.name` in the OpenAI tool
    /// descriptor and matched against streamed `tool_calls[].function.name`.
    /// Conventionally lower_snake_case and prefixed with `burnbar_` so it
    /// doesn't collide with any tools the upstream server adds on its own.
    static var name: String { get }

    /// Short one-line label shown in the iOS tool pill detail. Falls back
    /// to a derived summary of the arguments when nil.
    var displayName: String { get }

    /// One-paragraph description the model sees as `function.description`.
    /// Keep it specific: include when to use, when not to use, expected
    /// outcome.
    var description: String { get }

    /// JSON Schema describing `function.parameters`. Used verbatim in the
    /// wire-format tools array. Use `MobileToolJSONSchema` helpers to keep
    /// schemas consistent across tools.
    var parametersSchema: [String: Any] { get }

    /// Decode the streamed arguments JSON and run the tool. Always returns
    /// a `String` body suitable for a `role: "tool"` message. Throws only
    /// when the failure should be folded into a structured error body —
    /// the caller catches and forwards via `MobileToolError.wireContent`.
    func execute(
        arguments: String,
        context: any MobileToolContext
    ) async throws -> String
}

public extension MobileTool {
    /// OpenAI-compatible function descriptor for `tools: [...]`. Defaults
    /// to `function`-typed; override in a tool to produce a different
    /// schema family later (e.g. Anthropic-style) without touching the
    /// service layer.
    var descriptor: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": Self.name,
                "description": description,
                "parameters": parametersSchema
            ] as [String: Any]
        ]
    }

    /// Convenience for tools that want to read a single string argument
    /// from a JSON body. Returns `nil` when the key is missing or empty;
    /// throws `.invalidArguments` when the JSON itself doesn't parse.
    func stringArgument(_ key: String, in arguments: String) throws -> String? {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data, options: []))
                as? [String: Any] else {
            throw MobileToolError.invalidArguments(
                "expected a JSON object, got \(trimmed.prefix(80))"
            )
        }
        guard let raw = object[key] as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

// MARK: - Catalog

/// Read-only registry of mobile-side tools. Constructed once at startup
/// and held by `HermesService` / `PiService`. Use `.default` for the
/// canonical production set; pass a custom catalog from tests to inject
/// fakes.
public struct MobileToolCatalog: Sendable {
    public let tools: [any MobileTool]

    public init(tools: [any MobileTool]) {
        self.tools = tools
    }

    /// Wire-format `tools` array suitable for inclusion in an OpenAI
    /// `/v1/chat/completions` request body. Empty when the catalog has
    /// no tools — in that case callers should omit the `tools` key from
    /// the request entirely so they don't surprise providers that reject
    /// empty arrays.
    @MainActor
    public func toolsWireArray() -> [[String: Any]] {
        tools.map { $0.descriptor }
    }

    /// Look up a tool by its emitted `function.name`. The match is
    /// case-sensitive — names are user-defined identifiers and shouldn't
    /// rely on case-insensitive fuzzing.
    @MainActor
    public func tool(named name: String) -> (any MobileTool)? {
        tools.first { type(of: $0).name == name }
    }

    /// Canonical production catalog. Order is not load-bearing for the
    /// model, but is preserved when serialized so logs/tests are stable.
    @MainActor
    public static let `default` = MobileToolCatalog(tools: [
        BurnBarAtomOpenTool(),
        BurnBarHermesSessionsTool(),
        BurnBarProjectMemoryListTool(),
        BurnBarProjectMemoryWikiTool(),
        BurnBarRuntimeStatusTool()
    ])
}

// MARK: - Tool Context

/// Read-only surface tools use to reach app state. Implemented by the
/// chat service (`HermesService` / `PiService`) so tools never import
/// the service concretely and stay portable.
@MainActor
public protocol MobileToolContext: AnyObject, Sendable {
    /// Navigator used by `burnbar_atom_open` to drive the chat-surface
    /// detail sheet. `nil` when the host hasn't installed a router (e.g.
    /// previews / tests that don't care about navigation).
    var atomNavigator: HermesAtomNavigator? { get }

    /// Recent sessions surfaced by the assistant runtime (Hermes or Pi).
    /// Returns a stable snapshot; tools never mutate the list.
    var availableSessions: [MobileToolSessionSummary] { get }

    /// Connection / runtime status summary used by
    /// `burnbar_runtime_status`. Lightweight value-type snapshot so the
    /// tool doesn't hold references back into the service.
    var runtimeStatusSnapshot: MobileToolRuntimeStatus { get }

    /// Provider used by project-memory tools to list projects and load
    /// wiki snapshots.
    var projectMemoryProvider: any MobileProjectMemoryProviding { get }
}

public extension MobileToolContext {
    var projectMemoryProvider: any MobileProjectMemoryProviding {
        MobileProjectMemoryProvider.shared
    }
}

/// Lightweight session summary the catalog can serialize back to the
/// model without exposing the full `HermesSessionSummary` surface.
public struct MobileToolSessionSummary: Sendable, Equatable, Codable {
    public let id: String
    public let title: String?
    public let preview: String?
    public let model: String?
    public let messageCount: Int
    public let toolCallCount: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let lastActiveAt: Date?

    public init(
        id: String,
        title: String?,
        preview: String?,
        model: String?,
        messageCount: Int,
        toolCallCount: Int,
        inputTokens: Int,
        outputTokens: Int,
        lastActiveAt: Date?
    ) {
        self.id = id
        self.title = title
        self.preview = preview
        self.model = model
        self.messageCount = messageCount
        self.toolCallCount = toolCallCount
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.lastActiveAt = lastActiveAt
    }
}

/// Snapshot of the chat runtime the user is currently talking to. Fed to
/// the model by `burnbar_runtime_status` so it can answer "are you
/// online?" / "what model are you running?" honestly.
public struct MobileToolRuntimeStatus: Sendable, Equatable, Codable {
    public let runtime: String
    public let isReachable: Bool
    public let connectionName: String?
    public let connectionMode: String?
    public let selectedModelID: String?
    public let advertisedModel: String?
    public let lastError: String?

    public init(
        runtime: String,
        isReachable: Bool,
        connectionName: String?,
        connectionMode: String?,
        selectedModelID: String?,
        advertisedModel: String?,
        lastError: String?
    ) {
        self.runtime = runtime
        self.isReachable = isReachable
        self.connectionName = connectionName
        self.connectionMode = connectionMode
        self.selectedModelID = selectedModelID
        self.advertisedModel = advertisedModel
        self.lastError = lastError
    }
}

// MARK: - Project Memory Models

public enum MobileProjectMemoryFreshness: String, Sendable, Equatable, Codable {
    case fresh
    case needsRefresh = "needs_refresh"
    case stale

    public var displayLabel: String {
        switch self {
        case .fresh: return "Fresh"
        case .needsRefresh: return "Needs refresh"
        case .stale: return "Stale"
        }
    }

    static func from(lastSeen: Date, now: Date = Date()) -> MobileProjectMemoryFreshness {
        let age = now.timeIntervalSince(lastSeen)
        if age <= 6 * 3600 { return .fresh }
        if age <= 48 * 3600 { return .needsRefresh }
        return .stale
    }
}

public struct MobileProjectMemoryCitation: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let sessionID: String
    public let model: String
    public let provider: String
    public let observedAt: Date
    public let note: String

    public init(
        id: String,
        sessionID: String,
        model: String,
        provider: String,
        observedAt: Date,
        note: String
    ) {
        self.id = id
        self.sessionID = sessionID
        self.model = model
        self.provider = provider
        self.observedAt = observedAt
        self.note = note
    }
}

public struct MobileProjectMemorySection: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let title: String
    public let body: String
    public let citations: [MobileProjectMemoryCitation]

    public init(
        id: String,
        title: String,
        body: String,
        citations: [MobileProjectMemoryCitation]
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.citations = citations
    }

    public var citationCount: Int { citations.count }
}

public enum MobileProjectMemoryVisualKind: String, Sendable, Equatable, Codable {
    case bar
    case timeline
}

public struct MobileProjectMemoryVisualPoint: Sendable, Equatable, Codable {
    public let label: String
    public let value: Double
    public let display: String

    public init(label: String, value: Double, display: String) {
        self.label = label
        self.value = value
        self.display = display
    }
}

public struct MobileProjectMemoryVisual: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let kind: MobileProjectMemoryVisualKind
    public let points: [MobileProjectMemoryVisualPoint]

    public init(
        id: String,
        title: String,
        subtitle: String,
        kind: MobileProjectMemoryVisualKind,
        points: [MobileProjectMemoryVisualPoint]
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
        self.points = points
    }
}

public struct MobileProjectMemorySnapshot: Sendable, Equatable, Codable {
    public let projectID: String
    public let projectName: String
    public let summary: String
    public let generatedAt: Date
    public let freshness: MobileProjectMemoryFreshness
    public let sections: [MobileProjectMemorySection]
    public let visuals: [MobileProjectMemoryVisual]
    public let sourceSessionCount: Int
    public let sourceTokenTotal: Int
    public let sourceCostTotal: Double

    public init(
        projectID: String,
        projectName: String,
        summary: String,
        generatedAt: Date,
        freshness: MobileProjectMemoryFreshness,
        sections: [MobileProjectMemorySection],
        visuals: [MobileProjectMemoryVisual],
        sourceSessionCount: Int,
        sourceTokenTotal: Int,
        sourceCostTotal: Double
    ) {
        self.projectID = projectID
        self.projectName = projectName
        self.summary = summary
        self.generatedAt = generatedAt
        self.freshness = freshness
        self.sections = sections
        self.visuals = visuals
        self.sourceSessionCount = sourceSessionCount
        self.sourceTokenTotal = sourceTokenTotal
        self.sourceCostTotal = sourceCostTotal
    }

    public var freshnessLabel: String { freshness.displayLabel }

    static func build(
        project: ProjectSummary,
        sessions: [TokenUsage],
        focusQuestion: String? = nil,
        now: Date = Date()
    ) -> MobileProjectMemorySnapshot {
        let sortedSessions = sessions.sorted { $0.startTime > $1.startTime }
        let sourceSessionCount = max(project.sessions, Set(sortedSessions.map(\.sessionId)).count)
        let sourceTokenTotal = sortedSessions.isEmpty
            ? project.totalTokens
            : sortedSessions.reduce(0) { $0 + $1.totalTokens }
        let sourceCostTotal = sortedSessions.isEmpty
            ? project.totalCost
            : sortedSessions.reduce(0) { $0 + $1.cost }
        let summary = "\(sourceSessionCount) sessions · \(sourceTokenTotal.formatAsTokenVolume()) tokens · \(sourceCostTotal.formatAsCost())"

        let recentSessions = Array(sortedSessions.prefix(5))
        let recentSection = MobileProjectMemorySection(
            id: "recent-work",
            title: "Recent agent work",
            body: recentSessions.isEmpty
                ? "No session evidence is currently cached for this project."
                : recentSessions.enumerated().map { idx, session in
                    let stamp = session.startTime.formatted(date: .abbreviated, time: .shortened)
                    return "\(idx + 1). \(session.model) · \(session.cost.formatAsCost()) · \(session.totalTokens.formatAsTokenVolume()) · \(stamp)"
                }.joined(separator: "\n"),
            citations: citations(from: recentSessions, limit: 5)
        )

        var modelBuckets: [String: Int] = [:]
        var providerBuckets: [String: Double] = [:]
        for session in sortedSessions {
            modelBuckets[session.model, default: 0] += session.totalTokens
            providerBuckets[session.provider.displayName, default: 0] += session.cost
        }
        let topModels = modelBuckets.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }
        let modelSection = MobileProjectMemorySection(
            id: "model-decisions",
            title: "Model decisions",
            body: topModels.isEmpty
                ? "No model routing evidence is available yet."
                : topModels.prefix(6).enumerated().map { idx, entry in
                    "\(idx + 1). \(entry.key) · \(entry.value.formatAsTokenVolume())"
                }.joined(separator: "\n"),
            citations: citations(
                from: sortedSessions.filter { session in
                    topModels.prefix(3).contains(where: { $0.key == session.model })
                },
                limit: 4
            )
        )

        let averageCost = sortedSessions.isEmpty
            ? 0
            : sortedSessions.reduce(0) { $0 + $1.cost } / Double(sortedSessions.count)
        let riskSessions = sortedSessions.filter { $0.cost > max(averageCost * 1.8, 0.03) }
        let riskSection = MobileProjectMemorySection(
            id: "risks",
            title: "Open risks",
            body: riskSessions.isEmpty
                ? "No unusual spend spikes detected in the current evidence window."
                : riskSessions.prefix(4).map { session in
                    "\(session.model) spiked to \(session.cost.formatAsCost()) on \(session.startTime.formatted(date: .abbreviated, time: .shortened))."
                }.joined(separator: "\n"),
            citations: citations(from: Array(riskSessions.prefix(4)), limit: 4)
        )

        var sections: [MobileProjectMemorySection] = [recentSection, modelSection, riskSection]
        if let focusQuestion = focusQuestion?.trimmingCharacters(in: .whitespacesAndNewlines),
           !focusQuestion.isEmpty {
            let focused = focusedSessions(from: sortedSessions, question: focusQuestion)
            let focusSection = MobileProjectMemorySection(
                id: "focus",
                title: "Focus: \(focusQuestion)",
                body: focused.isEmpty
                    ? "No directly matching evidence found in the current project cache. Refresh project activity and retry this question."
                    : focused.prefix(4).map { session in
                        "\(session.model) · \(session.cost.formatAsCost()) · \(session.totalTokens.formatAsTokenVolume()) · \(session.startTime.formatted(date: .abbreviated, time: .shortened))"
                    }.joined(separator: "\n"),
                citations: citations(from: Array(focused.prefix(4)), limit: 4)
            )
            sections.insert(focusSection, at: 1)
        }

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "MMM d"
        let visuals: [MobileProjectMemoryVisual] = [
            MobileProjectMemoryVisual(
                id: "provider-mix",
                title: "Provider mix",
                subtitle: "Spend by provider",
                kind: .bar,
                points: providerBuckets
                    .sorted { lhs, rhs in
                        if lhs.value != rhs.value { return lhs.value > rhs.value }
                        return lhs.key < rhs.key
                    }
                    .prefix(5)
                    .map { MobileProjectMemoryVisualPoint(label: $0.key, value: $0.value, display: $0.value.formatAsCost()) }
            ),
            MobileProjectMemoryVisual(
                id: "timeline",
                title: "Timeline",
                subtitle: "Recent daily tokens",
                kind: .timeline,
                points: project.sortedDailyPoints.suffix(8).map {
                    MobileProjectMemoryVisualPoint(
                        label: dayFormatter.string(from: $0.date),
                        value: $0.value,
                        display: Int($0.value).formatAsTokenVolume()
                    )
                }
            ),
            MobileProjectMemoryVisual(
                id: "model-hotspots",
                title: "Model hotspots",
                subtitle: "Top token models",
                kind: .bar,
                points: topModels.prefix(5).map {
                    MobileProjectMemoryVisualPoint(label: $0.key, value: Double($0.value), display: $0.value.formatAsTokenVolume())
                }
            )
        ].filter { !$0.points.isEmpty }

        return MobileProjectMemorySnapshot(
            projectID: project.id,
            projectName: project.projectName,
            summary: summary,
            generatedAt: now,
            freshness: MobileProjectMemoryFreshness.from(lastSeen: project.lastSeen, now: now),
            sections: sections,
            visuals: visuals,
            sourceSessionCount: sourceSessionCount,
            sourceTokenTotal: sourceTokenTotal,
            sourceCostTotal: sourceCostTotal
        )
    }

    private static func citations(
        from sessions: [TokenUsage],
        limit: Int
    ) -> [MobileProjectMemoryCitation] {
        Array(sessions.prefix(max(0, limit))).enumerated().map { idx, session in
            MobileProjectMemoryCitation(
                id: "\(session.sessionId)-\(idx)",
                sessionID: session.sessionId,
                model: session.model,
                provider: session.provider.displayName,
                observedAt: session.startTime,
                note: "\(session.model) · \(session.cost.formatAsCost()) · \(session.totalTokens.formatAsTokenVolume())"
            )
        }
    }

    private static func focusedSessions(
        from sessions: [TokenUsage],
        question: String
    ) -> [TokenUsage] {
        let tokens = question
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 }
        guard !tokens.isEmpty else {
            return Array(sessions.prefix(4))
        }
        let scored = sessions.compactMap { session -> (TokenUsage, Int)? in
            let haystack = [
                session.model.lowercased(),
                session.provider.rawValue.lowercased(),
                session.projectName.lowercased()
            ].joined(separator: " ")
            let score = tokens.reduce(into: 0) { value, token in
                if haystack.contains(token) { value += 2 }
            } + (session.cost > 0.05 ? 1 : 0)
            guard score > 0 else { return nil }
            return (session, score)
        }
        return scored.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.startTime > rhs.0.startTime
        }.map(\.0)
    }
}

public struct MobileProjectMemoryCatalogEntry: Sendable, Equatable, Codable {
    public let projectID: String
    public let projectName: String
    public let sessionCount: Int
    public let totalTokens: Int
    public let totalCost: Double
    public let lastSeen: Date
    public let freshness: MobileProjectMemoryFreshness
    public let summary: String

    public init(
        projectID: String,
        projectName: String,
        sessionCount: Int,
        totalTokens: Int,
        totalCost: Double,
        lastSeen: Date,
        freshness: MobileProjectMemoryFreshness,
        summary: String
    ) {
        self.projectID = projectID
        self.projectName = projectName
        self.sessionCount = sessionCount
        self.totalTokens = totalTokens
        self.totalCost = totalCost
        self.lastSeen = lastSeen
        self.freshness = freshness
        self.summary = summary
    }
}

// MARK: - Project Memory Provider

@MainActor
public protocol MobileProjectMemoryProviding: AnyObject {
    func listProjectMemory(limit: Int) async throws -> [MobileProjectMemoryCatalogEntry]
    func projectMemorySnapshot(projectID: String, focusQuestion: String?) async throws -> MobileProjectMemorySnapshot?
}

@MainActor
public final class MobileProjectMemoryProvider: MobileProjectMemoryProviding {
    public static let shared = MobileProjectMemoryProvider()

    private let firestoreProvider: () -> FirestoreRepository
    private let pageSize: Int
    private let maxRows: Int

    init(
        firestoreProvider: @escaping () -> FirestoreRepository = { FirestoreRepository() },
        pageSize: Int = 100,
        maxRows: Int = 500
    ) {
        self.firestoreProvider = firestoreProvider
        self.pageSize = pageSize
        self.maxRows = maxRows
    }

    public func listProjectMemory(limit: Int) async throws -> [MobileProjectMemoryCatalogEntry] {
        let rows = try await loadUsageRows()
        let summaries = ProjectSummaryAggregator.aggregate(rows)
        let now = Date()
        let entries = summaries.map { summary in
            let freshness = MobileProjectMemoryFreshness.from(lastSeen: summary.lastSeen, now: now)
            return MobileProjectMemoryCatalogEntry(
                projectID: summary.id,
                projectName: summary.projectName,
                sessionCount: summary.sessions,
                totalTokens: summary.totalTokens,
                totalCost: summary.totalCost,
                lastSeen: summary.lastSeen,
                freshness: freshness,
                summary: "\(summary.sessions) sessions · \(summary.totalTokens.formatAsTokenVolume()) · \(summary.totalCost.formatAsCost())"
            )
        }
        return Array(entries.prefix(max(1, min(limit, 80))))
    }

    public func projectMemorySnapshot(projectID: String, focusQuestion: String?) async throws -> MobileProjectMemorySnapshot? {
        let query = normalizeProjectID(projectID)
        guard !query.isEmpty else { return nil }
        let rows = try await loadUsageRows()
        let summaries = ProjectSummaryAggregator.aggregate(rows)
        guard let project = summaries.first(where: { matches(summary: $0, query: query) }) else {
            return nil
        }
        let sessions = rows
            .filter { normalizeProjectID($0.projectName) == project.id }
            .sorted { $0.startTime > $1.startTime }
        return MobileProjectMemorySnapshot.build(
            project: project,
            sessions: sessions,
            focusQuestion: focusQuestion
        )
    }

    private func loadUsageRows() async throws -> [TokenUsage] {
        let firestore = firestoreProvider()
        var rows: [TokenUsage] = []
        var cursor: DocumentSnapshot? = nil

        while rows.count < maxRows {
            let (page, pageLast) = try await firestore.fetchUsagePage(
                pageSize: pageSize,
                after: cursor,
                provider: nil,
                model: nil,
                device: nil,
                startDate: nil,
                endDate: nil
            )
            guard !page.isEmpty else { break }
            rows.append(contentsOf: page)
            cursor = pageLast
            if page.count < pageSize || pageLast == nil {
                break
            }
        }
        if rows.count > maxRows {
            rows = Array(rows.prefix(maxRows))
        }
        return rows
    }

    private func matches(summary: ProjectSummary, query: String) -> Bool {
        let id = normalizeProjectID(summary.id)
        let display = normalizeProjectID(summary.projectName)
        return id == query || display == query || display.contains(query) || query.contains(display)
    }

    private func normalizeProjectID(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - Project Memory Tools

@MainActor
public struct BurnBarProjectMemoryListTool: MobileTool {
    public init() {}

    public static let name = "burnbar_project_memory_list"

    public var displayName: String { "List project memory" }

    public var description: String {
        """
        List projects with available Project Memory wiki snapshots on this \
        device. Use this before `burnbar_project_memory_wiki` when the user \
        asks for project wiki info but did not provide an exact project id.

        Optional arguments:
          - `limit`: max projects to return (1–50, default 10).
          - `query`: case-insensitive filter on project id/name.

        Returns JSON: `{"count":<int>,"total_available":<int>,"projects":[...]}` \
        where each project includes id, name, freshness, last seen timestamp, \
        sessions, token totals, and spend totals.
        """
    }

    public var parametersSchema: [String: Any] {
        MobileToolJSONSchema.object(
            properties: [
                "limit": MobileToolJSONSchema.integer(
                    description: "Maximum number of projects to return.",
                    minimum: 1,
                    maximum: 50
                ),
                "query": MobileToolJSONSchema.string(
                    description: "Optional project-name/project-id filter."
                )
            ],
            required: [],
            description: "Enumerate project memory snapshots available on-device."
        )
    }

    public func execute(
        arguments: String,
        context: any MobileToolContext
    ) async throws -> String {
        let object = try parseArguments(arguments)
        var limit = 10
        if let rawLimit = object["limit"] as? Int {
            limit = max(1, min(50, rawLimit))
        } else if let rawLimit = object["limit"] as? Double {
            limit = max(1, min(50, Int(rawLimit)))
        }
        let query = (object["query"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let allProjects = try await context.projectMemoryProvider.listProjectMemory(limit: 80)
        let filtered: [MobileProjectMemoryCatalogEntry]
        if let query, !query.isEmpty {
            filtered = allProjects.filter { project in
                project.projectID.lowercased().contains(query)
                    || project.projectName.lowercased().contains(query)
            }
        } else {
            filtered = allProjects
        }
        let selected = Array(filtered.prefix(limit))
        struct Payload: Codable {
            let count: Int
            let totalAvailable: Int
            let projects: [MobileProjectMemoryCatalogEntry]
        }
        let payload = Payload(
            count: selected.count,
            totalAvailable: filtered.count,
            projects: selected
        )
        return try encodeJSON(payload)
    }

    private func parseArguments(_ arguments: String) throws -> [String: Any] {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = object as? [String: Any] else {
            throw MobileToolError.invalidArguments(
                "expected a JSON object, got \(trimmed.prefix(80))"
            )
        }
        return dict
    }
}

@MainActor
public struct BurnBarProjectMemoryWikiTool: MobileTool {
    public init() {}

    public static let name = "burnbar_project_memory_wiki"

    public var displayName: String { "Get project wiki" }

    public var description: String {
        """
        Return a structured Project Memory wiki snapshot for a single \
        project. Use after `burnbar_project_memory_list` (or when the user \
        already gave a project id/name) to answer architecture, risk, and \
        recent-work questions with citations and visuals.

        Required argument:
          - `project_id`: project id or name.

        Optional argument:
          - `focus_question`: user question to focus evidence selection.

        Returns JSON containing `found`, project metadata, and a full \
        `snapshot` object with summary, sections, citations, visuals, and \
        freshness.
        """
    }

    public var parametersSchema: [String: Any] {
        MobileToolJSONSchema.object(
            properties: [
                "project_id": MobileToolJSONSchema.string(
                    description: "Project identifier or project name."
                ),
                "focus_question": MobileToolJSONSchema.string(
                    description: "Optional user question to focus this wiki snapshot."
                )
            ],
            required: ["project_id"],
            description: "Load one project's wiki snapshot with citations."
        )
    }

    public func execute(
        arguments: String,
        context: any MobileToolContext
    ) async throws -> String {
        let object = try parseArguments(arguments)
        guard let projectID = stringValue(
            forKeys: ["project_id", "projectId", "project"],
            object: object
        ) else {
            throw MobileToolError.invalidArguments(
                "missing required argument `project_id`"
            )
        }
        let focusQuestion = stringValue(
            forKeys: ["focus_question", "focusQuestion", "question"],
            object: object
        )
        let snapshot = try await context.projectMemoryProvider.projectMemorySnapshot(
            projectID: projectID,
            focusQuestion: focusQuestion
        )

        struct Payload: Codable {
            let found: Bool
            let projectID: String
            let atomURL: String
            let focusQuestion: String?
            let snapshot: MobileProjectMemorySnapshot?
            let message: String?
        }
        let atomURL = "burnbar://project?id=\(projectID)"
        let payload: Payload
        if let snapshot {
            payload = Payload(
                found: true,
                projectID: snapshot.projectID,
                atomURL: atomURL,
                focusQuestion: focusQuestion,
                snapshot: snapshot,
                message: nil
            )
        } else {
            payload = Payload(
                found: false,
                projectID: projectID,
                atomURL: atomURL,
                focusQuestion: focusQuestion,
                snapshot: nil,
                message: "No project memory snapshot found for '\(projectID)'. Call burnbar_project_memory_list to discover valid project ids."
            )
        }
        return try encodeJSON(payload)
    }

    private func parseArguments(_ arguments: String) throws -> [String: Any] {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = object as? [String: Any] else {
            throw MobileToolError.invalidArguments(
                "expected a JSON object, got \(trimmed.prefix(80))"
            )
        }
        return dict
    }

    private func stringValue(forKeys keys: [String], object: [String: Any]) -> String? {
        for key in keys {
            if let value = object[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }
}

private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let data = try encoder.encode(value)
    return String(data: data, encoding: .utf8) ?? "{}"
}

// MARK: - Executor

/// Coordinator that runs one or more tool calls against a catalog and
/// returns the result messages ready to be appended to the chat history.
/// Pure value-semantics — safe to construct fresh per request.
@MainActor
public struct MobileToolExecutor: Sendable {
    public let catalog: MobileToolCatalog

    public init(catalog: MobileToolCatalog) {
        self.catalog = catalog
    }

    /// Execute every tool call in `calls` against `context`. Order is
    /// preserved. Each call yields exactly one result message even when
    /// the tool failed; the model sees the failure body and can recover.
    public func execute(
        _ calls: [PendingToolCall],
        context: any MobileToolContext
    ) async -> [MobileToolExecutionResult] {
        var results: [MobileToolExecutionResult] = []
        results.reserveCapacity(calls.count)
        for call in calls {
            results.append(await execute(call, context: context))
        }
        return results
    }

    /// Execute a single tool call. Always returns a result — failures
    /// are wrapped in structured error bodies, not thrown.
    public func execute(
        _ call: PendingToolCall,
        context: any MobileToolContext
    ) async -> MobileToolExecutionResult {
        guard let tool = catalog.tool(named: call.name) else {
            return MobileToolExecutionResult(
                toolCallID: call.id,
                toolName: call.name,
                isError: true,
                content: MobileToolError.unknownTool(call.name).wireContent
            )
        }

        do {
            let content = try await tool.execute(
                arguments: call.arguments,
                context: context
            )
            return MobileToolExecutionResult(
                toolCallID: call.id,
                toolName: call.name,
                isError: false,
                content: MobileToolExecutionResult.truncatedForWire(content)
            )
        } catch let toolError as MobileToolError {
            return MobileToolExecutionResult(
                toolCallID: call.id,
                toolName: call.name,
                isError: true,
                content: toolError.wireContent
            )
        } catch {
            let fallback = MobileToolError.executionFailed(error.localizedDescription)
            return MobileToolExecutionResult(
                toolCallID: call.id,
                toolName: call.name,
                isError: true,
                content: fallback.wireContent
            )
        }
    }
}

/// Plain-value handoff between the streaming parser (which writes one
/// `HermesToolCall` / `PiToolCall` per assistant turn) and the executor.
/// Keeps the executor decoupled from the service-specific types.
public struct PendingToolCall: Sendable, Equatable {
    public let id: String
    public let name: String
    public let arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

// MARK: - JSON Schema Helpers

/// Tiny builder helpers for the JSON Schema fragments tools emit in
/// `parametersSchema`. Keeps every tool consistent and removes the
/// dictionary-literal noise from the call sites.
public enum MobileToolJSONSchema {
    /// `{"type": "object", "properties": {...}, "required": [...], "additionalProperties": false}`.
    public static func object(
        properties: [String: [String: Any]],
        required: [String] = [],
        description: String? = nil
    ) -> [String: Any] {
        var schema: [String: Any] = [
            "type": "object",
            "properties": properties,
            "additionalProperties": false
        ]
        if !required.isEmpty {
            schema["required"] = required
        }
        if let description {
            schema["description"] = description
        }
        return schema
    }

    /// `{"type": "string", "description": "..."}` with optional enum.
    public static func string(
        description: String,
        enumeration: [String]? = nil
    ) -> [String: Any] {
        var field: [String: Any] = [
            "type": "string",
            "description": description
        ]
        if let enumeration, !enumeration.isEmpty {
            field["enum"] = enumeration
        }
        return field
    }

    /// `{"type": "integer", "description": "..."}` with optional bounds.
    public static func integer(
        description: String,
        minimum: Int? = nil,
        maximum: Int? = nil
    ) -> [String: Any] {
        var field: [String: Any] = [
            "type": "integer",
            "description": description
        ]
        if let minimum { field["minimum"] = minimum }
        if let maximum { field["maximum"] = maximum }
        return field
    }

    /// `{"type": "boolean", "description": "..."}`.
    public static func boolean(description: String) -> [String: Any] {
        ["type": "boolean", "description": description]
    }
}

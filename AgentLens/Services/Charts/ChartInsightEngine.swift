import Foundation
import OpenBurnBarCore

// MARK: - Chart Insight Models

/// One AI-authored observation about the user's usage.
struct ChartInsight: Codable, Equatable, Identifiable, Sendable {
    enum Severity: String, Codable, Sendable {
        case info, win, warning
    }

    let id: String
    let severity: Severity
    let title: String
    let body: String
    /// Chart kinds this insight references (raw values validated on parse).
    let metricRefs: [String]
}

struct ChartInsightSuggestion: Codable, Equatable, Identifiable, Sendable {
    let kind: ChartKind
    let reason: String

    var id: String { kind.rawValue }
}

struct ChartInsightResult: Equatable, Sendable {
    let insights: [ChartInsight]
    let suggestedCharts: [ChartInsightSuggestion]
}

// MARK: - Parser
//
// Pure and separately testable (ChartInsightEngineParsingTests). Tolerates
// code fences and leading chatter; drops unknown chart kinds instead of
// failing the whole payload.

enum ChartInsightParser {

    private struct RawPayload: Codable {
        struct RawInsight: Codable {
            let id: String?
            let severity: String?
            let title: String
            let body: String
            let metricRefs: [String]?
        }
        struct RawSuggestion: Codable {
            let kind: String
            let reason: String?
        }
        let insights: [RawInsight]?
        let suggestedCharts: [RawSuggestion]?
    }

    static func parse(_ text: String) -> ChartInsightResult? {
        guard let json = extractJSONObject(from: text),
              let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawPayload.self, from: data) else {
            return nil
        }
        let insights = (raw.insights ?? []).enumerated().map { index, entry in
            ChartInsight(
                id: entry.id ?? "insight-\(index)",
                severity: ChartInsight.Severity(rawValue: entry.severity ?? "") ?? .info,
                title: String(entry.title.prefix(80)),
                body: String(entry.body.prefix(300)),
                metricRefs: (entry.metricRefs ?? []).filter { ChartKind(rawValue: $0) != nil }
            )
        }
        let suggestions = (raw.suggestedCharts ?? []).compactMap { entry -> ChartInsightSuggestion? in
            guard let kind = ChartKind(rawValue: entry.kind) else { return nil }
            return ChartInsightSuggestion(kind: kind, reason: String((entry.reason ?? "").prefix(160)))
        }
        guard !insights.isEmpty || !suggestions.isEmpty else { return nil }
        return ChartInsightResult(insights: insights, suggestedCharts: suggestions)
    }

    /// Pulls the first balanced `{ … }` object out of a response that may be
    /// wrapped in code fences or prefixed with prose.
    static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var previous: Character = " "
        for index in text.indices[start...] {
            let char = text[index]
            if inString {
                if char == "\"" && previous != "\\" { inString = false }
            } else {
                switch char {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                default: break
                }
            }
            previous = char
        }
        return nil
    }
}

// MARK: - Metrics serializer
//
// The compact aggregate summary sent to the model. Numbers only — no
// conversation content, no file paths, no session ids.

enum ChartInsightMetrics {

    static func compactJSON(from snapshot: ChartsSnapshot) -> String {
        var payload: [String: Any] = [
            "window": snapshot.timeRange.rawValue,
            "totalCostUSD": rounded(snapshot.totalCost),
            "totalTokens": snapshot.totalTokens,
            "sessions": snapshot.sessionCount,
            "burnDaily": snapshot.burnSeries.suffix(31).map { rounded($0.value) },
            "providerShares": snapshot.providerShares.prefix(6).map {
                ["name": $0.provider.displayName, "costUSD": rounded($0.cost)]
            },
            "topModels": snapshot.modelCosts.prefix(6).map {
                ["name": $0.label, "costUSD": rounded($0.value)]
            },
            "cacheHitRate": rounded(snapshot.cacheHitRate, places: 3),
            "cacheSavingsEstUSD": rounded(snapshot.cacheSavingsEstimate),
            "reasoningTokenShare": rounded(snapshot.reasoningShare, places: 3),
            "weekOverWeekPercent": snapshot.weekOverWeekPercent.map { rounded($0, places: 1) } as Any,
            "medianSessionCostUSD": snapshot.medianSessionCost.map { rounded($0) } as Any,
            "projectFocusEntropy": rounded(snapshot.projectEntropy, places: 2),
            "exactDataShare": rounded(snapshot.exactShare, places: 2),
            "modelConcentrationHHI": rounded(snapshot.modelConcentrationIndex, places: 2)
        ]
        if let forecast = snapshot.forecast {
            payload["projectedMonthEndSpendUSD"] = rounded(forecast.projectedMonthEndSpend)
        }
        if let peakHour = snapshot.peakHour, let peakDay = snapshot.peakWeekdayIndex {
            payload["peakUsage"] = ["weekdayIndexSundayZero": peakDay, "hour": peakHour]
        }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    static func prompt(metricsJSON: String) -> String {
        let kinds = ChartKind.allCases.map(\.rawValue).joined(separator: ", ")
        return """
        You are the analytics copilot inside OpenBurnBar, a desktop app that tracks \
        AI/LLM token spend. Below is an aggregate summary of the user's usage \
        (numbers only). Find the 3-5 most genuinely useful, non-obvious insights: \
        anomalies, savings opportunities, risks, and wins. Be specific and quantitative.

        METRICS:
        \(metricsJSON)

        Respond with ONLY a JSON object matching exactly this schema (no prose, no fences):
        {"insights":[{"id":"string","severity":"info|win|warning","title":"max 60 chars","body":"max 240 chars","metricRefs":["chartKind"]}],"suggestedCharts":[{"kind":"chartKind","reason":"max 120 chars"}]}

        Valid chartKind values: \(kinds). Suggest at most 2 charts, only ones worth \
        surfacing given the data (e.g. hidden charts that would reveal something).
        """
    }

    private static func rounded(_ value: Double, places: Int = 2) -> Double {
        let factor = pow(10.0, Double(places))
        return (value * factor).rounded() / factor
    }
}

// MARK: - Engine
//
// Orchestrates one-shot insight generation over the user's already-connected
// backends. Local-first: Hermes (localhost gateway) outranks cloud CLIs.
// Results are cached per (usagesVersion, timeRange) with a 15-minute re-ask
// floor so toggling the switch or reordering cards never spams the model.

@MainActor
@Observable
final class ChartInsightEngine {

    enum State: Equatable {
        case idle
        case loading
        case loaded(ChartInsightResult, backend: String, isLocal: Bool)
        case unavailable(String)
    }

    private(set) var state: State = .idle

    /// Backends tried in order; the first `.ready` one wins.
    static let preferredOrder: [ChatBackendID] = [.hermes, .claude, .codex]

    private struct CacheEntry {
        let key: ChartsDataService.SnapshotKey
        let state: State
        let at: Date
    }

    private var cache: CacheEntry?
    private var task: Task<Void, Never>?
    private static let reaskFloor: TimeInterval = 15 * 60

    func generateIfNeeded(
        snapshot: ChartsSnapshot,
        bridge: CLIBridge,
        enabledBackends: [ChatBackendID],
        now: Date = Date()
    ) {
        let key = ChartsDataService.SnapshotKey(
            usagesVersion: snapshot.usagesVersion, timeRange: snapshot.timeRange
        )
        if let cache, cache.key == key || now.timeIntervalSince(cache.at) < Self.reaskFloor {
            state = cache.state
            return
        }
        guard task == nil else { return }

        state = .loading
        task = Task { [weak self] in
            let result = await Self.generate(
                snapshot: snapshot, bridge: bridge, enabledBackends: enabledBackends
            )
            guard let self, !Task.isCancelled else { return }
            self.state = result
            self.cache = CacheEntry(key: key, state: result, at: Date())
            self.task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if state == .loading { state = .idle }
    }

    // MARK: One-shot generation

    private static func generate(
        snapshot: ChartsSnapshot,
        bridge: CLIBridge,
        enabledBackends: [ChatBackendID]
    ) async -> State {
        let candidates = preferredOrder.filter { enabledBackends.contains($0) }
            + enabledBackends.filter { !preferredOrder.contains($0) }
        guard !candidates.isEmpty else {
            return .unavailable("No chat backends enabled. Connect one in Settings → Agents.")
        }

        let prompt = ChartInsightMetrics.prompt(
            metricsJSON: ChartInsightMetrics.compactJSON(from: snapshot)
        )

        for backend in candidates {
            let provider = PetChatProviders.provider(for: backend, bridge: bridge)
            guard await provider.checkAuth() == .ready else { continue }

            // First attempt, then a single "JSON only" retry.
            for attempt in 0..<2 {
                if Task.isCancelled { return .idle }
                let message = attempt == 0
                    ? prompt
                    : prompt + "\n\nREMINDER: respond with ONLY the JSON object. No other text."
                guard let text = await collectResponse(
                    backend: backend, bridge: bridge, message: message
                ), !text.isEmpty else { break }
                if let parsed = ChartInsightParser.parse(text) {
                    return .loaded(parsed, backend: backend.displayName, isLocal: backend == .hermes)
                }
            }
        }
        return .unavailable("Insights unavailable — no connected backend produced a readable answer.")
    }

    /// Accumulates a full one-shot response, bounded by a hard timeout so a
    /// wedged CLI can never pin the loading state.
    private static func collectResponse(
        backend: ChatBackendID,
        bridge: CLIBridge,
        message: String,
        timeout: TimeInterval = 90
    ) async -> String? {
        let systemPrompt = "You are a precise analytics engine. You respond only with valid JSON."
        let stream: AsyncThrowingStream<CLIChatStreamEvent, Error>
        switch backend {
        case .hermes:
            let history = [ChatMessageRecord(role: .user, content: message)]
            stream = bridge.chatHermes(
                systemPrompt: systemPrompt,
                history: history,
                bearerToken: try? PetKeychainStore().get(.hermes)
            )
        case .claude:
            stream = bridge.chatClaudeStream(
                systemPrompt: systemPrompt, userMessage: message, workspaceDirectory: nil
            )
        case .codex:
            stream = bridge.chatCodexStream(
                systemPrompt: systemPrompt, userMessage: message, workspaceDirectory: nil
            )
        default:
            return nil
        }

        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                var collected = ""
                do {
                    for try await event in stream {
                        if case let .text(chunk) = event {
                            collected += chunk
                        }
                    }
                } catch {
                    return collected.isEmpty ? nil : collected
                }
                return collected
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

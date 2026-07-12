import Foundation

/// Read-only tool plane the LLM can call during an investigation.
///
/// All tools are routed through the local `InsightDataSource` and bounded
/// in result size — the broker enforces read-only by construction
/// (`mutating func` operations are not declared anywhere on this type).
public actor InsightToolBroker {

    private let dataSource: InsightDataSource
    private let taxonomy: InsightTaxonomy
    private let executor: InsightExecutor
    private let maxRows: Int

    public init(dataSource: InsightDataSource,
                taxonomy: InsightTaxonomy = .default,
                executor: InsightExecutor = InsightExecutor(),
                maxRows: Int = 25) {
        self.dataSource = dataSource
        self.taxonomy = taxonomy
        self.executor = executor
        self.maxRows = max(1, maxRows)
    }

    /// Dispatch a single tool call. Always returns a result, never throws —
    /// failures are wrapped as `.error(payload:)` so the LLM gets
    /// stable feedback.
    public func dispatch(_ call: InsightToolCall) async -> InsightToolResult {
        do {
            switch call.arguments {
            case .drilldownSearch(let query, let filter):
                return try await drilldownSearch(query: query, filter: filter, callID: call.id)
            case .drilldownSession(let sessionID):
                return try await drilldownSession(sessionID: sessionID, callID: call.id)
            case .agentUsage(let agent, let window):
                return try await agentUsage(agent: agent, window: window, callID: call.id)
            case .modelUsage(let modelID, let window):
                return try await modelUsage(modelID: modelID, window: window, callID: call.id)
            case .operatingActions(let window):
                return try await operatingActions(window: window, callID: call.id)
            case .quotaSnapshot(let providerKey):
                return try await quotaSnapshot(providerKey: providerKey, callID: call.id)
            case .anomalyDetail(let anomalyID):
                return try await anomalyDetail(anomalyID: anomalyID, callID: call.id)
            case .listFocuses:
                return .init(id: call.id, toolName: "list_focuses",
                             isError: false, summary: "\(taxonomy.focuses.count) focuses",
                             payload: .vocabulary(taxonomy.focuses))
            case .listUseCases:
                return .init(id: call.id, toolName: "list_use_cases",
                             isError: false, summary: "\(taxonomy.useCases.count) use cases",
                             payload: .vocabulary(taxonomy.useCases))
            }
        } catch {
            return .init(id: call.id, toolName: call.name,
                         isError: true, summary: error.localizedDescription,
                         payload: .error(error.localizedDescription))
        }
    }

    // MARK: - Tool implementations

    private func drilldownSearch(query: String,
                                 filter: InsightFilter?,
                                 callID: String) async throws -> InsightToolResult {
        let effective = filter ?? InsightFilter(window: .last30d)
        let snapshot = try await dataSource.snapshot(window: effective.window.interval())
        let q = query.lowercased()
        let matched = snapshot.sessions.filter {
            ($0.inferredTaskTitle ?? "").lowercased().contains(q)
                || $0.keyTools.contains(where: { $0.lowercased().contains(q) })
                || $0.keyCommands.contains(where: { $0.lowercased().contains(q) })
        }
        let rows = matched.prefix(maxRows).map { s -> InsightWidgetData.Drilldown.Row in
            InsightWidgetData.Drilldown.Row(
                id: "\(s.provider)|\(s.sessionID)",
                title: s.inferredTaskTitle ?? "Session \(s.sessionID.prefix(8))",
                subtitle: s.provider,
                occurredAt: s.startTime,
                costUSD: nil,
                tokens: nil,
                citation: .init(kind: .session(id: s.sessionID, provider: s.provider),
                                label: s.inferredTaskTitle ?? s.sessionID)
            )
        }
        return .init(id: callID, toolName: "drilldown_search",
                     isError: false,
                     summary: "\(rows.count) sessions matched “\(String(query.prefix(40)))”",
                     payload: .sessions(Array(rows)))
    }

    private func drilldownSession(sessionID: String, callID: String) async throws -> InsightToolResult {
        let snapshot = try await dataSource.snapshot(window: InsightTimeWindow.allTime.interval())
        guard let session = snapshot.sessions.first(where: { $0.sessionID == sessionID }) else {
            return .init(id: callID, toolName: "drilldown_session",
                         isError: true, summary: "Session not found",
                         payload: .error("Session \(sessionID) not found"))
        }
        let row = InsightWidgetData.Drilldown.Row(
            id: "\(session.provider)|\(session.sessionID)",
            title: session.inferredTaskTitle ?? "Session \(session.sessionID.prefix(8))",
            subtitle: session.provider,
            occurredAt: session.startTime,
            costUSD: nil,
            tokens: nil,
            citation: .init(kind: .session(id: session.sessionID, provider: session.provider),
                            label: session.inferredTaskTitle ?? session.sessionID)
        )
        return .init(id: callID, toolName: "drilldown_session",
                     isError: false, summary: row.title,
                     payload: .sessions([row]))
    }

    private func agentUsage(agent: String,
                            window: InsightTimeWindow,
                            callID: String) async throws -> InsightToolResult {
        let snapshot = try await dataSource.snapshot(window: window.interval())
        let filter = InsightFilter(window: window, providers: [agent])
        let result = executor.evaluate(
            binding: .timeSeries(metric: .cost, dimension: .day, window: window),
            filter: filter, snapshot: snapshot
        )
        guard case .timeSeries(let ts) = result else {
            return .init(id: callID, toolName: "agent_usage",
                         isError: true, summary: "No data",
                         payload: .error("No usage for \(agent)"))
        }
        return .init(id: callID, toolName: "agent_usage",
                     isError: false, summary: "\(ts.series.count) series",
                     payload: .timeSeries(ts))
    }

    private func modelUsage(modelID: String,
                            window: InsightTimeWindow,
                            callID: String) async throws -> InsightToolResult {
        let snapshot = try await dataSource.snapshot(window: window.interval())
        let filter = InsightFilter(window: window, models: [modelID])
        let result = executor.evaluate(
            binding: .ranking(metric: .cost, dimension: .project, limit: maxRows, window: window),
            filter: filter, snapshot: snapshot
        )
        guard case .ranking(let r) = result else {
            return .init(id: callID, toolName: "model_usage",
                         isError: true, summary: "No data",
                         payload: .error("No usage for \(modelID)"))
        }
        return .init(id: callID, toolName: "model_usage",
                     isError: false, summary: "\(r.rows.count) projects",
                     payload: .ranking(r))
    }

    private func operatingActions(window: InsightTimeWindow,
                                  callID: String) async throws -> InsightToolResult {
        let snapshot = try await dataSource.snapshot(window: window.interval())
        let builder = InsightDigestBuilder(taxonomy: taxonomy)
        let actions = snapshot.operatingActions
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(maxRows)
            .map { a -> InsightDigest.ActionDigest in
                .init(id: a.id, kind: a.actionKind,
                      projectID: a.projectName.map(builder.hashedProjectID(_:)),
                      occurredAt: a.occurredAt,
                      summary: String(a.summary.prefix(160)))
            }
        return .init(id: callID, toolName: "operating_actions",
                     isError: false,
                     summary: "\(actions.count) actions",
                     payload: .actions(Array(actions)))
    }

    private func quotaSnapshot(providerKey: String?,
                               callID: String) async throws -> InsightToolResult {
        let snapshot = try await dataSource.snapshot(window: InsightTimeWindow.today.interval())
        let result = executor.evaluate(
            binding: .quota(providerKey: providerKey),
            filter: InsightFilter(), snapshot: snapshot
        )
        guard case .quota(let q) = result else {
            return .init(id: callID, toolName: "quota_snapshot",
                         isError: true, summary: "No quota",
                         payload: .error("No quota state"))
        }
        return .init(id: callID, toolName: "quota_snapshot",
                     isError: false,
                     summary: "\(q.buckets.count) buckets",
                     payload: .quota(q))
    }

    private func anomalyDetail(anomalyID: String,
                               callID: String) async throws -> InsightToolResult {
        let snapshot = try await dataSource.snapshot(window: InsightTimeWindow.last90d.interval())
        let result = executor.evaluate(binding: .anomaly(window: .last90d),
                                       filter: InsightFilter(window: .last90d),
                                       snapshot: snapshot)
        guard case .anomaly(let table) = result,
              let row = table.rows.first(where: { $0.id == anomalyID }) else {
            return .init(id: callID, toolName: "anomaly_detail",
                         isError: true, summary: "Anomaly not found",
                         payload: .error("\(anomalyID) not found"))
        }
        return .init(id: callID, toolName: "anomaly_detail",
                     isError: false, summary: row.label,
                     payload: .anomaly(row))
    }
}

import Foundation

/// Streaming events emitted by an `InsightModelGateway` during an
/// investigation.
///
/// The UI subscribes to an `AsyncThrowingStream<InsightInvestigateEvent,
/// Error>` and renders widgets as they materialize. Cancellation,
/// thinking, and final usage all flow through the same channel.
public enum InsightInvestigateEvent: Sendable, Hashable {
    /// Free-form reasoning delta from the model (when thinking is enabled).
    case thinkingDelta(String)
    /// The full canvas the model has authored so far. Replaces any prior
    /// `.partialCanvas`/`.widgetReady` state in the UI.
    case partialCanvas(InsightCanvas)
    /// A single widget materialized. The UI may insert/replace it.
    case widgetReady(InsightWidget)
    /// The model has called a tool. The broker will respond.
    case toolCall(InsightToolCall)
    /// The tool broker has answered. Surfaced for the UI to optionally show.
    case toolResult(InsightToolResult)
    /// Token usage update. Final usage arrives with `.finalCanvas`.
    case usage(InsightTokenUsage)
    /// The final, committed canvas.
    case finalCanvas(InsightCanvas)
}

/// A read-only tool call requested by the LLM mid-stream.
public struct InsightToolCall: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let arguments: InsightToolArguments
    public init(id: String, name: String, arguments: InsightToolArguments) {
        self.id = id; self.name = name; self.arguments = arguments
    }
}

/// Result of a tool call. The broker enforces read-only-ness.
public struct InsightToolResult: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let toolName: String
    public let isError: Bool
    public let summary: String                // short user-facing line
    public let payload: InsightToolResultPayload
    public init(id: String, toolName: String, isError: Bool, summary: String, payload: InsightToolResultPayload) {
        self.id = id; self.toolName = toolName; self.isError = isError
        self.summary = summary; self.payload = payload
    }
}

/// Sealed sum of supported tool argument shapes.
public enum InsightToolArguments: Codable, Hashable, Sendable {
    case drilldownSearch(query: String, filter: InsightFilter?)
    case drilldownSession(sessionID: String)
    case agentUsage(agent: String, window: InsightTimeWindow)
    case modelUsage(modelID: String, window: InsightTimeWindow)
    case operatingActions(window: InsightTimeWindow)
    case quotaSnapshot(providerKey: String?)
    case anomalyDetail(anomalyID: String)
    case listFocuses
    case listUseCases
}

/// Sealed sum of supported tool result shapes.
public enum InsightToolResultPayload: Codable, Hashable, Sendable {
    case sessions([InsightWidgetData.Drilldown.Row])
    case timeSeries(InsightWidgetData.TimeSeries)
    case ranking(InsightWidgetData.Ranking)
    case actions([InsightDigest.ActionDigest])
    case quota(InsightWidgetData.QuotaState)
    case anomaly(InsightWidgetData.AnomalyTable.Row)
    case vocabulary([String])
    case error(String)
}

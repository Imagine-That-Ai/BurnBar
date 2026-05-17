import Foundation

/// JSON-schema definitions for every tool the `InsightToolBroker` can
/// dispatch. Passed to LLM adapters so models declare `tools` in the
/// request body and receive structured `tool_use` / `function_call`
/// blocks.
///
/// Plan §4.7 — tool-use finally wired. All tools are read-only by
/// construction; no mutating operations are declared.
public enum InsightToolDefinitions {

    public static let all: [Tool] = [
        drilldownSearch,
        drilldownSession,
        agentUsage,
        modelUsage,
        operatingActions,
        quotaSnapshot,
        anomalyDetail,
        listFocuses,
        listUseCases
    ]

    public struct Tool {
        public let name: String
        public let description: String
        public let parameters: [String: Any]

        public init(name: String, description: String, parameters: [String: Any]) {
            self.name = name
            self.description = description
            self.parameters = parameters
        }
    }

    // MARK: - Anthropic shape

    /// Tools formatted for Anthropic's Messages API (`tools` array).
    public static var anthropicTools: [[String: Any]] {
        all.map { tool in
            [
                "name": tool.name,
                "description": tool.description,
                "input_schema": tool.parameters
            ]
        }
    }

    // MARK: - OpenAI shape

    /// Tools formatted for OpenAI's Chat Completions API (`tools` array).
    public static var openAITools: [[String: Any]] {
        all.map { tool in
            [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.parameters,
                    "strict": true
                ]
            ]
        }
    }

    // MARK: - Individual tools

    public static let drilldownSearch = Tool(
        name: "drilldown_search",
        description: "Search sessions by query string across task titles, tools, and commands.",
        parameters: [
            "type": "object",
            "additionalProperties": false,
            "required": ["query"],
            "properties": [
                "query": ["type": "string", "description": "Search term"],
                "window": ["type": "string", "enum": ["today", "last24h", "last7d", "last30d", "last90d", "last365d", "allTime"], "description": "Optional time window"]
            ]
        ]
    )

    public static let drilldownSession = Tool(
        name: "drilldown_session",
        description: "Fetch full metadata for a single session by its ID.",
        parameters: [
            "type": "object",
            "additionalProperties": false,
            "required": ["session_id"],
            "properties": [
                "session_id": ["type": "string", "description": "The session ID"]
            ]
        ]
    )

    public static let agentUsage = Tool(
        name: "agent_usage",
        description: "Get a time-series breakdown of cost or tokens for a specific agent/provider.",
        parameters: [
            "type": "object",
            "additionalProperties": false,
            "required": ["agent"],
            "properties": [
                "agent": ["type": "string", "description": "Provider key, e.g. 'anthropic' or 'openai'"],
                "window": ["type": "string", "enum": ["today", "last24h", "last7d", "last30d", "last90d", "last365d", "allTime"], "description": "Time window"]
            ]
        ]
    )

    public static let modelUsage = Tool(
        name: "model_usage",
        description: "Get a ranking of projects or dimensions for a specific model.",
        parameters: [
            "type": "object",
            "additionalProperties": false,
            "required": ["model_id"],
            "properties": [
                "model_id": ["type": "string", "description": "Model ID, e.g. 'claude-sonnet-4-6'"],
                "window": ["type": "string", "enum": ["today", "last24h", "last7d", "last30d", "last90d", "last365d", "allTime"], "description": "Time window"]
            ]
        ]
    )

    public static let operatingActions = Tool(
        name: "operating_actions",
        description: "List recent operating actions (tool calls, commands) within a window.",
        parameters: [
            "type": "object",
            "additionalProperties": false,
            "required": [],
            "properties": [
                "window": ["type": "string", "enum": ["today", "last24h", "last7d", "last30d", "last90d", "last365d", "allTime"], "description": "Time window"]
            ]
        ]
    )

    public static let quotaSnapshot = Tool(
        name: "quota_snapshot",
        description: "Read the current quota state for a provider or all providers.",
        parameters: [
            "type": "object",
            "additionalProperties": false,
            "required": [],
            "properties": [
                "provider_key": ["type": "string", "description": "Optional provider key filter"]
            ]
        ]
    )

    public static let anomalyDetail = Tool(
        name: "anomaly_detail",
        description: "Fetch the full detail row for a specific anomaly by its ID.",
        parameters: [
            "type": "object",
            "additionalProperties": false,
            "required": ["anomaly_id"],
            "properties": [
                "anomaly_id": ["type": "string", "description": "Anomaly ID (day ISO string)"]
            ]
        ]
    )

    public static let listFocuses = Tool(
        name: "list_focuses",
        description: "Return the controlled vocabulary of task focuses used in this account.",
        parameters: [
            "type": "object",
            "additionalProperties": false,
            "required": [],
            "properties": [:]
        ]
    )

    public static let listUseCases = Tool(
        name: "list_use_cases",
        description: "Return the controlled vocabulary of use cases used in this account.",
        parameters: [
            "type": "object",
            "additionalProperties": false,
            "required": [],
            "properties": [:]
        ]
    )
}

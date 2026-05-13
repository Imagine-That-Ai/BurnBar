import Foundation
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

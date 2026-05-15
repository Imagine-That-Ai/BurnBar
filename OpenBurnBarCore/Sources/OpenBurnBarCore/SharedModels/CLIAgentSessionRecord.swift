import Foundation

// MARK: - CLI Agent Session Mirror
//
// Shared data model used by both the macOS writer
// (`CLIAgentSessionMirror` in AgentLens) and the iOS reader
// (`CLIAgentChatReader` in OpenBurnBarMobile). Mirrors what users see when
// they chat with Codex / Claude Code / OpenClaw on their Mac so the same
// transcript surfaces inside the iOS Assistants tab, complete with the
// streamed tool-use pills.
//
// Flow (per session):
//   Mac CLI bridge → CLIChatStreamEvent → `CLIAgentSessionMirror.append(...)`
//     → Firestore: users/{uid}/cli_sessions/{sessionID}
//   iOS Assistants tab → `CLIAgentChatReader.refresh()` → renders.
//
// Wire shape stays read-only on iOS this wave. Future waves can replace
// the read with a bi-directional transport.

/// Three CLI agent runtimes whose transcripts can be mirrored from the
/// user's Mac to their iOS app. The raw values are stable Firestore
/// tokens; iOS uses them to filter `cli_sessions` per tile.
public enum CLIAgentRuntime: String, Codable, Hashable, Sendable, CaseIterable {
    case codex
    case claude
    case openClaw = "openclaw"

    /// Map an `AssistantRuntimeID` to its CLI counterpart. `hermes` and
    /// `pi` are intentionally absent — they have their own first-class
    /// chat surfaces and are not mirrored through this path.
    public init?(assistant: AssistantRuntimeID) {
        switch assistant {
        case .codex:    self = .codex
        case .claude:   self = .claude
        case .openClaw: self = .openClaw
        case .hermes, .pi: return nil
        }
    }

    public var assistantRuntime: AssistantRuntimeID {
        switch self {
        case .codex:    return .codex
        case .claude:   return .claude
        case .openClaw: return .openClaw
        }
    }

    public var displayName: String {
        switch self {
        case .codex:    return "Codex"
        case .claude:   return "Claude Code"
        case .openClaw: return "OpenClaw"
        }
    }
}

/// One persisted CLI agent session, mirrored from a Mac chat into
/// Firestore for iOS visibility. Keys mirror `MobileChatThread` where the
/// shapes overlap so the iOS UI can render them with the same bubble
/// components.
public struct CLIAgentSessionRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var agent: CLIAgentRuntime
    public var sourceKind: CLIAgentSessionSourceKind
    public var title: String
    public var preview: String
    public var modelName: String?
    public var workspaceLabel: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var endedAt: Date?
    /// Wire-format schema version for forward compatibility. Bump when
    /// you change the shape; readers MUST tolerate unknown fields and
    /// MUST refuse versions newer than the one they were compiled for.
    public var schemaVersion: Int
    public var messages: [CLIAgentMessage]
    public var tokenUsage: CLIAgentTokenUsage?
    /// Optional local resume/fork handle. This never contains credentials.
    /// Mobile uses it to explain whether the paired Mac can continue the
    /// underlying Codex/Claude/OpenClaw session.
    public var resumeHandle: CLIAgentResumeHandle?
    /// True when the full transcript lives in the encrypted session-log
    /// cloud vault rather than plaintext `messages`.
    public var encryptedTranscriptAvailable: Bool

    public static let currentSchemaVersion = 1

    public init(
        id: String,
        agent: CLIAgentRuntime,
        sourceKind: CLIAgentSessionSourceKind = .liveChat,
        title: String,
        preview: String,
        modelName: String? = nil,
        workspaceLabel: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        endedAt: Date? = nil,
        schemaVersion: Int = CLIAgentSessionRecord.currentSchemaVersion,
        messages: [CLIAgentMessage] = [],
        tokenUsage: CLIAgentTokenUsage? = nil,
        resumeHandle: CLIAgentResumeHandle? = nil,
        encryptedTranscriptAvailable: Bool = false
    ) {
        self.id = id
        self.agent = agent
        self.sourceKind = sourceKind
        self.title = title
        self.preview = preview
        self.modelName = modelName
        self.workspaceLabel = workspaceLabel
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.endedAt = endedAt
        self.schemaVersion = schemaVersion
        self.messages = messages
        self.tokenUsage = tokenUsage
        self.resumeHandle = resumeHandle
        self.encryptedTranscriptAvailable = encryptedTranscriptAvailable
    }

    /// `true` when the session has been finalised — no more messages will
    /// be appended. iOS uses this to dim the "running" indicator.
    public var isCompleted: Bool { endedAt != nil }
}

/// Where the mirrored CLI session came from. Live chat rows stream from
/// OpenBurnBar's own Mac chat panel; archived log rows are parsed from
/// provider-owned Codex/Claude/OpenClaw history and point at the encrypted
/// cloud session-log body for search/reference.
public enum CLIAgentSessionSourceKind: String, Codable, Hashable, Sendable {
    case liveChat = "live_chat"
    case archivedLog = "archived_log"
}

/// Non-secret pointer that lets mobile display whether a CLI session can
/// be resumed/forked on the paired Mac. The Mac remains the executor; cloud
/// stores only stable IDs and user-facing command hints.
public struct CLIAgentResumeHandle: Codable, Hashable, Sendable {
    public var providerSessionID: String
    public var projectLabel: String?
    public var commandHint: String?
    public var canResume: Bool
    public var canFork: Bool
    public var canForward: Bool

    public init(
        providerSessionID: String,
        projectLabel: String? = nil,
        commandHint: String? = nil,
        canResume: Bool = false,
        canFork: Bool = false,
        canForward: Bool = true
    ) {
        self.providerSessionID = providerSessionID
        self.projectLabel = projectLabel
        self.commandHint = commandHint
        self.canResume = canResume
        self.canFork = canFork
        self.canForward = canForward
    }
}

/// One message in a mirrored CLI agent session.
public struct CLIAgentMessage: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var role: CLIAgentRole
    public var text: String
    public var timestamp: Date
    public var isError: Bool
    public var toolUses: [CLIAgentToolUse]

    public init(
        id: String,
        role: CLIAgentRole,
        text: String,
        timestamp: Date,
        isError: Bool = false,
        toolUses: [CLIAgentToolUse] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.isError = isError
        self.toolUses = toolUses
    }
}

/// Messages carry the same three roles the OpenAI / Anthropic APIs use.
/// `tool` is intentionally not exposed here — CLI agents emit tool uses
/// as substructures of an assistant turn, never as standalone messages.
public enum CLIAgentRole: String, Codable, Hashable, Sendable {
    case user
    case assistant
    case system
}

/// One tool the CLI agent invoked during an assistant turn. Schema
/// matches the existing `HermesToolCall` / `PiToolCall` shape so iOS can
/// route it through the same pill renderer.
public struct CLIAgentToolUse: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// Free-form status string: "running" / "done" / "failed" /
    /// runtime-specific labels. iOS reads it but never enforces a
    /// vocabulary so future runtimes can extend without breaking the
    /// reader.
    public var status: String
    /// Short human-readable summary of the invocation arguments — file
    /// path, command, query, etc. Capped at 200 UTF-8 characters before
    /// it lands in Firestore.
    public var detail: String?
    /// ISO-8601 timestamp the tool call was observed on the Mac.
    public var startedAt: Date

    public init(
        id: String,
        name: String,
        status: String,
        detail: String? = nil,
        startedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.detail = detail
        self.startedAt = startedAt
    }
}

/// Token usage rolled up across the session. Mirrors the macOS
/// `CLIUsageSnapshot` shape but flattens it for Firestore.
public struct CLIAgentTokenUsage: Codable, Hashable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationTokens: Int
    public var cacheReadTokens: Int
    public var reasoningTokens: Int

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0,
        reasoningTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.reasoningTokens = reasoningTokens
    }

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + reasoningTokens
    }

    public static let zero = CLIAgentTokenUsage()
}

// MARK: - Firestore Codec

/// Plain `[String: Any]` codec for `CLIAgentSessionRecord`. We avoid
/// `JSONEncoder/Decoder` round-tripping at the call site because Firestore's
/// SDK already accepts dictionary payloads and rejects unsupported types
/// (e.g. `Date` becomes `Timestamp`). Tests use the same codec to verify
/// round-trip integrity.
public enum CLIAgentSessionCodec {
    /// Decode a Firestore document body into a `CLIAgentSessionRecord`.
    /// Returns `nil` for documents missing required fields, sessions
    /// stamped with a schema version newer than this build, or sessions
    /// whose `agent` token isn't recognised — keeps the iOS app
    /// forward-tolerant when the Mac writer ships a new runtime first.
    public static func decode(
        documentID: String,
        data: [String: Any],
        timestampDecoder: (Any?) -> Date? = defaultTimestampDecoder
    ) -> CLIAgentSessionRecord? {
        let schemaVersion = (data["schemaVersion"] as? Int) ?? 1
        guard schemaVersion <= CLIAgentSessionRecord.currentSchemaVersion else {
            return nil
        }
        guard let rawAgent = data["agent"] as? String,
              let agent = CLIAgentRuntime(rawValue: rawAgent) else {
            return nil
        }
        let sourceKind = (data["sourceKind"] as? String)
            .flatMap(CLIAgentSessionSourceKind.init(rawValue:)) ?? .liveChat
        let id = (data["id"] as? String) ?? documentID
        let title = (data["title"] as? String) ?? "CLI session"
        let preview = (data["preview"] as? String) ?? ""
        let modelName = (data["modelName"] as? String).flatMap(nonBlank)
        let workspaceLabel = (data["workspaceLabel"] as? String).flatMap(nonBlank)
        let createdAt = timestampDecoder(data["createdAt"]) ?? Date()
        let updatedAt = timestampDecoder(data["updatedAt"]) ?? createdAt
        let endedAt = timestampDecoder(data["endedAt"])
        let rawMessages = data["messages"] as? [[String: Any]] ?? []
        let messages = rawMessages.compactMap { decodeMessage($0, timestampDecoder: timestampDecoder) }
        let tokenUsage = (data["tokenUsage"] as? [String: Any]).flatMap(decodeTokenUsage)
        let resumeHandle = (data["resumeHandle"] as? [String: Any]).flatMap(decodeResumeHandle)
        let encryptedTranscriptAvailable = (data["encryptedTranscriptAvailable"] as? Bool) ?? false
        return CLIAgentSessionRecord(
            id: id,
            agent: agent,
            sourceKind: sourceKind,
            title: title,
            preview: preview,
            modelName: modelName,
            workspaceLabel: workspaceLabel,
            createdAt: createdAt,
            updatedAt: updatedAt,
            endedAt: endedAt,
            schemaVersion: schemaVersion,
            messages: messages,
            tokenUsage: tokenUsage,
            resumeHandle: resumeHandle,
            encryptedTranscriptAvailable: encryptedTranscriptAvailable
        )
    }

    /// Encode a `CLIAgentSessionRecord` to the dictionary form
    /// Firestore's SDK accepts. Dates stay as `Date` values; the SDK
    /// converts them to `Timestamp` at the boundary.
    public static func encode(_ record: CLIAgentSessionRecord) -> [String: Any] {
        var dict: [String: Any] = [
            "id": record.id,
            "agent": record.agent.rawValue,
            "sourceKind": record.sourceKind.rawValue,
            "title": record.title,
            "preview": record.preview,
            "createdAt": record.createdAt,
            "updatedAt": record.updatedAt,
            "schemaVersion": record.schemaVersion,
            "messages": record.messages.map(encodeMessage),
            "encryptedTranscriptAvailable": record.encryptedTranscriptAvailable
        ]
        if let modelName = record.modelName, !modelName.isEmpty {
            dict["modelName"] = modelName
        }
        if let workspaceLabel = record.workspaceLabel, !workspaceLabel.isEmpty {
            dict["workspaceLabel"] = workspaceLabel
        }
        if let endedAt = record.endedAt {
            dict["endedAt"] = endedAt
        }
        if let usage = record.tokenUsage {
            dict["tokenUsage"] = encodeTokenUsage(usage)
        }
        if let resumeHandle = record.resumeHandle {
            dict["resumeHandle"] = encodeResumeHandle(resumeHandle)
        }
        return dict
    }

    public static func encodeMessage(_ message: CLIAgentMessage) -> [String: Any] {
        [
            "id": message.id,
            "role": message.role.rawValue,
            "text": message.text,
            "timestamp": message.timestamp,
            "isError": message.isError,
            "toolUses": message.toolUses.map(encodeToolUse)
        ]
    }

    public static func encodeToolUse(_ tool: CLIAgentToolUse) -> [String: Any] {
        var dict: [String: Any] = [
            "id": tool.id,
            "name": tool.name,
            "status": tool.status,
            "startedAt": tool.startedAt
        ]
        if let detail = tool.detail, !detail.isEmpty {
            dict["detail"] = detail
        }
        return dict
    }

    public static func encodeTokenUsage(_ usage: CLIAgentTokenUsage) -> [String: Any] {
        [
            "inputTokens": usage.inputTokens,
            "outputTokens": usage.outputTokens,
            "cacheCreationTokens": usage.cacheCreationTokens,
            "cacheReadTokens": usage.cacheReadTokens,
            "reasoningTokens": usage.reasoningTokens
        ]
    }

    public static func encodeResumeHandle(_ handle: CLIAgentResumeHandle) -> [String: Any] {
        var dict: [String: Any] = [
            "providerSessionID": handle.providerSessionID,
            "canResume": handle.canResume,
            "canFork": handle.canFork,
            "canForward": handle.canForward
        ]
        if let projectLabel = handle.projectLabel, !projectLabel.isEmpty {
            dict["projectLabel"] = projectLabel
        }
        if let commandHint = handle.commandHint, !commandHint.isEmpty {
            dict["commandHint"] = commandHint
        }
        return dict
    }

    public static func decodeMessage(
        _ raw: [String: Any],
        timestampDecoder: (Any?) -> Date? = defaultTimestampDecoder
    ) -> CLIAgentMessage? {
        guard let id = raw["id"] as? String,
              let roleRaw = raw["role"] as? String,
              let role = CLIAgentRole(rawValue: roleRaw),
              let text = raw["text"] as? String else {
            return nil
        }
        let timestamp = timestampDecoder(raw["timestamp"]) ?? Date()
        let isError = (raw["isError"] as? Bool) ?? false
        let rawTools = raw["toolUses"] as? [[String: Any]] ?? []
        let toolUses = rawTools.compactMap { decodeToolUse($0, timestampDecoder: timestampDecoder) }
        return CLIAgentMessage(
            id: id,
            role: role,
            text: text,
            timestamp: timestamp,
            isError: isError,
            toolUses: toolUses
        )
    }

    public static func decodeToolUse(
        _ raw: [String: Any],
        timestampDecoder: (Any?) -> Date? = defaultTimestampDecoder
    ) -> CLIAgentToolUse? {
        guard let id = raw["id"] as? String,
              let name = raw["name"] as? String,
              let status = raw["status"] as? String else {
            return nil
        }
        let detail = (raw["detail"] as? String).flatMap(nonBlank)
        let startedAt = timestampDecoder(raw["startedAt"]) ?? Date()
        return CLIAgentToolUse(
            id: id,
            name: name,
            status: status,
            detail: detail,
            startedAt: startedAt
        )
    }

    public static func decodeTokenUsage(_ raw: [String: Any]) -> CLIAgentTokenUsage {
        CLIAgentTokenUsage(
            inputTokens: intValue(raw["inputTokens"]),
            outputTokens: intValue(raw["outputTokens"]),
            cacheCreationTokens: intValue(raw["cacheCreationTokens"]),
            cacheReadTokens: intValue(raw["cacheReadTokens"]),
            reasoningTokens: intValue(raw["reasoningTokens"])
        )
    }

    public static func decodeResumeHandle(_ raw: [String: Any]) -> CLIAgentResumeHandle? {
        guard let providerSessionID = raw["providerSessionID"] as? String,
              !providerSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return CLIAgentResumeHandle(
            providerSessionID: providerSessionID,
            projectLabel: (raw["projectLabel"] as? String).flatMap(nonBlank),
            commandHint: (raw["commandHint"] as? String).flatMap(nonBlank),
            canResume: (raw["canResume"] as? Bool) ?? false,
            canFork: (raw["canFork"] as? Bool) ?? false,
            canForward: (raw["canForward"] as? Bool) ?? true
        )
    }

    private static func intValue(_ raw: Any?) -> Int {
        if let value = raw as? Int { return value }
        if let value = raw as? Double { return Int(value) }
        if let value = raw as? NSNumber { return value.intValue }
        return 0
    }

    private static func nonBlank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Default timestamp decoder for in-process round trips (tests).
    /// Treats `Date` straight through and `Double` as Unix epoch
    /// seconds; the Firebase-aware decoder lives in the iOS reader so
    /// Core stays SDK-free.
    public static let defaultTimestampDecoder: (Any?) -> Date? = { raw in
        if let date = raw as? Date { return date }
        if let value = raw as? Double { return Date(timeIntervalSince1970: value) }
        if let value = raw as? Int { return Date(timeIntervalSince1970: TimeInterval(value)) }
        return nil
    }
}

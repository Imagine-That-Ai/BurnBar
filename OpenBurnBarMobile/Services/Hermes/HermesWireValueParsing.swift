import Foundation
import OpenBurnBarCore

/// Tolerant JSON value coercion + control-plane response parsing shared by
/// the Hermes wire decoders.
///
/// `HermesService` (session / session-message / profile / job / model
/// catalog parsing) and `HermesStreamingEngine` (SSE event handling) both
/// consume loosely-shaped JSON from Hermes runtimes that disagree on field
/// naming and value types. All bodies were moved verbatim from
/// `HermesService` so both sides keep byte-identical behavior.
@MainActor
enum HermesWireValueParsing {
    static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        return nil
    }

    static func modelNameValue(item: [String: Any]) -> String? {
        stringValue(item["model"])
            ?? stringValue(item["model_id"])
            ?? stringValue(item["modelId"])
            ?? stringValue(item["model_name"])
            ?? stringValue(item["modelName"])
            ?? stringValue(item["selected_model"])
            ?? stringValue(item["selectedModel"])
    }

    static func tokenCountSourceValue(_ value: Any?) -> HermesTokenCountSource? {
        guard let rawValue = stringValue(value) else { return nil }
        if let source = HermesTokenCountSource(rawValue: rawValue) {
            return source
        }
        switch rawValue.lowercased() {
        case "provider", "provider_usage", "exact":
            return .providerUsage
        case "estimated", "estimated_text", "approximate":
            return .estimatedText
        default:
            return nil
        }
    }

    static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value) }
        return nil
    }

    static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }

    static func dateValue(_ value: Any?) -> Date? {
        if let value = value as? Date { return value }
        if let value = value as? TimeInterval { return Date(timeIntervalSince1970: value) }
        guard let value = value as? String else { return nil }
        return Self.iso8601WithFractionalSeconds.date(from: value) ?? Self.iso8601.date(from: value)
    }

    private static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601 = ISO8601DateFormatter()

    // MARK: - Control-plane response parsing (sessions / transcripts / profiles / jobs)

    static func parseSessions(from data: Data) -> [HermesSessionSummary] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let rawSessions: [[String: Any]]
        if let array = object as? [[String: Any]] {
            rawSessions = array
        } else if let dict = object as? [String: Any],
                  let array = dict["sessions"] as? [[String: Any]] {
            rawSessions = array
        } else {
            rawSessions = []
        }

        return rawSessions.compactMap { item in
            let id = stringValue(item["id"]) ?? stringValue(item["session_id"]) ?? stringValue(item["sessionId"])
            guard let id, !id.isEmpty else { return nil }
            return HermesSessionSummary(
                id: id,
                title: stringValue(item["title"]),
                preview: stringValue(item["preview"]) ?? stringValue(item["summary"]),
                source: stringValue(item["source"]),
                model: modelNameValue(item: item),
                startedAt: dateValue(item["started_at"]) ?? dateValue(item["created_at"]) ?? dateValue(item["createdAt"]),
                lastActiveAt: dateValue(item["last_active_at"]) ?? dateValue(item["updated_at"]) ?? dateValue(item["updatedAt"]),
                endedAt: dateValue(item["ended_at"]),
                isActive: boolValue(item["is_active"]) ?? boolValue(item["active"]) ?? false,
                messageCount: intValue(item["message_count"]) ?? intValue(item["messageCount"]) ?? 0,
                toolCallCount: intValue(item["tool_call_count"]) ?? intValue(item["toolCallCount"]) ?? 0,
                inputTokens: intValue(item["input_tokens"]) ?? intValue(item["inputTokens"]) ?? 0,
                outputTokens: intValue(item["output_tokens"]) ?? intValue(item["outputTokens"]) ?? 0
            )
        }
    }

    static func parseSessionMessages(from data: Data) -> [HermesChatMessage] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let rawMessages: [[String: Any]]
        if let array = object as? [[String: Any]] {
            rawMessages = array
        } else if let dict = object as? [String: Any] {
            rawMessages = (dict["messages"] as? [[String: Any]])
                ?? (dict["turns"] as? [[String: Any]])
                ?? (dict["events"] as? [[String: Any]])
                ?? []
        } else {
            rawMessages = []
        }
        return rawMessages.compactMap { item in
            guard let roleText = stringValue(item["role"]) ?? stringValue(item["type"]),
                  let role = HermesChatRole(rawValue: roleText) else {
                return nil
            }
            let content = stringValue(item["content"])
                ?? stringValue(item["text"])
                ?? stringValue(item["message"])
                ?? ""
            guard !content.isEmpty || role == .assistant else { return nil }
            let resolvedModel = role == .assistant ? modelNameValue(item: item) : nil
            return HermesChatMessage(
                id: stringValue(item["id"]) ?? UUID().uuidString,
                role: role,
                text: content,
                requestedModelID: stringValue(item["requested_model_id"])
                    ?? stringValue(item["requestedModelId"])
                    ?? stringValue(item["requested_model"]),
                responseModelID: role == .assistant ? resolvedModel : nil,
                modelName: resolvedModel,
                timestamp: dateValue(item["timestamp"]) ?? dateValue(item["created_at"]) ?? Date(),
                isStreaming: false,
                isError: false,
                responseStartedAt: dateValue(item["response_started_at"]) ?? dateValue(item["responseStartedAt"]),
                firstResponseChunkAt: dateValue(item["first_response_chunk_at"]) ?? dateValue(item["firstResponseChunkAt"]),
                responseCompletedAt: dateValue(item["response_completed_at"]) ?? dateValue(item["responseCompletedAt"]),
                outputTokenCount: intValue(item["output_tokens"]) ?? intValue(item["outputTokens"]) ?? intValue(item["completion_tokens"]) ?? intValue(item["completionTokens"]),
                totalTokenCount: intValue(item["total_tokens"]) ?? intValue(item["totalTokens"]),
                tokenCountSource: tokenCountSourceValue(item["token_count_source"]) ?? tokenCountSourceValue(item["tokenCountSource"])
            )
        }
    }

    static func parseProfiles(from data: Data) -> [HermesRuntimeProfile] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let rawProfiles: [[String: Any]]
        if let array = object as? [[String: Any]] {
            rawProfiles = array
        } else if let dict = object as? [String: Any],
                  let array = dict["profiles"] as? [[String: Any]] {
            rawProfiles = array
        } else {
            rawProfiles = []
        }

        return rawProfiles.compactMap { item in
            guard let name = stringValue(item["name"]) ?? stringValue(item["id"]) else { return nil }
            return HermesRuntimeProfile(
                name: name,
                model: stringValue(item["model"]),
                provider: stringValue(item["provider"]),
                skillCount: intValue(item["skill_count"]) ?? intValue(item["skillCount"]) ?? 0
            )
        }
    }

    static func parseJobs(from data: Data) -> [HermesRuntimeJob] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let rawJobs: [[String: Any]]
        if let array = object as? [[String: Any]] {
            rawJobs = array
        } else if let dict = object as? [String: Any],
                  let array = dict["jobs"] as? [[String: Any]] {
            rawJobs = array
        } else {
            rawJobs = []
        }

        return rawJobs.compactMap { item in
            let id = stringValue(item["id"]) ?? stringValue(item["job_id"]) ?? stringValue(item["jobId"])
            guard let id else { return nil }
            return HermesRuntimeJob(
                id: id,
                name: stringValue(item["name"]),
                prompt: stringValue(item["prompt"]) ?? stringValue(item["description"]) ?? "Hermes job",
                scheduleDisplay: stringValue(item["schedule"]) ?? stringValue(item["cron"]),
                state: stringValue(item["state"]) ?? stringValue(item["status"]) ?? "unknown",
                enabled: boolValue(item["enabled"]) ?? true,
                lastRunAt: dateValue(item["last_run_at"]) ?? dateValue(item["lastRunAt"]),
                nextRunAt: dateValue(item["next_run_at"]) ?? dateValue(item["nextRunAt"]),
                lastError: stringValue(item["last_error"]) ?? stringValue(item["lastError"])
            )
        }
    }

    // MARK: - /v1/models catalog parsing

    /// Decodes an OpenAI-compatible `/v1/models` response body into the
    /// runtime model options the catalog UI binds to. Decode behavior is
    /// byte-identical to the inline `JSONDecoder().decode(...)` +
    /// `modelOptions(from:)` pair this replaces.
    static func parseModelOptions(from data: Data) throws -> [HermesRuntimeModelOption] {
        let decoded = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
        return modelOptions(from: decoded.data)
    }

    static func mergedModelOptions(
        primary: [HermesRuntimeModelOption],
        secondary: [HermesRuntimeModelOption]
    ) -> [HermesRuntimeModelOption] {
        var seen = Set<String>()
        var merged: [HermesRuntimeModelOption] = []
        for option in primary + secondary where seen.insert(option.modelID).inserted {
            merged.append(option)
        }
        return merged
    }

    private static func modelOptions(from models: [OpenAIModel]) -> [HermesRuntimeModelOption] {
        models.map { model in
            let provider = providerMetadata(for: model)
            return HermesRuntimeModelOption(
                providerID: provider.id,
                providerName: provider.name,
                modelID: model.id,
                displayName: model.displayName ?? model.name ?? providerDisplayName(forModelID: model.id),
                accountID: model.accountID,
                accountLabel: model.accountLabel,
                sourceID: model.sourceID,
                sourceKind: model.sourceKind,
                capabilities: model.capabilities ?? [],
                modelCapabilities: model.modelCapabilities,
                quotaState: model.quotaState,
                routeEligible: model.routeEligible,
                lastRefreshAt: model.lastRefreshAt,
                lastError: model.lastError
            )
        }
    }

    private static func providerMetadata(for model: OpenAIModel) -> (id: String, name: String) {
        let rawProviderID = model.providerID ?? model.ownedBy ?? "hermes"
        let searchText = [
            model.providerID,
            model.ownedBy,
            model.providerName,
            model.id,
            model.displayName,
            model.name
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        if searchText.contains("minimax") || searchText.contains("abab") {
            return ("minimax", "MiniMax")
        }
        if searchText.contains("zai") || searchText.contains("z.ai") || searchText.contains("zhipu") || searchText.contains("glm") {
            return ("zai", "Z.AI / GLM")
        }
        if searchText.contains("kimi") || searchText.contains("moonshot") {
            return ("kimi-coding", "Kimi / Kimi Coding Plan")
        }
        if searchText.contains("ollama-local") || searchText.contains("ollama local") {
            return ("ollama-local", "Ollama Local")
        }
        if searchText.contains("lmstudio-local") || searchText.contains("lm studio") || searchText.contains("lmstudio") {
            return ("lmstudio-local", "LM Studio Local")
        }
        if searchText.contains("local-openai") || searchText.contains("openai compatible local") {
            return ("local-openai", "Local OpenAI-Compatible")
        }

        let providerName = model.providerName
            ?? AgentProvider.fromProviderID(ProviderID(rawValue: rawProviderID))?.displayName
            ?? rawProviderID
        return (rawProviderID, providerName)
    }

    private static func providerDisplayName(forModelID modelID: String) -> String {
        modelID
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { token in
                if token.uppercased() == token { return String(token) }
                return token.prefix(1).uppercased() + String(token.dropFirst())
            }
            .joined(separator: " ")
    }
}

// MARK: - /v1/models wire shapes (moved verbatim from HermesService.swift)

private struct OpenAIModelsResponse: Decodable {
    var data: [OpenAIModel]
}

private struct OpenAIModel: Decodable {
    var id: String
    var ownedBy: String?
    var providerID: String?
    var providerName: String?
    var displayName: String?
    var name: String?
    var accountID: String?
    var accountLabel: String?
    var sourceID: String?
    var sourceKind: String?
    var capabilities: [String]?
    var modelCapabilities: ModelIOCapabilities?
    var quotaState: String?
    var routeEligible: Bool?
    var lastRefreshAt: Date?
    var lastError: String?

    enum CodingKeys: String, CodingKey {
        case id
        case ownedBy = "owned_by"
        case providerID = "provider_id"
        case providerName = "provider_name"
        case displayName = "display_name"
        case name
        case accountID = "account_id"
        case accountLabel = "account_label"
        case sourceID = "source_id"
        case sourceKind = "source_kind"
        case capabilities
        case modelCapabilities = "model_capabilities"
        case quotaState = "quota_state"
        case routeEligible = "route_eligible"
        case lastRefreshAt = "last_refresh_at"
        case lastError = "last_error"
    }
}

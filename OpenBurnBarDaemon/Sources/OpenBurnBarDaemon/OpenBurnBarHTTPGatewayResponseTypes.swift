// Gateway response & value types — the DTOs the HTTP gateway server emits and
// the small value types its pipeline passes around. Extracted from
// OpenBurnBarHTTPGatewayServer.swift so the server class is behavior, not data.
// Kept nested on BurnBarHTTPGatewayServer (qualified names unchanged); widened
// from `private` to module-internal only so this extension can hold them.

import OpenBurnBarEngine
import OpenBurnBarKernel
import CryptoKit
import Foundation
import Network

extension BurnBarHTTPGatewayServer {

    /// Detect when the inbound wire id refers to a thinking-level variant
    /// (e.g. `claude-opus-4-7-xhigh`) or a user-defined alias (`my-coder`) and
    /// resolve it back to the base model the router knows how to score.
    struct GatewayProxyModelOverride {
        let requestedModel: GatewayRequestedModel
        let advertisedRequestedModel: GatewayRequestedModel
        let variant: BurnBarModelVariant?
        let alias: BurnBarModelAlias?
    }

    struct GatewayAdvertisedRouteResolution {
        let requestedModel: GatewayRequestedModel
        let advertisedRequestedModel: GatewayRequestedModel
        let routeKeysByFamily: [BurnBarProviderFormatFamily: Set<String>]
    }

    struct GatewayModelCatalogEntry {
        let model: BurnBarLiveAdvertisedModel
        let advertised: Bool
    }

    struct GatewayModelCatalogGroup {
        let providerID: String
        let normalizedModelID: String
        var entries: [GatewayModelCatalogEntry]

        var representative: BurnBarLiveAdvertisedModel {
            entries.first(where: { $0.advertised })?.model ?? entries[0].model
        }

        var advertised: Bool {
            entries.contains { $0.advertised }
        }
    }

    struct GatewayRequestedModel {
        let originalID: String
        let modelID: String
        let providerID: String?
        let accountID: String?
    }

    /// Everything that differs between the three model-serving endpoints
    /// (`/v1/chat/completions`, `/v1/responses`, `/v1/messages`), so
    /// `routeModelRequest` can drive the shared route-resolve → attempt-loop →
    /// fail-over → usage-record sequence for all of them (finding-16/63).
    struct GatewayEndpointDescriptor {
        /// Request path as served (e.g. "/v1/chat/completions").
        let requestPath: String
        /// Human-readable endpoint name for route-log entries.
        let endpoint: String
        /// Logger event name when routing throws.
        let routeErrorLogEvent: String
        /// Category for the per-request provider-router logger.
        let routerLoggerCategory: String
        /// Forwarded to `BurnBarProviderRouter.init`.
        let allowDynamicOpenAICompatibleModels: Bool
        /// `true` maps a thrown `BurnBarProviderRouterError` to the 503
        /// no-eligible-route response (chat/responses); `false` lets it fall
        /// through to the generic 502 routing-failure response (Anthropic).
        let treatsRouterErrorAsNoEligibleRoute: Bool
        /// `true` stamps the final no-eligible-route record with the ranking's
        /// required canonical model ID (Anthropic); `false` uses the
        /// catalog-derived requested canonical ID (chat/responses).
        let finalRejectUsesRankingCanonicalModelID: Bool
        /// Decodes the endpoint's wire request far enough for routing: the
        /// model slug and whether the client asked for a streamed response.
        let decodeRequest: (Data) throws -> GatewayDecodedModelRequest
        /// Chooses the format families to attempt (in order), or rejects the
        /// request up front (Anthropic without an Anthropic-family route).
        /// Receives the advertised route keys by family, the (post-resolution)
        /// requested model, and the client's model slug for error copy.
        let selectFormatFamilies: (
            [BurnBarProviderFormatFamily: Set<String>],
            GatewayRequestedModel,
            String
        ) -> GatewayFormatFamilySelection
        /// Endpoint-specific narrowing of the ranked routes (e.g. Anthropic
        /// account pinning), applied before the advertised-route-key filter.
        let filterRankedRoutes: ([BurnBarProviderRoute], GatewayRequestedModel) -> [BurnBarProviderRoute]
        /// When non-nil, an empty ranked-route set rejects the request with
        /// the returned log message and response instead of moving on to the
        /// next format family.
        let emptyRankedRoutesRejection: ((String) -> (failureMessage: String, response: GatewayHTTPResponse))?
        /// Verbatim SSE passthrough plan for one attempt, or nil to serve the
        /// attempt on the buffered path.
        let streamAttempt: (GatewayRouteAttemptContext) -> GatewayStreamAttemptPlan?
        /// Buffered (non-streaming) proxy call for one attempt.
        let proxyBuffered: (GatewayRouteAttemptContext) async throws -> BurnBarProviderProxyResponse
        /// Cross-vendor degrade safety net (chat only, Part B3).
        let attemptDegrade: ((GatewayDegradeRequest) async -> GatewayDegradeAttemptResult?)?
    }

    /// The routing-relevant fields of a decoded model-endpoint request.
    struct GatewayDecodedModelRequest {
        let model: String
        let wantsStream: Bool
    }

    enum GatewayFormatFamilySelection {
        case families([BurnBarProviderFormatFamily])
        case reject(failureMessage: String)
    }

    /// Inputs available to one route attempt inside the shared pipeline.
    struct GatewayRouteAttemptContext {
        let bodyData: Data
        let route: BurnBarProviderRoute
        let formatFamily: BurnBarProviderFormatFamily
        let wantsStream: Bool
        let variant: BurnBarModelVariant?
    }

    /// How to relay one attempt as a verbatim SSE stream.
    struct GatewayStreamAttemptPlan {
        let usageFormat: GatewayStreamUsageFormat
        let openStream: () async throws -> BurnBarProviderProxyStream
    }

    /// Pipeline state handed to the cross-vendor degrade hook.
    struct GatewayDegradeRequest {
        let bodyData: Data
        let accountingRequestID: String
        let executionSource: UsageExecutionSource
        let modelID: String
        let startedAt: Date
        let requestPath: String
        let endpoint: String
        let advertisedModelSlug: String?
        let routingModelSlug: String?
        let requestedCanonicalModelID: String?
        let priorAttempts: [BurnBarProxyRouteAttempt]
    }

    /// Result of validating/decoding the request body and resolving any proxy
    /// model override. `.rejected` carries the exact early-return response the
    /// original inline guards produced; `.resolved` carries the initial routing
    /// state the rest of the pipeline reads/mutates.
    struct GatewayResolvedModelRequest {
        let bodyData: Data
        let modelID: String
        let wantsStream: Bool
        let requestedModel: GatewayRequestedModel
        let advertisedRequestedModel: GatewayRequestedModel
        let resolvedVariant: BurnBarModelVariant?
        let logContext: GatewayRequestContext
    }

    enum GatewayModelRequestParse {
        case rejected(GatewayRouteOutcome)
        case resolved(GatewayResolvedModelRequest)
    }

    /// remediation(gateway split): the request-stable inputs shared by every
    /// route attempt in one `routeModelRequest` call. Bundling them keeps
    /// `attemptSingleRoute` to a readable parameter count (the per-attempt and
    /// `inout` accumulators stay explicit). These never change across the
    /// route/format-family loops, so passing them as one value is equivalent to
    /// the former inline closure captures.
    struct GatewayRoutePipeline {
        let descriptor: GatewayEndpointDescriptor
        let connection: NWConnection?
        let corsHeaders: [String: String]
        let bodyData: Data
        let wantsStream: Bool
        let resolvedVariant: BurnBarModelVariant?
        let accountingRequestID: String
        let executionSource: UsageExecutionSource
        let requestedModel: GatewayRequestedModel
        let logContext: GatewayRequestContext
        /// Memory Pro purpose, when the request declared one.
        let purpose: GatewayPurpose?
    }

    /// Control-flow signal returned by `attemptSingleRoute` so the caller's loop
    /// can reproduce the original `return` / `continue` / `break` behavior.
    enum GatewaySingleRouteOutcome {
        /// The attempt produced a final response; return it from the pipeline.
        case completed(GatewayRouteOutcome)
        /// The attempt failed; the loop should move on to the next candidate.
        case failedTryNext
        /// The attempt failed terminally; the loop should stop trying candidates.
        case failedStop
    }

    struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: String?
    }

    struct ParsedRequestHead {
        let method: String
        let path: String
        let headers: [String: String]
        let contentLength: Int
    }

    enum HTTPRequestReadError: Error {
        case invalidRequest
        case payloadTooLarge
    }

    struct GatewayHTTPResponse {
        let status: Int
        let headers: [String: String]
        let body: Data

        func withHeaders(_ headers: [String: String]) -> GatewayHTTPResponse {
            GatewayHTTPResponse(status: status, headers: headers, body: body)
        }
    }

    /// The result of routing a request: either a fully-buffered response the
    /// caller should write, or a stream the relay has already written directly
    /// to the connection (so the caller only needs to close it).
    enum GatewayRouteOutcome {
        case buffered(GatewayHTTPResponse)
        case streamed
    }

    struct GatewayStreamRelayResult {
        let outcome: GatewayRouteOutcome
        let usage: BurnBarProviderProxyUsage?
        let headers: [String: String]
        let interrupted: Bool
        let httpStatus: Int
    }

    struct GatewayDegradeAttemptResult {
        let outcome: GatewayRouteOutcome?
        let attempts: [BurnBarProxyRouteAttempt]
    }

    struct HealthResponse: Encodable {
        let ok: Bool
        let version: String
    }

    struct GatewayErrorResponse: Encodable {
        let error: String
    }

    struct ModelsResponse: Encodable {
        let object = "list"
        let data: [ModelDescriptor]
        let models: [CodexModelDescriptor]

        init(data: [ModelDescriptor]) {
            self.data = data
            self.models = data.map(CodexModelDescriptor.init(model:))
        }
    }

    struct ModelDescriptor: Encodable {
        let id: String
        let object = "model"
        let ownedBy: String
        let providerID: String
        let providerName: String
        let accountID: String
        let accountLabel: String
        let sourceID: String
        let sourceKind: String
        let servedBy: String
        let usageLane: String?
        let nativeStreaming: Bool
        let displayName: String
        /// `true` when `displayName` is a verbatim user rename emitted as-is
        /// (no provider/route/reasoning suffixes). Lets clients badge it.
        let displayNameIsCustom: Bool
        let capabilities: [String]
        let modelCapabilities: ModelIOCapabilities?
        let formatFamily: String
        let servedEndpoints: [String]
        let quotaState: String
        let accountCount: Int
        let enabled: Bool
        let advertisementEnabled: Bool
        let advertised: Bool
        let routeEligible: Bool
        let lastRefreshAt: Date?
        let lastError: String?
        let baseModelID: String?
        let thinkingLevel: String?
        let hidesBaseModel: Bool?

        init(group: GatewayModelCatalogGroup, advertisedID: String, advertised: Bool? = nil) {
            let representative = group.representative
            let entries = group.entries
            let models = entries.map(\.model)
            let accountIDs = Self.uniqueNonEmpty(models.map(\.accountID))
            let accountLabels = Self.uniqueNonEmpty(models.map(\.accountLabel))
            let accountCount = max(1, accountIDs.count)
            let capabilities = Self.mergedCapabilities(from: models)
            let modelCapabilities = Self.mergedModelCapabilities(from: models)
            let formatFamily = Self.formatFamily(from: capabilities)
            let rawDisplayName = Self.displayName(
                representative: representative,
                accountLabels: accountLabels
            )
            let thinkingLevel = models.compactMap(\.thinkingLevel).first

            self.id = advertisedID
            self.ownedBy = representative.providerID
            self.providerID = representative.providerID
            self.providerName = representative.providerName
            self.accountID = accountCount > 1 ? "auto" : representative.accountID
            self.accountLabel = Self.accountLabel(
                representative: representative,
                accountLabels: accountLabels,
                accountCount: accountCount
            )
            self.sourceID = accountCount > 1
                ? "\(representative.providerID)#auto"
                : representative.sourceID
            self.sourceKind = Self.sourceKind(from: models)
            self.servedBy = Self.servedBy(from: models)
            self.usageLane = Self.usageLane(from: models)
            self.nativeStreaming = !models.allSatisfy { Self.isFactoryModel($0) }
            let isCustomDisplayName = models.contains(where: { $0.displayNameIsCustom == true })
            self.displayNameIsCustom = isCustomDisplayName
            self.displayName = isCustomDisplayName
                ? rawDisplayName
                : OpenBurnBarModelDisplayName.compose(
                    modelName: rawDisplayName,
                    providerName: representative.providerName,
                    providerID: representative.providerID,
                    reasoningLevel: thinkingLevel
                )
            self.capabilities = capabilities
            self.modelCapabilities = modelCapabilities
            self.formatFamily = formatFamily.rawValue
            self.servedEndpoints = Self.servedEndpoints(for: formatFamily)
            self.quotaState = Self.quotaState(from: entries).rawValue
            self.accountCount = accountCount
            self.enabled = models.contains { $0.enabled }
            self.advertisementEnabled = models.contains { $0.advertisementEnabled }
            self.advertised = advertised ?? group.advertised
            self.routeEligible = models.contains { $0.routeEligible }
            self.lastRefreshAt = models.compactMap(\.lastRefreshAt).max()
            self.lastError = models.compactMap(\.lastError).first
            self.baseModelID = models.compactMap(\.baseModelID).first
            self.thinkingLevel = thinkingLevel
            self.hidesBaseModel = models.compactMap(\.hidesBaseModel).first
        }

        private static func formatFamily(from capabilities: [String]) -> BurnBarProviderFormatFamily {
            if capabilities.contains(BurnBarProviderFormatFamily.anthropic.rawValue) {
                return .anthropic
            }
            return .openaiCompat
        }

        private static func servedEndpoints(for formatFamily: BurnBarProviderFormatFamily) -> [String] {
            switch formatFamily {
            case .openaiCompat:
                return ["/v1/models", "/v1/messages", "/v1/chat/completions", "/v1/responses"]
            case .anthropic:
                return ["/v1/models", "/v1/messages", "/v1/chat/completions", "/v1/responses"]
            }
        }

        private static func mergedCapabilities(from models: [BurnBarLiveAdvertisedModel]) -> [String] {
            var seen: Set<String> = []
            var merged: [String] = []
            for capability in models.flatMap(\.capabilities) {
                let normalized = capability.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
                merged.append(capability)
            }
            return merged
        }

        private static func mergedModelCapabilities(from models: [BurnBarLiveAdvertisedModel]) -> ModelIOCapabilities? {
            let values = models.compactMap(\.modelCapabilities)
            guard let first = values.first else { return nil }
            guard values.count > 1 else { return first }

            return ModelIOCapabilities(
                schemaVersion: first.schemaVersion,
                inputModalities: intersection(values.map(\.inputModalities), fallback: first.inputModalities),
                outputModalities: intersection(values.map(\.outputModalities), fallback: first.outputModalities),
                supportedParameters: union(values.map(\.supportedParameters)),
                contextWindowTokens: values.compactMap(\.contextWindowTokens).min(),
                maxOutputTokens: values.compactMap(\.maxOutputTokens).min(),
                acceptedInputMimeTypes: intersection(
                    values.map(\.acceptedInputMimeTypes).filter { !$0.isEmpty },
                    fallback: first.acceptedInputMimeTypes
                ),
                imageMaxBytes: values.compactMap(\.imageMaxBytes).min(),
                audioMaxBytes: values.compactMap(\.audioMaxBytes).min(),
                videoMaxBytes: values.compactMap(\.videoMaxBytes).min(),
                sourceRefs: first.sourceRefs
            )
        }

        private static func intersection(_ lists: [[String]], fallback: [String]) -> [String] {
            guard let first = lists.first, !first.isEmpty else { return fallback }
            let remaining = lists.dropFirst().map { Set($0.map { $0.lowercased() }) }
            let result = first.filter { value in
                remaining.allSatisfy { $0.contains(value.lowercased()) }
            }
            return result.isEmpty ? fallback : result
        }

        private static func union(_ lists: [[String]]) -> [String] {
            var seen: Set<String> = []
            var result: [String] = []
            for value in lists.flatMap({ $0 }) {
                let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
                result.append(value)
            }
            return result
        }

        private static func quotaState(from entries: [GatewayModelCatalogEntry]) -> BurnBarLiveModelQuotaState {
            if let advertised = entries.first(where: { $0.advertised })?.model.quotaState {
                return advertised
            }
            if let eligible = entries.first(where: { $0.model.routeEligible })?.model.quotaState {
                return eligible
            }
            return entries.first?.model.quotaState ?? .unknown
        }

        private static func sourceKind(from models: [BurnBarLiveAdvertisedModel]) -> String {
            let sourceKinds = uniqueNonEmpty(models.map(\.sourceKind))
            return sourceKinds.count == 1 ? sourceKinds[0] : "gateway_failover_pool"
        }

        private static func servedBy(from models: [BurnBarLiveAdvertisedModel]) -> String {
            if models.allSatisfy({ isFactoryModel($0) }) {
                return "Factory Droid CLI"
            }
            let providerNames = uniqueNonEmpty(models.map(\.providerName))
            return providerNames.count == 1 ? providerNames[0] : "OpenBurnBar failover pool"
        }

        private static func usageLane(from models: [BurnBarLiveAdvertisedModel]) -> String? {
            guard models.allSatisfy({ isFactoryModel($0) }) else { return nil }
            let lanes = uniqueNonEmpty(models.map { model in
                FactoryDroidProviderExecutor.isStandardModel(model.baseModelID ?? model.id)
                    ? "standard"
                    : "droid_core"
            })
            return lanes.count == 1 ? lanes[0] : "mixed"
        }

        private static func isFactoryModel(_ model: BurnBarLiveAdvertisedModel) -> Bool {
            model.providerID.caseInsensitiveCompare("factory") == .orderedSame
        }

        private static func accountLabel(
            representative: BurnBarLiveAdvertisedModel,
            accountLabels: [String],
            accountCount: Int
        ) -> String {
            guard accountCount > 1 else {
                return representative.accountLabel
            }
            return "Auto failover (\(accountCount) accounts)"
        }

        private static func displayName(
            representative: BurnBarLiveAdvertisedModel,
            accountLabels: [String]
        ) -> String {
            var displayName = representative.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if displayName.isEmpty {
                displayName = representative.id
            }
            for label in accountLabels where !label.isEmpty {
                let suffix = " (\(label))"
                if displayName.hasSuffix(suffix) {
                    displayName.removeLast(suffix.count)
                    displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return displayName
        }

        private static func uniqueNonEmpty(_ values: [String]) -> [String] {
            var seen: Set<String> = []
            var unique: [String] = []
            for value in values {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalized = trimmed.lowercased()
                guard !trimmed.isEmpty, seen.insert(normalized).inserted else { continue }
                unique.append(trimmed)
            }
            return unique
        }

        enum CodingKeys: String, CodingKey {
            case id
            case object
            case ownedBy = "owned_by"
            case providerID = "provider_id"
            case providerName = "provider_name"
            case accountID = "account_id"
            case accountLabel = "account_label"
            case sourceID = "source_id"
            case sourceKind = "source_kind"
            case servedBy = "served_by"
            case usageLane = "usage_lane"
            case nativeStreaming = "native_streaming"
            case displayName = "display_name"
            case displayNameIsCustom = "display_name_is_custom"
            case capabilities
            case modelCapabilities = "model_capabilities"
            case formatFamily = "format_family"
            case servedEndpoints = "served_endpoints"
            case quotaState = "quota_state"
            case accountCount = "account_count"
            case enabled
            case advertisementEnabled = "advertisement_enabled"
            case advertised
            case routeEligible = "route_eligible"
            case lastRefreshAt = "last_refresh_at"
            case lastError = "last_error"
            case baseModelID = "base_model_id"
            case thinkingLevel = "thinking_level"
            case hidesBaseModel = "hides_base_model"
        }
    }

    struct CodexModelDescriptor: Encodable {
        let slug: String
        let displayName: String
        let description: String?
        let defaultReasoningLevel: String?
        let supportedReasoningLevels: [ReasoningLevel]
        let shellType: String
        let visibility: String
        let supportedInAPI: Bool
        let priority: Int
        let additionalSpeedTiers: [String]
        let serviceTiers: [String]
        let availabilityNux: String?
        let upgrade: String?
        let baseInstructions: String
        let modelMessages: String?
        let supportsReasoningSummaries: Bool
        let defaultReasoningSummary: String
        let supportVerbosity: Bool
        let defaultVerbosity: String?
        let applyPatchToolType: String?
        let webSearchToolType: String
        let truncationPolicy: TruncationPolicy
        let supportsParallelToolCalls: Bool
        let supportsImageDetailOriginal: Bool
        let contextWindow: Int
        let maxContextWindow: Int?
        let autoCompactTokenLimit: Int?
        let effectiveContextWindowPercent: Int
        let experimentalSupportedTools: [String]
        let inputModalities: [String]
        let supportsSearchTool: Bool

        init(model: ModelDescriptor) {
            let contextWindow = Self.contextWindow(for: model)
            self.slug = model.id
            self.displayName = model.displayName
            if model.accountCount > 1 {
                self.description = "\(model.providerName) via OpenBurnBar auto failover across \(model.accountCount) accounts"
            } else {
                self.description = "\(model.providerName) via OpenBurnBar"
            }
            self.defaultReasoningLevel = nil
            self.supportedReasoningLevels = []
            self.shellType = "shell_command"
            self.visibility = "list"
            self.supportedInAPI = true
            self.priority = 10_000
            self.additionalSpeedTiers = []
            self.serviceTiers = []
            self.availabilityNux = nil
            self.upgrade = nil
            self.baseInstructions = "You are Codex, a coding agent."
            self.modelMessages = nil
            self.supportsReasoningSummaries = false
            self.defaultReasoningSummary = "auto"
            self.supportVerbosity = false
            self.defaultVerbosity = nil
            self.applyPatchToolType = nil
            self.webSearchToolType = "text"
            self.truncationPolicy = TruncationPolicy(mode: "tokens", limit: contextWindow)
            self.supportsParallelToolCalls = false
            self.supportsImageDetailOriginal = model.modelCapabilities?.supportsImageInput ?? false
            self.contextWindow = contextWindow
            self.maxContextWindow = contextWindow
            self.autoCompactTokenLimit = nil
            self.effectiveContextWindowPercent = 95
            self.experimentalSupportedTools = []
            self.inputModalities = model.modelCapabilities?.inputModalities ?? ["text"]
            self.supportsSearchTool = false
        }

        /// Advertised when we have no discovered limit for a route.
        ///
        /// Deliberately small: a client that believes it has more room than the
        /// upstream allows only finds out by failing a request, while a client
        /// that believes it has less compacts early and still works.
        static let unknownContextWindowFallback = 65_536

        private static func contextWindow(for model: ModelDescriptor) -> Int {
            advertisedContextWindow(
                formatFamily: model.formatFamily,
                modelID: model.id,
                declaredContextWindowTokens: model.modelCapabilities?.contextWindowTokens
            )
        }

        /// Context window advertised to Codex-compatible clients.
        ///
        /// Clients use this number to decide when to truncate and compact, so a
        /// generous guess is not a neutral default: tell an 8K/128K/400K route it
        /// has a million tokens and the conversation grows past the real limit and
        /// then fails upstream instead of compacting. So only three things are
        /// advertised — the limit the provider actually reported, the published
        /// Anthropic family windows (every current Claude model is 200K, Opus adds
        /// the 1M tier), and otherwise ``unknownContextWindowFallback``. A model
        /// name from some other vendor is not evidence of a limit: OpenAI-compatible
        /// routes cover everything from 8K local builds to 1M frontier models under
        /// arbitrary custom ids, so an unreported window stays at the fallback.
        static func advertisedContextWindow(
            formatFamily: String,
            modelID: String,
            declaredContextWindowTokens: Int?
        ) -> Int {
            // Discovery normalizes non-positive values away, but a decoded
            // capability payload bypasses that init — a zero limit here would
            // advertise a zero-token truncation policy.
            if let declaredContextWindowTokens, declaredContextWindowTokens > 0 {
                return declaredContextWindowTokens
            }
            if formatFamily == BurnBarProviderFormatFamily.anthropic.rawValue {
                return modelID.lowercased().contains("opus") ? 1_000_000 : 200_000
            }
            return unknownContextWindowFallback
        }

        enum CodingKeys: String, CodingKey {
            case slug
            case displayName = "display_name"
            case description
            case defaultReasoningLevel = "default_reasoning_level"
            case supportedReasoningLevels = "supported_reasoning_levels"
            case shellType = "shell_type"
            case visibility
            case supportedInAPI = "supported_in_api"
            case priority
            case additionalSpeedTiers = "additional_speed_tiers"
            case serviceTiers = "service_tiers"
            case availabilityNux = "availability_nux"
            case upgrade
            case baseInstructions = "base_instructions"
            case modelMessages = "model_messages"
            case supportsReasoningSummaries = "supports_reasoning_summaries"
            case defaultReasoningSummary = "default_reasoning_summary"
            case supportVerbosity = "support_verbosity"
            case defaultVerbosity = "default_verbosity"
            case applyPatchToolType = "apply_patch_tool_type"
            case webSearchToolType = "web_search_tool_type"
            case truncationPolicy = "truncation_policy"
            case supportsParallelToolCalls = "supports_parallel_tool_calls"
            case supportsImageDetailOriginal = "supports_image_detail_original"
            case contextWindow = "context_window"
            case maxContextWindow = "max_context_window"
            case autoCompactTokenLimit = "auto_compact_token_limit"
            case effectiveContextWindowPercent = "effective_context_window_percent"
            case experimentalSupportedTools = "experimental_supported_tools"
            case inputModalities = "input_modalities"
            case supportsSearchTool = "supports_search_tool"
        }

        struct ReasoningLevel: Encodable {
            let effort: String
            let description: String
        }

        struct TruncationPolicy: Encodable {
            let mode: String
            let limit: Int
        }
    }
}

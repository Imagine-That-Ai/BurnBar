import Foundation

/// Capability matrix advertised by each gateway adapter.
public struct InsightModelCapabilities: Codable, Hashable, Sendable {
    public var supportsStrictJSONSchema: Bool
    public var supportsJSONObject: Bool
    public var supportsThinking: Bool
    public var supportsToolUse: Bool
    public var supportsStreaming: Bool

    public init(supportsStrictJSONSchema: Bool = false,
                supportsJSONObject: Bool = true,
                supportsThinking: Bool = false,
                supportsToolUse: Bool = false,
                supportsStreaming: Bool = true) {
        self.supportsStrictJSONSchema = supportsStrictJSONSchema
        self.supportsJSONObject = supportsJSONObject
        self.supportsThinking = supportsThinking
        self.supportsToolUse = supportsToolUse
        self.supportsStreaming = supportsStreaming
    }

    /// The best supported tier given the requested tier.
    public func bestTier(requested: InsightCapabilityTier) -> InsightCapabilityTier {
        switch requested {
        case .strictJSONSchema where supportsStrictJSONSchema: return .strictJSONSchema
        case .strictJSONSchema where supportsJSONObject: return .jsonObject
        case .strictJSONSchema: return .narrativeOnly
        case .jsonObject where supportsJSONObject: return .jsonObject
        case .jsonObject: return .narrativeOnly
        case .narrativeOnly: return .narrativeOnly
        }
    }
}

/// The protocol every LLM adapter conforms to. One unified streaming API.
public protocol InsightModelGateway: Sendable {
    /// Stable identifier of this gateway (e.g. "anthropic", "openai",
    /// "hermes", "pi", "ollama").
    var providerKey: String { get }

    /// Default capability matrix. Adapters may override per-model.
    var capabilities: InsightModelCapabilities { get }

    /// User-facing label.
    var displayName: String { get }

    /// Available models for the picker. Cheap; cached by adapter.
    func availableModels() async throws -> [InsightCatalogModel]

    /// Stream investigation events.
    func investigate(
        request: InsightInvestigateRequest,
        tools: InsightToolBroker?
    ) -> AsyncThrowingStream<InsightInvestigateEvent, Error>

    /// Produce a structured analysis result. Gateways that support JSON mode
    /// should override this and ask the provider for
    /// `InsightJSONSchema.analysisResultSchemaV1`. The default bridge keeps
    /// older canvas-only adapters usable by converting the generated canvas
    /// into the shared analysis contract.
    func analyze(
        request: InsightAnalysisRequest,
        platform: InsightAnalysisPlatform,
        tools: InsightToolBroker?
    ) async throws -> InsightAnalysisResult
}

/// One model in the picker catalog.
public struct InsightCatalogModel: Codable, Hashable, Sendable, Identifiable {
    public let id: String                 // provider's model id
    public let displayName: String
    public let providerKey: String
    public let egressTier: InsightEgressTier
    public let capabilities: InsightModelCapabilities
    /// Dollars per million input tokens, if known. Used to badge cost.
    public let inputCostPerMtoken: Double?
    /// Dollars per million output tokens, if known.
    public let outputCostPerMtoken: Double?
    /// SF Symbol for the picker chip.
    public let symbolName: String
    public init(id: String, displayName: String, providerKey: String,
                egressTier: InsightEgressTier, capabilities: InsightModelCapabilities,
                inputCostPerMtoken: Double? = nil,
                outputCostPerMtoken: Double? = nil,
                symbolName: String = "cpu") {
        self.id = id; self.displayName = displayName
        self.providerKey = providerKey; self.egressTier = egressTier
        self.capabilities = capabilities
        self.inputCostPerMtoken = inputCostPerMtoken
        self.outputCostPerMtoken = outputCostPerMtoken
        self.symbolName = symbolName
    }
}

public extension InsightModelGateway {
    func analyze(
        request: InsightAnalysisRequest,
        platform: InsightAnalysisPlatform,
        tools: InsightToolBroker?
    ) async throws -> InsightAnalysisResult {
        let canvasRequest = InsightInvestigateRequest(
            prompt: request.prompt,
            digest: request.context.digest,
            canvas: request.currentCanvas,
            modelTag: request.selectedModel,
            capabilityTier: capabilities.supportsStrictJSONSchema ? .strictJSONSchema : .jsonObject,
            maxNewWidgets: request.maxGeneratedWidgets,
            allowToolCalls: false,
            instruction: request.instruction.asInvestigationInstruction
        )
        var finalCanvas: InsightCanvas?
        var tokenUsage: InsightTokenUsage?
        for try await event in investigate(request: canvasRequest, tools: tools) {
            switch event {
            case .finalCanvas(let canvas):
                finalCanvas = canvas
            case .partialCanvas(let canvas):
                finalCanvas = canvas
            case .usage(let usage):
                tokenUsage = usage
            default:
                break
            }
        }
        guard let finalCanvas else {
            throw InsightGatewayError.malformedResponse(
                modelID: request.selectedModel.modelID,
                detail: "gateway did not return a canvas or analysis result"
            )
        }
        return InsightAnalysisModelDecoder.resultFromCanvas(
            finalCanvas,
            request: request,
            platform: platform,
            tokenUsage: tokenUsage
        )
    }
}

private extension InsightAnalysisRequest.Instruction {
    var asInvestigationInstruction: InsightInvestigateRequest.Instruction {
        switch self {
        case .defaultBrief: return .composeCanvas
        case .answerFollowUp: return .explainBriefly
        case .generateReport: return .composeCanvas
        case .updateCanvas: return .refineCanvas
        }
    }
}

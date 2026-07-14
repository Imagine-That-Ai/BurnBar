import Foundation

/// High-level orchestrator: digest → cache lookup → adapter → audit log.
///
/// View models drive the UI through this single object. It exposes one
/// streaming method per investigation; the shell layer subscribes to the
/// event stream and updates the canvas.
public actor InsightInvestigation {

    public struct Configuration: Sendable {
        public var privacyModeRestrictsToLocal: Bool
        public init(privacyModeRestrictsToLocal: Bool = false) {
            self.privacyModeRestrictsToLocal = privacyModeRestrictsToLocal
        }
    }

    private let catalog: InsightModelCatalog
    private let cache: InsightCache
    private let auditLog: InsightAuditLog
    private let toolBroker: InsightToolBroker?
    private let promptEngine: InsightPromptEngine
    public var configuration: Configuration

    public init(catalog: InsightModelCatalog,
                cache: InsightCache,
                auditLog: InsightAuditLog,
                toolBroker: InsightToolBroker?,
                configuration: Configuration = .init()) {
        self.catalog = catalog
        self.cache = cache
        self.auditLog = auditLog
        self.toolBroker = toolBroker
        self.promptEngine = InsightPromptEngine()
        self.configuration = configuration
    }

    public func updateConfiguration(_ config: Configuration) {
        self.configuration = config
    }

    /// Run an investigation. Caller subscribes to the returned stream.
    public func run(_ request: InsightInvestigateRequest) -> AsyncThrowingStream<InsightInvestigateEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let startedAt = Date()
                let auditEntryID = UUID()

                // Privacy gate.
                if configuration.privacyModeRestrictsToLocal,
                   request.modelTag.egressTier != .localOnly {
                    let err = InsightGatewayError.egressBlockedByPrivacyMode(modelID: request.modelTag.modelID)
                    try? await auditLog.append(.init(
                        id: auditEntryID,
                        canvasID: request.canvas?.id,
                        prompt: request.prompt,
                        modelTag: request.modelTag,
                        egressTier: request.modelTag.egressTier,
                        digestBytes: estimatedDigestBytes(request.digest),
                        digestContentHash: request.digest.contentHash,
                        instruction: request.instruction.rawValue,
                        tokenUsage: nil,
                        startedAt: startedAt,
                        completedAt: Date(),
                        status: .failed,
                        errorDescription: err.localizedDescription
                    ))
                    continuation.finish(throwing: err)
                    return
                }

                // Audit: started.
                try? await auditLog.append(.init(
                    id: auditEntryID,
                    canvasID: request.canvas?.id,
                    prompt: request.prompt,
                    modelTag: request.modelTag,
                    egressTier: request.modelTag.egressTier,
                    digestBytes: estimatedDigestBytes(request.digest),
                    digestContentHash: request.digest.contentHash,
                    instruction: request.instruction.rawValue,
                    startedAt: startedAt,
                    status: .started
                ))

                // Cache.
                let cacheKey = InsightCache.key(
                    digestContentHash: request.digest.contentHash,
                    prompt: request.prompt,
                    modelID: request.modelTag.modelID,
                    tier: request.capabilityTier,
                    instruction: request.instruction
                )
                if let hit = await cache.lookup(key: cacheKey) {
                    continuation.yield(.finalCanvas(hit.canvas))
                    continuation.finish()
                    try? await auditLog.append(.init(
                        canvasID: hit.canvas.id,
                        prompt: request.prompt,
                        modelTag: request.modelTag,
                        egressTier: request.modelTag.egressTier,
                        digestBytes: estimatedDigestBytes(request.digest),
                        digestContentHash: request.digest.contentHash,
                        instruction: request.instruction.rawValue,
                        startedAt: startedAt,
                        completedAt: Date(),
                        status: .succeeded
                    ))
                    return
                }

                // Dispatch to the adapter.
                guard let gateway = await catalog.gateway(for: request.modelTag.providerKey) else {
                    let err = InsightGatewayError.modelUnavailable(
                        modelID: request.modelTag.modelID,
                        reason: "no adapter for \(request.modelTag.providerKey)"
                    )
                    continuation.finish(throwing: err)
                    return
                }
                let stream = gateway.investigate(request: request, tools: toolBroker)
                do {
                    var finalCanvas: InsightCanvas?
                    var finalUsage: InsightTokenUsage?
                    for try await event in stream {
                        switch event {
                        case .finalCanvas(let canvas):
                            finalCanvas = canvas
                        case .usage(let usage):
                            finalUsage = usage
                        default:
                            break
                        }
                        continuation.yield(event)
                    }
                    if let canvas = finalCanvas {
                        try? await cache.store(.init(
                            key: cacheKey,
                            canvas: canvas,
                            costSavedUSD: finalUsage?.estimatedCostUSD ?? 0
                        ))
                    }
                    try? await auditLog.append(.init(
                        canvasID: finalCanvas?.id,
                        prompt: request.prompt,
                        modelTag: request.modelTag,
                        egressTier: request.modelTag.egressTier,
                        digestBytes: estimatedDigestBytes(request.digest),
                        digestContentHash: request.digest.contentHash,
                        instruction: request.instruction.rawValue,
                        tokenUsage: finalUsage,
                        startedAt: startedAt,
                        completedAt: Date(),
                        status: .succeeded
                    ))
                    continuation.finish()
                } catch {
                    try? await auditLog.append(.init(
                        canvasID: request.canvas?.id,
                        prompt: request.prompt,
                        modelTag: request.modelTag,
                        egressTier: request.modelTag.egressTier,
                        digestBytes: estimatedDigestBytes(request.digest),
                        digestContentHash: request.digest.contentHash,
                        instruction: request.instruction.rawValue,
                        startedAt: startedAt,
                        completedAt: Date(),
                        status: .failed,
                        errorDescription: error.localizedDescription
                    ))
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func estimatedDigestBytes(_ digest: InsightDigest) -> Int {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(digest))?.count ?? 0
    }
}

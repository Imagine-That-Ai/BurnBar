import Foundation

/// Adapter that targets the user's local Pi runtime.
///
/// Identical wire format to `HermesInsightAdapter`. Different transport.
public struct PiInsightAdapter: InsightModelGateway {

    public let providerKey = "pi"
    public let displayName = "Pi"
    public let capabilities = InsightModelCapabilities(
        supportsStrictJSONSchema: false,
        supportsJSONObject: true,
        supportsThinking: false,
        supportsToolUse: false,
        supportsStreaming: true
    )

    public let transport: HermesInsightTransport
    public let availableModelList: [InsightCatalogModel]

    public init(transport: HermesInsightTransport,
                availableModels: [InsightCatalogModel] = []) {
        self.transport = transport
        self.availableModelList = availableModels
    }

    public func availableModels() async throws -> [InsightCatalogModel] {
        if !availableModelList.isEmpty { return availableModelList }
        return try await transport.discoverModels()
    }

    public func investigate(
        request: InsightInvestigateRequest,
        tools: InsightToolBroker?
    ) -> AsyncThrowingStream<InsightInvestigateEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let canvas = try await transport.sendCanvasRequest(request: request)
                    continuation.yield(.finalCanvas(canvas))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

import Foundation

/// Adapter that targets the existing OpenBurnBar Hermes relay.
///
/// Hermes already speaks the Chart Studio JSON envelope grammar — this
/// adapter reuses the same `POST /v1/chat/completions` plumbing as
/// `ChartStudioHermesBridge` but asks for a canvas-shaped response
/// instead of a single rendering envelope.
///
/// The actual transport (LAN socket vs. hosted relay) is delegated to a
/// `HermesInsightTransport` so the macOS and mobile shells can plug in
/// their existing connection objects.
public struct HermesInsightAdapter: InsightModelGateway {

    public let providerKey = "hermes"
    public let displayName = "Hermes"
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

/// Pluggable transport so we don't have to import the entire Hermes
/// stack into core. Shell layers provide their own implementation.
public protocol HermesInsightTransport: Sendable {
    func discoverModels() async throws -> [InsightCatalogModel]
    func sendCanvasRequest(request: InsightInvestigateRequest) async throws -> InsightCanvas
}

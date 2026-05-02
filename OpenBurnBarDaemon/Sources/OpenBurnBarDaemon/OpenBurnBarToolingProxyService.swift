import OpenBurnBarCore
import Foundation

public actor BurnBarToolingProxyService {
    private let connectorPlaneService: BurnBarConnectorPlaneService
    private let browserToolService: BurnBarBrowserToolService

    public init(
        connectorPlaneService: BurnBarConnectorPlaneService = BurnBarConnectorPlaneService(),
        browserToolService: BurnBarBrowserToolService = BurnBarBrowserToolService()
    ) {
        self.connectorPlaneService = connectorPlaneService
        self.browserToolService = browserToolService
    }

    public func connectorPlaneSnapshot() async throws -> BurnBarConnectorPlaneSnapshot {
        try await connectorPlaneService.snapshot()
    }

    public func updateConnectorPlane(
        _ request: BurnBarConnectorConfigUpdateRequest
    ) async throws -> BurnBarConnectorPlaneSnapshot {
        try await connectorPlaneService.updateConfig(request)
    }

    public func performConnectorAction(
        _ request: BurnBarConnectorActionRequest
    ) async throws -> BurnBarConnectorActionResponse {
        try await connectorPlaneService.performAction(request)
    }

    public func browserToolingSnapshot() async throws -> BurnBarBrowserToolingSnapshot {
        try await browserToolService.snapshot()
    }

    public func updateBrowserTooling(
        _ request: BurnBarBrowserToolingUpdateRequest
    ) async throws -> BurnBarBrowserToolingSnapshot {
        try await browserToolService.update(request)
    }

    public func performBrowserAction(
        _ request: BurnBarBrowserActionRequest
    ) async throws -> BurnBarBrowserActionResponse {
        try await browserToolService.performAction(request)
    }
}

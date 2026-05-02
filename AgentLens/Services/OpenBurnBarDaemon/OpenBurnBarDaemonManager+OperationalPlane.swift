import Foundation
import OpenBurnBarCore

extension OpenBurnBarDaemonManager {

    func refreshOperationalToolPlane() async {
        guard case .healthy = status else {
            connectorPlaneSnapshot = nil
            browserToolingSnapshot = nil
            return
        }

        let socketURL = paths.socketURL
        do {
            let (plane, tooling) = try await daemonRPC {
                let plane = try OpenBurnBarDaemonSocketClient.connectorPlane(at: socketURL)
                let tooling = try OpenBurnBarDaemonSocketClient.browserTooling(at: socketURL)
                return (plane, tooling)
            }
            connectorPlaneSnapshot = plane
            browserToolingSnapshot = tooling
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func updateConnectorConfig(
        _ config: BurnBarConnectorConfigMutation,
        secret: String? = nil,
        replaceSecret: Bool = false
    ) async throws -> BurnBarConnectorPlaneSnapshot {
        guard case .healthy = status else {
            throw OpenBurnBarDaemonManagerError.rpcError("OpenBurnBar daemon must be healthy before updating connectors.")
        }

        let socketURL = paths.socketURL
        let snapshot = try await daemonRPC {
            try OpenBurnBarDaemonSocketClient.updateConnectorConfig(
                BurnBarConnectorConfigUpdateRequest(
                    config: config,
                    secret: secret,
                    replaceSecret: replaceSecret
                ),
                at: socketURL
            )
        }
        connectorPlaneSnapshot = snapshot
        return snapshot
    }

    func performConnectorAction(
        kind: BurnBarConnectorKind,
        action: BurnBarConnectorActionKind = .testConnection
    ) async throws -> BurnBarConnectorActionResponse {
        guard case .healthy = status else {
            throw OpenBurnBarDaemonManagerError.rpcError("OpenBurnBar daemon must be healthy before testing connectors.")
        }

        let socketURL = paths.socketURL
        let response = try await daemonRPC {
            try OpenBurnBarDaemonSocketClient.performConnectorAction(
                BurnBarConnectorActionRequest(kind: kind, action: action),
                at: socketURL
            )
        }
        connectorPlaneSnapshot = try? await daemonRPC {
            try OpenBurnBarDaemonSocketClient.connectorPlane(at: socketURL)
        }
        return response
    }

    func updateBrowserTooling(
        _ request: BurnBarBrowserToolingUpdateRequest
    ) async throws -> BurnBarBrowserToolingSnapshot {
        guard case .healthy = status else {
            throw OpenBurnBarDaemonManagerError.rpcError("OpenBurnBar daemon must be healthy before updating browser tooling.")
        }

        let socketURL = paths.socketURL
        let snapshot = try await daemonRPC {
            try OpenBurnBarDaemonSocketClient.updateBrowserTooling(request, at: socketURL)
        }
        browserToolingSnapshot = snapshot
        return snapshot
    }

    func performBrowserAction(
        _ request: BurnBarBrowserActionRequest
    ) async throws -> BurnBarBrowserActionResponse {
        guard case .healthy = status else {
            throw OpenBurnBarDaemonManagerError.rpcError("OpenBurnBar daemon must be healthy before using browser tooling.")
        }

        let socketURL = paths.socketURL
        let response = try await daemonRPC {
            try OpenBurnBarDaemonSocketClient.performBrowserAction(request, at: socketURL)
        }
        browserToolingSnapshot = try? await daemonRPC {
            try OpenBurnBarDaemonSocketClient.browserTooling(at: socketURL)
        }
        return response
    }
}

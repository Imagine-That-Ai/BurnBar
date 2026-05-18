import Foundation
import OpenBurnBarCore

extension OpenBurnBarDaemonManager {
    func startComputerUseSession(
        _ request: ComputerUseSessionStartRequest
    ) async throws -> ComputerUseSessionStartResponse {
        guard case .healthy = status else {
            throw OpenBurnBarDaemonManagerError.rpcError("OpenBurnBar daemon must be healthy before starting Computer Use.")
        }
        let socketURL = paths.socketURL
        return try await daemonRPC {
            try OpenBurnBarDaemonSocketClient.startComputerUseSession(request, at: socketURL)
        }
    }

    func invokeComputerUse(
        _ request: ComputerUseInvokeRequest
    ) async throws -> ComputerUseInvokeResponse {
        guard case .healthy = status else {
            throw OpenBurnBarDaemonManagerError.rpcError("OpenBurnBar daemon must be healthy before invoking Computer Use.")
        }
        let socketURL = paths.socketURL
        return try await daemonRPC {
            try OpenBurnBarDaemonSocketClient.invokeComputerUse(request, at: socketURL)
        }
    }

    func pendingComputerUseApprovals(
        _ request: ComputerUseApprovalPendingRequest = ComputerUseApprovalPendingRequest()
    ) async throws -> ComputerUseApprovalPendingResponse {
        guard case .healthy = status else {
            throw OpenBurnBarDaemonManagerError.rpcError("OpenBurnBar daemon must be healthy before reading Computer Use approvals.")
        }
        let socketURL = paths.socketURL
        return try await daemonRPC {
            try OpenBurnBarDaemonSocketClient.pendingComputerUseApprovals(request, at: socketURL)
        }
    }

    func respondToComputerUseApproval(
        _ request: ComputerUseApprovalRespondRequest
    ) async throws -> ComputerUseApprovalRespondResponse {
        guard case .healthy = status else {
            throw OpenBurnBarDaemonManagerError.rpcError("OpenBurnBar daemon must be healthy before responding to Computer Use approvals.")
        }
        let socketURL = paths.socketURL
        return try await daemonRPC {
            try OpenBurnBarDaemonSocketClient.respondToComputerUseApproval(request, at: socketURL)
        }
    }

    func panicHaltComputerUse(
        _ request: ComputerUsePanicHaltRequest
    ) async throws -> ComputerUsePanicHaltResponse {
        guard case .healthy = status else {
            throw OpenBurnBarDaemonManagerError.rpcError("OpenBurnBar daemon must be healthy before halting Computer Use.")
        }
        let socketURL = paths.socketURL
        return try await daemonRPC {
            try OpenBurnBarDaemonSocketClient.panicHaltComputerUse(request, at: socketURL)
        }
    }

    func exportComputerUseAudit(
        _ request: ComputerUseAuditExportRequest
    ) async throws -> ComputerUseAuditExportResponse {
        guard case .healthy = status else {
            throw OpenBurnBarDaemonManagerError.rpcError("OpenBurnBar daemon must be healthy before exporting a Computer Use audit archive.")
        }
        let socketURL = paths.socketURL
        return try await daemonRPC {
            try OpenBurnBarDaemonSocketClient.exportComputerUseAudit(request, at: socketURL)
        }
    }
}

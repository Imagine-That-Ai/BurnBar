import Foundation
import Observation
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

@MainActor
@Observable
final class AgentCapabilityGrantStore {
    static let shared = AgentCapabilityGrantStore()

    private struct GrantKey: Hashable {
        let runtimeID: AssistantRuntimeID
        let threadID: String
    }

    private var activeGrants: [GrantKey: AgentCapabilityGrant] = [:]
    private(set) var latestReceipts: [String: AgentCapabilityGrantReceipt] = [:]

    private init() {}

    func activate(_ grant: AgentCapabilityGrant) {
        activeGrants[GrantKey(runtimeID: grant.runtimeID, threadID: grant.threadID)] = grant
    }

    func activeGrant(
        runtimeID: AssistantRuntimeID,
        threadID: String,
        now: Date = Date()
    ) -> AgentCapabilityGrant? {
        let key = GrantKey(runtimeID: runtimeID, threadID: threadID)
        guard let grant = activeGrants[key] else { return nil }
        guard grant.isActive(now: now) else {
            activeGrants.removeValue(forKey: key)
            return nil
        }
        return grant
    }

    func revoke(runtimeID: AssistantRuntimeID, threadID: String) {
        let key = GrantKey(runtimeID: runtimeID, threadID: threadID)
        if let grant = activeGrants[key] {
            activeGrants[key] = grant.revoked()
        }
    }

    @discardableResult
    func apply(
        _ request: AgentCapabilityGrantRequest,
        workspaceRootPath: String? = nil,
        now: Date = Date()
    ) -> AgentCapabilityGrantReceipt {
        let receipt: AgentCapabilityGrantReceipt
        if request.threadID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            receipt = deniedReceipt(
                for: request,
                reason: .malformedRequest,
                message: "Missing thread id.",
                now: now
            )
        } else if !request.isFresh(now: now) {
            receipt = deniedReceipt(
                for: request,
                reason: .expired,
                message: "Grant request expired before this Mac received it.",
                now: now
            )
        } else if request.preset.requiresLocalAuthentication && !request.localAuthenticationSatisfied {
            receipt = deniedReceipt(
                for: request,
                reason: .localAuthenticationRequired,
                message: "This permission level requires device authentication.",
                now: now
            )
        } else if yoloUnavailable(for: request) {
            receipt = deniedReceipt(
                for: request,
                reason: .yoloUnavailable,
                message: "YOLO desktop grants are unavailable in this build.",
                now: now
            )
        } else if request.capabilities.isEmpty {
            revoke(runtimeID: request.runtimeID, threadID: request.threadID)
            receipt = AgentCapabilityGrantReceipt(
                requestID: request.requestID,
                runtimeID: request.runtimeID,
                threadID: request.threadID,
                status: .revoked,
                capabilities: [],
                trustMode: request.trustMode,
                receivedAt: now,
                sourceDeviceID: request.sourceDeviceID,
                message: "Desktop tools are off."
            )
        } else {
            let grant = request.makeGrant(workspaceRootPath: workspaceRootPath, now: now)
            activate(grant)
            receipt = AgentCapabilityGrantReceipt(
                requestID: request.requestID,
                runtimeID: request.runtimeID,
                threadID: request.threadID,
                status: .applied,
                appliedGrantID: grant.grantID,
                capabilities: grant.capabilities,
                trustMode: grant.trustMode,
                receivedAt: now,
                grantExpiresAt: grant.expiresAt,
                sourceDeviceID: request.sourceDeviceID,
                message: "\(request.preset.title) permissions enabled for this thread."
            )
        }
        latestReceipts[request.requestID] = receipt
        return receipt
    }

    private func deniedReceipt(
        for request: AgentCapabilityGrantRequest,
        reason: AgentGrantDenialReason,
        message: String,
        now: Date
    ) -> AgentCapabilityGrantReceipt {
        AgentCapabilityGrantReceipt(
            requestID: request.requestID,
            runtimeID: request.runtimeID,
            threadID: request.threadID,
            status: .denied,
            capabilities: request.capabilities,
            trustMode: request.trustMode,
            receivedAt: now,
            sourceDeviceID: request.sourceDeviceID,
            denialReason: reason,
            message: message
        )
    }

    private func yoloUnavailable(for request: AgentCapabilityGrantRequest) -> Bool {
        #if DISTRIBUTION_MAS
        return request.capabilities.contains(.shellUnrestricted)
        #else
        return false
        #endif
    }
}

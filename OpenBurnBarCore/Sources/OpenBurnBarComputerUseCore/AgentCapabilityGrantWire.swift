import Foundation
import OpenBurnBarCore

public enum AgentCapabilityGrantWireError: Error, Equatable, Sendable {
    case unsupportedRuntime(String)
    case unsupportedPreset(String)
    case unsupportedCapability(String)
    case unsupportedTrustMode(String)
    case unsupportedDeliveryMode(String)
    case unsupportedReceiptStatus(String)
    case unsupportedDenialReason(String)
    case presetCapabilityMismatch
}

public extension AgentCapabilityGrantRequest {
    init(wire request: HermesRealtimeRelayAgentGrantRequest) throws {
        guard let runtime = AssistantRuntimeID(rawValue: request.runtime) else {
            throw AgentCapabilityGrantWireError.unsupportedRuntime(request.runtime)
        }
        guard let preset = AgentPermissionPreset(rawValue: request.preset) else {
            throw AgentCapabilityGrantWireError.unsupportedPreset(request.preset)
        }
        var capabilities = Set<AgentDesktopCapability>()
        for raw in request.capabilities {
            guard let capability = AgentDesktopCapability(rawValue: raw) else {
                throw AgentCapabilityGrantWireError.unsupportedCapability(raw)
            }
            capabilities.insert(capability)
        }
        guard let trustMode = ComputerUseTrustMode(rawValue: request.trustMode) else {
            throw AgentCapabilityGrantWireError.unsupportedTrustMode(request.trustMode)
        }
        guard let deliveryMode = AgentGrantDeliveryMode(rawValue: request.deliveryMode) else {
            throw AgentCapabilityGrantWireError.unsupportedDeliveryMode(request.deliveryMode)
        }
        guard preset.matches(capabilities: capabilities, trustMode: trustMode) else {
            throw AgentCapabilityGrantWireError.presetCapabilityMismatch
        }
        self.init(
            requestID: request.requestId,
            runtimeID: runtime,
            threadID: request.threadId,
            preset: preset,
            capabilities: capabilities,
            trustMode: trustMode,
            deliveryMode: deliveryMode,
            requestedAt: request.requestedAt,
            expiresAt: request.expiresAt,
            grantDurationSeconds: request.grantDurationSeconds,
            sourceDeviceID: request.sourceDeviceId,
            clientIntentID: request.clientIntentId,
            localAuthenticationSatisfied: request.localAuthenticationSatisfied
        )
    }

    func wire(authority: HermesRealtimeRelayAuthorityEnvelope) -> HermesRealtimeRelayAgentGrantRequest {
        HermesRealtimeRelayAgentGrantRequest(
            requestId: requestID,
            runtime: runtimeID.rawValue,
            threadId: threadID,
            preset: preset.rawValue,
            capabilities: capabilities.map(\.rawValue).sorted(),
            trustMode: trustMode.rawValue,
            deliveryMode: deliveryMode.rawValue,
            requestedAt: requestedAt,
            expiresAt: expiresAt,
            grantDurationSeconds: grantDurationSeconds,
            sourceDeviceId: sourceDeviceID,
            clientIntentId: clientIntentID,
            localAuthenticationSatisfied: localAuthenticationSatisfied,
            authority: authority
        )
    }
}

public extension AgentCapabilityGrantReceipt {
    init(wire receipt: HermesRealtimeRelayAgentGrantReceipt) throws {
        guard let runtime = AssistantRuntimeID(rawValue: receipt.runtime) else {
            throw AgentCapabilityGrantWireError.unsupportedRuntime(receipt.runtime)
        }
        guard let status = AgentGrantDecisionStatus(rawValue: receipt.status) else {
            throw AgentCapabilityGrantWireError.unsupportedReceiptStatus(receipt.status)
        }
        var capabilities = Set<AgentDesktopCapability>()
        for raw in receipt.capabilities {
            guard let capability = AgentDesktopCapability(rawValue: raw) else {
                throw AgentCapabilityGrantWireError.unsupportedCapability(raw)
            }
            capabilities.insert(capability)
        }
        guard let trustMode = ComputerUseTrustMode(rawValue: receipt.trustMode) else {
            throw AgentCapabilityGrantWireError.unsupportedTrustMode(receipt.trustMode)
        }
        let denialReason: AgentGrantDenialReason?
        if let raw = receipt.denialReason {
            guard let parsed = AgentGrantDenialReason(rawValue: raw) else {
                throw AgentCapabilityGrantWireError.unsupportedDenialReason(raw)
            }
            denialReason = parsed
        } else {
            denialReason = nil
        }
        self.init(
            receiptID: receipt.receiptId,
            requestID: receipt.requestId,
            runtimeID: runtime,
            threadID: receipt.threadId,
            status: status,
            appliedGrantID: receipt.appliedGrantId,
            capabilities: capabilities,
            trustMode: trustMode,
            receivedAt: receipt.receivedAt,
            grantExpiresAt: receipt.grantExpiresAt,
            sourceDeviceID: receipt.sourceDeviceId,
            denialReason: denialReason,
            message: receipt.message
        )
    }

    func wire() -> HermesRealtimeRelayAgentGrantReceipt {
        HermesRealtimeRelayAgentGrantReceipt(
            receiptId: receiptID,
            requestId: requestID,
            runtime: runtimeID.rawValue,
            threadId: threadID,
            status: status.rawValue,
            appliedGrantId: appliedGrantID,
            capabilities: capabilities.map(\.rawValue).sorted(),
            trustMode: trustMode.rawValue,
            receivedAt: receivedAt,
            grantExpiresAt: grantExpiresAt,
            sourceDeviceId: sourceDeviceID,
            denialReason: denialReason?.rawValue,
            message: message
        )
    }
}

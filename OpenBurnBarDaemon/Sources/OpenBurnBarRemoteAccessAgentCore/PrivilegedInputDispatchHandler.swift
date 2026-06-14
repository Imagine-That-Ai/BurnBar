import Foundation
import OpenBurnBarComputerUseCore

/// Executes `PrivilegedInputDispatchRequest` on the HID leaf with policy, kill-switch, and audit hooks.
public final class PrivilegedInputDispatchHandler: Sendable {
    public let auditSocketLabel: String
    private let keyboard: VirtualHIDKeyboardEngine
    private let capabilityVerifier: CapabilityTokenLeafVerifier
    private let maximumCredentialUTF8Bytes = 1_024

    public init(
        auditSocketLabel: String,
        keyboard: VirtualHIDKeyboardEngine,
        capabilityVerifier: CapabilityTokenLeafVerifier? = nil
    ) {
        self.auditSocketLabel = auditSocketLabel
        self.keyboard = keyboard
        self.capabilityVerifier = capabilityVerifier ?? CapabilityTokenLeafVerifier(
            nonceStore: FileCapabilityTokenNonceStore()
        ) {
            try? CapabilityTokenIssuerTrustMaterial.load()?.issuerTrust()
        }
    }

    public func handle(envelope: PrivilegedInputDispatchEnvelope) throws -> PrivilegedInputDispatchResponse {
        if let tokenData = envelope.peerAuditToken {
            try PrivilegedInputXPCPeerValidator.validateForwardedAuditToken(tokenData)
        }
        try PrivilegedInputKillSwitch.assertNotActive()

        switch envelope.request.operation {
        case "health":
            return PrivilegedInputDispatchResponse(ok: true)
        case "typeCredential":
            let password = try validatedPassword(envelope.request.password)
            try validateCredentialType(capabilityToken: envelope.capabilityToken)
            try keyboard.typeCredential(password)
            return PrivilegedInputDispatchResponse(ok: true)
        case "input":
            try validateBridgeInput(envelope.request, capabilityToken: envelope.capabilityToken)
            try keyboard.dispatch(envelope.request)
            PrivilegedSocketAudit.record(
                PrivilegedSocketAuditRecord(
                    event: .bridgeInputAccepted,
                    socket: auditSocketLabel,
                    operation: envelope.request.operation,
                    inputKind: envelope.request.kind
                )
            )
            return PrivilegedInputDispatchResponse(ok: true)
        default:
            return PrivilegedInputDispatchResponse(ok: false, error: "unsupported_operation")
        }
    }

    private func validateBridgeInput(_ request: PrivilegedInputDispatchRequest, capabilityToken: CapabilityToken?) throws {
        let gateRequest = VirtualHIDBridgeCapabilityGate.Request(
            kind: request.kind,
            text: request.text,
            key: request.key,
            modifiers: request.modifiers,
            capabilityToken: capabilityToken
        )
        switch VirtualHIDBridgeCapabilityGate.validate(gateRequest, verifier: capabilityVerifier) {
        case .success:
            return
        case .failure(let reason):
            PrivilegedSocketAudit.record(
                PrivilegedSocketAuditRecord(
                    event: .bridgeInputRejected,
                    socket: auditSocketLabel,
                    operation: request.operation,
                    detail: reason.rawValue,
                    inputKind: request.kind
                )
            )
            throw VirtualHIDKeyboardEngine.EngineError.inputPolicyRejected
        }
    }

    private func validateCredentialType(capabilityToken: CapabilityToken?) throws {
        let gateRequest = VirtualHIDBridgeCapabilityGate.CredentialRequest(capabilityToken: capabilityToken)
        switch VirtualHIDBridgeCapabilityGate.validateCredentialType(gateRequest, verifier: capabilityVerifier) {
        case .success:
            return
        case .failure(let reason):
            PrivilegedSocketAudit.record(
                PrivilegedSocketAuditRecord(
                    event: .bridgeInputRejected,
                    socket: auditSocketLabel,
                    operation: "typeCredential",
                    detail: reason.rawValue,
                    inputKind: "typeCredential"
                )
            )
            throw VirtualHIDKeyboardEngine.EngineError.inputPolicyRejected
        }
    }

    private func validatedPassword(_ value: String?) throws -> String {
        guard let value else { throw VirtualHIDKeyboardEngine.EngineError.missingPassword }
        guard !value.isEmpty else { throw VirtualHIDKeyboardEngine.EngineError.emptyPassword }
        guard value.utf8.count <= maximumCredentialUTF8Bytes else {
            throw VirtualHIDKeyboardEngine.EngineError.passwordTooLarge
        }
        guard RemoteAccessVirtualHIDReportPlanner.planForANSIUSKeyboard(value) != nil else {
            throw VirtualHIDKeyboardEngine.EngineError.unsupportedKeyboardLayout
        }
        return value
    }
}

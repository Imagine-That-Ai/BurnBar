import Foundation
import OpenBurnBarComputerUseCore

/// Session context for the active Remote Unlock presenter, used to bind
/// capability tokens to a specific device/attestation/scope at the gate.
public struct RemoteUnlockSessionContext: Sendable, Equatable {
    public var escrowDeviceId: String?
    public var attestationHashBlake3: String?
    public var scopeHash: String?

    public init(
        escrowDeviceId: String? = nil,
        attestationHashBlake3: String? = nil,
        scopeHash: String? = nil
    ) {
        self.escrowDeviceId = escrowDeviceId
        self.attestationHashBlake3 = attestationHashBlake3
        self.scopeHash = scopeHash
    }

    public static let none = RemoteUnlockSessionContext()
}

/// Executes `PrivilegedInputDispatchRequest` on the HID leaf with policy, kill-switch, and audit hooks.
public final class PrivilegedInputDispatchHandler: Sendable {
    public let auditSocketLabel: String
    private let keyboard: VirtualHIDKeyboardEngine
    private let capabilityVerifier: CapabilityTokenLeafVerifier
    private let sessionContextProvider: @Sendable () -> RemoteUnlockSessionContext
    private let maximumCredentialUTF8Bytes = 1_024

    public init(
        auditSocketLabel: String,
        keyboard: VirtualHIDKeyboardEngine,
        capabilityVerifier: CapabilityTokenLeafVerifier? = nil,
        sessionContextProvider: @escaping @Sendable () -> RemoteUnlockSessionContext = { .none }
    ) {
        self.auditSocketLabel = auditSocketLabel
        self.keyboard = keyboard
        self.capabilityVerifier = capabilityVerifier ?? CapabilityTokenLeafVerifier(
            nonceStore: FileCapabilityTokenNonceStore()
        ) {
            try? CapabilityTokenIssuerTrustMaterial.load()?.issuerTrust()
        }
        self.sessionContextProvider = sessionContextProvider
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
            try validateCredentialType(envelope: envelope)
            try keyboard.typeCredential(password)
            return PrivilegedInputDispatchResponse(ok: true)
        case "input":
            try validateBridgeInput(envelope: envelope)
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

    private func validateBridgeInput(envelope: PrivilegedInputDispatchEnvelope) throws {
        let request = envelope.request
        let gateRequest = VirtualHIDBridgeCapabilityGate.Request(
            kind: request.kind,
            text: request.text,
            key: request.key,
            modifiers: request.modifiers,
            capabilityToken: envelope.capabilityToken,
            presentingEscrowDeviceId: envelope.presentingEscrowDeviceId,
            requiredAttestationHashBlake3: envelope.requiredAttestationHashBlake3
        )
        let context = sessionContext(for: envelope)
        let presenterBinding = VirtualHIDBridgeCapabilityGate.PresenterBinding(
            escrowDeviceId: context.escrowDeviceId,
            attestationHashBlake3: context.attestationHashBlake3,
            scopeHash: context.scopeHash
        )
        switch VirtualHIDBridgeCapabilityGate.validate(gateRequest, verifier: capabilityVerifier, presenterBinding: presenterBinding) {
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

    private func validateCredentialType(envelope: PrivilegedInputDispatchEnvelope) throws {
        let gateRequest = VirtualHIDBridgeCapabilityGate.CredentialRequest(
            capabilityToken: envelope.capabilityToken,
            presentingEscrowDeviceId: envelope.presentingEscrowDeviceId,
            requiredAttestationHashBlake3: envelope.requiredAttestationHashBlake3
        )
        let context = sessionContext(for: envelope)
        let presenterBinding = VirtualHIDBridgeCapabilityGate.PresenterBinding(
            escrowDeviceId: context.escrowDeviceId,
            attestationHashBlake3: context.attestationHashBlake3,
            scopeHash: context.scopeHash
        )
        switch VirtualHIDBridgeCapabilityGate.validateCredentialType(gateRequest, verifier: capabilityVerifier, presenterBinding: presenterBinding) {
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

    private func sessionContext(for envelope: PrivilegedInputDispatchEnvelope) -> RemoteUnlockSessionContext {
        let fallback = sessionContextProvider()
        return RemoteUnlockSessionContext(
            escrowDeviceId: fallback.escrowDeviceId ?? normalizedBinding(envelope.presentingEscrowDeviceId),
            attestationHashBlake3: fallback.attestationHashBlake3 ?? normalizedBinding(envelope.requiredAttestationHashBlake3),
            scopeHash: fallback.scopeHash
        )
    }

    private func normalizedBinding(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

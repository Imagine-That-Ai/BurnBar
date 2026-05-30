import Foundation
import OpenBurnBarComputerUseCore

/// Executes `PrivilegedInputDispatchRequest` on the HID leaf with policy, kill-switch, and audit hooks.
public final class PrivilegedInputDispatchHandler: @unchecked Sendable {
    public let auditSocketLabel: String
    private let keyboard: VirtualHIDKeyboardEngine
    private let maximumCredentialUTF8Bytes = 1_024

    public init(auditSocketLabel: String, keyboard: VirtualHIDKeyboardEngine) {
        self.auditSocketLabel = auditSocketLabel
        self.keyboard = keyboard
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
            try keyboard.typeCredential(password)
            return PrivilegedInputDispatchResponse(ok: true)
        case "input":
            try validateBridgeInput(envelope.request)
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

    private func validateBridgeInput(_ request: PrivilegedInputDispatchRequest) throws {
        let policyRequest = VirtualHIDBridgeInputPolicy.Request(
            kind: request.kind,
            text: request.text,
            key: request.key,
            modifiers: request.modifiers
        )
        switch VirtualHIDBridgeInputPolicy.validate(policyRequest) {
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

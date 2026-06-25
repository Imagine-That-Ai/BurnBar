import Foundation
import OpenBurnBarComputerUseCore

/// Combined fail-closed gate for Virtual HID `"input"`: action-kind policy + capability token.
public enum VirtualHIDBridgeCapabilityGate {
    public enum RejectionReason: String, Sendable, Equatable, Error {
        case missingKind = "missing_input_kind"
        case disallowedKind = "disallowed_input_kind"
        case disallowedTypeOperation = "disallowed_type_operation"
        case disallowedScroll = "disallowed_scroll"
        case disallowedDragDrop = "disallowed_drag_drop"
        case disallowedKey = "disallowed_key"
        case disallowedShortcut = "disallowed_shortcut"
        case emptyText = "empty_text"
        case capabilityTokenMissing = "capability_token_missing"
        case capabilityTokenExpired = "capability_token_expired"
        case capabilityTokenSignatureInvalid = "capability_token_signature_invalid"
        case capabilityTokenNonceReplay = "capability_token_nonce_replay"
        case capabilityTokenActionNotAllowed = "capability_token_action_not_allowed"
        case capabilityTokenBindingMissing = "capability_token_binding_missing"
        case capabilityTokenAttestationMismatch = "capability_token_attestation_mismatch"
        case capabilityTokenIssuerUnavailable = "capability_token_issuer_unavailable"
        case capabilityTokenIssuerRevoked = "capability_token_issuer_revoked"
        case capabilityTokenDomainMismatch = "capability_token_domain_mismatch"
        case capabilityTokenEscrowMismatch = "capability_token_escrow_mismatch"
        case capabilityTokenScopeMismatch = "capability_token_scope_mismatch"
        case capabilityTokenBudgetExhausted = "capability_token_budget_exhausted"
    }

    /// The presenter's Remote Unlock session context that a capability token
    /// must be bound to. Supplied by `PrivilegedInputDispatchHandler` from the
    /// active session.
    public struct PresenterBinding: Sendable, Equatable {
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

        public static let none = PresenterBinding()
    }

    public struct Request: Sendable, Equatable {
        public var kind: String?
        public var text: String?
        public var key: String?
        public var modifiers: [String]?
        public var capabilityToken: CapabilityToken?
        /// Legacy wire fields forwarded from the caller. They are retained for
        /// contract compatibility but are not trusted as presenter context by
        /// the HID leaf; `presenterBinding` must come from the active session
        /// context provider.
        public var presentingEscrowDeviceId: String?
        public var requiredAttestationHashBlake3: String?

        public init(
            kind: String?,
            text: String?,
            key: String?,
            modifiers: [String]?,
            capabilityToken: CapabilityToken? = nil,
            presentingEscrowDeviceId: String? = nil,
            requiredAttestationHashBlake3: String? = nil
        ) {
            self.kind = kind
            self.text = text
            self.key = key
            self.modifiers = modifiers
            self.capabilityToken = capabilityToken
            self.presentingEscrowDeviceId = presentingEscrowDeviceId
            self.requiredAttestationHashBlake3 = requiredAttestationHashBlake3
        }
    }

    public struct CredentialRequest: Sendable, Equatable {
        public var capabilityToken: CapabilityToken?
        /// Legacy wire fields forwarded from the caller. They are retained for
        /// contract compatibility but are not trusted as presenter context by
        /// the HID leaf; `presenterBinding` must come from the active session
        /// context provider.
        public var presentingEscrowDeviceId: String?
        public var requiredAttestationHashBlake3: String?

        public init(
            capabilityToken: CapabilityToken? = nil,
            presentingEscrowDeviceId: String? = nil,
            requiredAttestationHashBlake3: String? = nil
        ) {
            self.capabilityToken = capabilityToken
            self.presentingEscrowDeviceId = presentingEscrowDeviceId
            self.requiredAttestationHashBlake3 = requiredAttestationHashBlake3
        }
    }

    public static func validate(
        _ request: Request,
        verifier: CapabilityTokenLeafVerifier,
        presenterBinding: PresenterBinding = .none,
        now: Date = Date()
    ) -> Result<Void, RejectionReason> {
        let policyRequest = VirtualHIDBridgeInputPolicy.Request(
            kind: request.kind,
            text: request.text,
            key: request.key,
            modifiers: request.modifiers
        )
        switch VirtualHIDBridgeInputPolicy.validate(policyRequest) {
        case .failure(let reason):
            return .failure(mapPolicyReason(reason))
        case .success:
            break
        }

        let effectiveBinding = presenterBinding.normalized()
        if let token = request.capabilityToken,
           let bindingFailure = trustedBindingFailure(for: token, presenterBinding: effectiveBinding) {
            return .failure(bindingFailure)
        }

        let actionKind = request.kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let tokenRequest = CapabilityTokenLeafVerifier.Request(
            token: request.capabilityToken,
            expectedDomain: .remoteUnlock,
            actionKind: actionKind,
            requiredScopeHash: effectiveBinding.scopeHash,
            requiredAttestationHashBlake3: effectiveBinding.attestationHashBlake3,
            boundEscrowDeviceId: effectiveBinding.escrowDeviceId
        )
        switch verifier.verify(request: tokenRequest, now: now) {
        case .success:
            return .success(())
        case .failure(let failure):
            return .failure(mapTokenFailure(failure))
        }
    }

    public static func validateCredentialType(
        _ request: CredentialRequest,
        verifier: CapabilityTokenLeafVerifier,
        presenterBinding: PresenterBinding = .none,
        now: Date = Date()
    ) -> Result<Void, RejectionReason> {
        let effectiveBinding = presenterBinding.normalized()
        if let token = request.capabilityToken,
           let bindingFailure = trustedBindingFailure(for: token, presenterBinding: effectiveBinding) {
            return .failure(bindingFailure)
        }

        let tokenRequest = CapabilityTokenLeafVerifier.Request(
            token: request.capabilityToken,
            expectedDomain: .remoteUnlock,
            actionKind: "type_credential",
            requiredScopeHash: effectiveBinding.scopeHash,
            requiredAttestationHashBlake3: effectiveBinding.attestationHashBlake3,
            boundEscrowDeviceId: effectiveBinding.escrowDeviceId
        )
        switch verifier.verify(request: tokenRequest, now: now) {
        case .success:
            return .success(())
        case .failure(let failure):
            return .failure(mapTokenFailure(failure))
        }
    }

    private static func mapPolicyReason(
        _ reason: VirtualHIDBridgeInputPolicy.RejectionReason
    ) -> RejectionReason {
        switch reason {
        case .missingKind: return .missingKind
        case .disallowedKind: return .disallowedKind
        case .disallowedTypeOperation: return .disallowedTypeOperation
        case .disallowedScroll: return .disallowedScroll
        case .disallowedDragDrop: return .disallowedDragDrop
        case .disallowedKey: return .disallowedKey
        case .disallowedShortcut: return .disallowedShortcut
        case .emptyText: return .emptyText
        }
    }

    private static func mapTokenFailure(
        _ failure: CapabilityTokenVerificationFailure
    ) -> RejectionReason {
        switch failure {
        case .missingToken, .missingSignature: return .capabilityTokenMissing
        case .signatureInvalid: return .capabilityTokenSignatureInvalid
        case .expired: return .capabilityTokenExpired
        case .domainMismatch: return .capabilityTokenDomainMismatch
        case .nonceReplay: return .capabilityTokenNonceReplay
        case .actionNotAllowed: return .capabilityTokenActionNotAllowed
        case .actionBudgetExhausted: return .capabilityTokenBudgetExhausted
        case .scopeMismatch: return .capabilityTokenScopeMismatch
        case .attestationMismatch: return .capabilityTokenAttestationMismatch
        case .escrowDeviceMismatch: return .capabilityTokenEscrowMismatch
        case .issuerKeyUnavailable: return .capabilityTokenIssuerUnavailable
        case .issuerRevoked: return .capabilityTokenIssuerRevoked
        }
    }

    private static func trustedBindingFailure(
        for token: CapabilityToken,
        presenterBinding: PresenterBinding
    ) -> RejectionReason? {
        guard let requiredScopeHash = presenterBinding.scopeHash else {
            return .capabilityTokenBindingMissing
        }
        guard token.scopeHash == requiredScopeHash else {
            return .capabilityTokenScopeMismatch
        }
        if normalized(token.boundEscrowDeviceId) != nil,
           presenterBinding.escrowDeviceId == nil {
            return .capabilityTokenBindingMissing
        }
        if normalized(token.attestationHashBlake3) != nil,
           presenterBinding.attestationHashBlake3 == nil {
            return .capabilityTokenBindingMissing
        }
        return nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension VirtualHIDBridgeCapabilityGate.PresenterBinding {
    func normalized() -> Self {
        Self(
            escrowDeviceId: Self.normalized(escrowDeviceId),
            attestationHashBlake3: Self.normalized(attestationHashBlake3),
            scopeHash: Self.normalized(scopeHash)
        )
    }

    static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

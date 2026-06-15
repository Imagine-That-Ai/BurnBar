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

        // Verify scope binding before signature checks to fail fast on
        // cross-session replay.
        let effectiveBinding = presenterBinding.merging(
            escrowDeviceId: request.presentingEscrowDeviceId,
            attestationHashBlake3: request.requiredAttestationHashBlake3
        )

        if let token = request.capabilityToken,
           let requiredScopeHash = effectiveBinding.scopeHash,
           token.scopeHash != requiredScopeHash {
            return .failure(.capabilityTokenScopeMismatch)
        }

        let actionKind = request.kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let tokenRequest = CapabilityTokenLeafVerifier.Request(
            token: request.capabilityToken,
            expectedDomain: .remoteUnlock,
            actionKind: actionKind,
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
        // Verify scope binding before signature checks to fail fast on
        // cross-session replay.
        let effectiveBinding = presenterBinding.merging(
            escrowDeviceId: request.presentingEscrowDeviceId,
            attestationHashBlake3: request.requiredAttestationHashBlake3
        )

        if let token = request.capabilityToken,
           let requiredScopeHash = effectiveBinding.scopeHash,
           token.scopeHash != requiredScopeHash {
            return .failure(.capabilityTokenScopeMismatch)
        }

        let tokenRequest = CapabilityTokenLeafVerifier.Request(
            token: request.capabilityToken,
            expectedDomain: .remoteUnlock,
            actionKind: "type_credential",
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
        case .attestationMismatch: return .capabilityTokenAttestationMismatch
        case .escrowDeviceMismatch: return .capabilityTokenEscrowMismatch
        case .issuerKeyUnavailable: return .capabilityTokenIssuerUnavailable
        case .issuerRevoked: return .capabilityTokenIssuerRevoked
        }
    }
}

private extension VirtualHIDBridgeCapabilityGate.PresenterBinding {
    func merging(
        escrowDeviceId: String?,
        attestationHashBlake3: String?
    ) -> Self {
        Self(
            escrowDeviceId: self.escrowDeviceId ?? Self.normalized(escrowDeviceId),
            attestationHashBlake3: self.attestationHashBlake3 ?? Self.normalized(attestationHashBlake3),
            scopeHash: self.scopeHash
        )
    }

    static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

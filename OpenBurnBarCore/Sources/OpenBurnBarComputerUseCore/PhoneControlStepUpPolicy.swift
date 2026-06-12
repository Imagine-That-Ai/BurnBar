import Foundation
import OpenBurnBarCore

public extension AgentDesktopCapability {
    /// F2 — capabilities whose *individual actions* demand a fresh biometric
    /// step-up at signing time, not merely a one-time grant approval. These are
    /// the classes that can take irreversible or system-level action: raw Mac
    /// input synthesis, shell, and unrestricted shell.
    static let biometricStepUpRequired: Set<AgentDesktopCapability> = [
        .desktopSystemInput,
        .shell,
        .shellUnrestricted
    ]

    /// Whether each signed action exercising this capability must carry a fresh
    /// biometric step-up proof.
    var requiresBiometricStepUpPerAction: Bool {
        Self.biometricStepUpRequired.contains(self)
    }
}

/// F2 — per-action biometric step-up policy for phone control.
///
/// The pre-F2 model authenticated the controller once (first Mac approval) and
/// then trusted possession of the software signing key for every subsequent
/// intent. F2 requires a fresh user-presence proof (Face ID / Touch ID /
/// fingerprint) for the sensitive action classes on *every* signing, and binds
/// that proof to the key custody:
///
///  - A Secure-Enclave / StrongBox key created with biometry-gated access
///    control cannot produce a signature without a live biometric match, so the
///    presence of a valid `se-p256` signature *is* the step-up proof — the OS
///    enforces it and it cannot be forged by mere key possession.
///  - A legacy software Ed25519 key offers no such guarantee, so a sensitive
///    action signed by one must additionally carry a single-use local-auth
///    proof (the existing `HermesRealtimeRelayAgentGrantLocalAuthProof` flow).
///
/// This type is the shared, platform-independent decision surface; the Mac
/// validator, the server, and the iOS/Android signers all consult it so the
/// rule is identical everywhere.
public struct PhoneControlStepUpPolicy: Sendable, Equatable {
    public init() {}

    /// How a sensitive action's step-up requirement is satisfied for a key kind.
    public enum StepUpEvidence: Sendable, Equatable {
        /// The signature itself proves a live biometric (biometry-gated Secure
        /// Enclave / StrongBox key). No extra proof field is required.
        case enforcedBySecureEnclaveSignature
        /// Possession of a software key is not a biometric proof; the action
        /// must carry an explicit single-use local-auth proof.
        case requiresExplicitLocalAuthProof
    }

    /// Whether a control action exercising `capabilities` requires a step-up at
    /// all. Non-sensitive classes (read-only inspection, screenshots,
    /// browser-only) never do.
    public func requiresStepUp(capabilities: Set<AgentDesktopCapability>) -> Bool {
        !capabilities.isDisjoint(with: AgentDesktopCapability.biometricStepUpRequired)
    }

    /// Whether the named raw capability requires a step-up.
    public func requiresStepUp(capability: AgentDesktopCapability) -> Bool {
        capability.requiresBiometricStepUpPerAction
    }

    /// The evidence a controller of the given key kind must supply to satisfy a
    /// step-up requirement.
    public func stepUpEvidence(for kind: PhoneControlSigningKeyKind) -> StepUpEvidence {
        switch kind {
        case .secureEnclaveP256:
            return .enforcedBySecureEnclaveSignature
        case .ed25519:
            return .requiresExplicitLocalAuthProof
        }
    }

    /// Convenience for the validator chokepoint: given the action's capabilities
    /// and the signing key kind, does the envelope additionally need an explicit
    /// local-auth proof attached? (True only for sensitive actions signed by a
    /// legacy software key.)
    public func requiresExplicitLocalAuthProof(
        capabilities: Set<AgentDesktopCapability>,
        keyKind: PhoneControlSigningKeyKind
    ) -> Bool {
        guard requiresStepUp(capabilities: capabilities) else { return false }
        return stepUpEvidence(for: keyKind) == .requiresExplicitLocalAuthProof
    }
}

import Foundation

/// Remote Config `computer_use_phone_control_attestation_required` drives strict mode.
public enum PhoneControlAttestationRequirement: Equatable, Sendable {
    /// No attestation gate on the authority envelope.
    case none
    /// Envelope must include a non-empty `attestationHashBlake3` (phone-side App Check bind).
    case requirePresent
    /// Envelope must match an exact digest (same-device or pre-registered peer digest).
    case required(digest: String)
    /// Strict RC on but Mac host has no fresh `obb_app_check` binding — reject all phone control.
    case rejectUnboundHost
}

public enum PhoneControlAttestationPolicy {
    public static let remoteConfigKey = "computer_use_phone_control_attestation_required"

    /// Maps RC strict flag + Mac host bind state into validator input.
    ///
    /// Phone envelopes carry the **controller app's** App Check digest (iOS/Android app id).
    /// The Mac host digest uses a different App Check app id, so strict mode requires
    /// presence of phone attestation, not equality with the Mac digest.
    public static func requirement(strictMode: Bool, macHostHasBoundClaim: Bool) -> PhoneControlAttestationRequirement {
        guard strictMode else {
            return .none
        }
        guard macHostHasBoundClaim else {
            return .rejectUnboundHost
        }
        return .requirePresent
    }
}

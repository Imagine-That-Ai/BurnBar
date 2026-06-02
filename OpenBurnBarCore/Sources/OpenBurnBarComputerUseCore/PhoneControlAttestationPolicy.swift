import Foundation

/// Remote Config `computer_use_phone_control_attestation_required` drives strict mode.
public enum PhoneControlAttestationRequirement: Equatable, Sendable {
    /// Permissive: enforce digest only when Mac has a bound claim (legacy behavior).
    case none
    /// Envelope `attestationHashBlake3` must equal the Mac user's bound digest.
    case required(digest: String)
    /// Strict RC on but Mac host has no fresh `obb_app_check` binding — reject all phone control.
    case rejectUnboundHost
}

public enum PhoneControlAttestationPolicy {
    public static let remoteConfigKey = "computer_use_phone_control_attestation_required"

    /// Maps RC strict flag + Mac-bound digest into validator input.
    public static func requirement(
        strictMode: Bool,
        macBoundDigest: String?
    ) -> PhoneControlAttestationRequirement {
        guard strictMode else {
            guard let macBoundDigest, !macBoundDigest.isEmpty else {
                return .none
            }
            return .required(digest: macBoundDigest)
        }
        guard let macBoundDigest, !macBoundDigest.isEmpty else {
            return .rejectUnboundHost
        }
        return .required(digest: macBoundDigest)
    }
}
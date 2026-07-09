import Foundation

/// Pure presentation helpers shared by the Apple Community surfaces.
///
/// The leaderboard views stay SwiftUI-only; this type owns the small but
/// user-visible copy/number contracts that must not drift between macOS and iOS.
public enum CommunityDisplayFormatter {

    public static func compactTokenCount(_ value: Int64) -> String {
        let clamped = max(value, 0)
        if clamped >= 1_000_000 {
            return compact(clamped, divisor: 1_000_000, suffix: "M")
        }
        if clamped >= 1_000 {
            return compact(clamped, divisor: 1_000, suffix: "K")
        }
        return "\(clamped)"
    }

    private static func compact(_ value: Int64, divisor: Int64, suffix: String) -> String {
        var whole = value / divisor
        let remainder = value % divisor
        var decimal = (remainder * 10 + divisor / 2) / divisor
        if decimal == 10 {
            whole += 1
            decimal = 0
        }
        return "\(whole).\(decimal)\(suffix)"
    }

    public static func participantDisplayName(handle: String?, anonId: String) -> String {
        if let handle = handle?.trimmingCharacters(in: .whitespacesAndNewlines), !handle.isEmpty {
            return handle
        }
        return "anon-\(anonId.prefix(6))"
    }

    /// Public below-threshold boards intentionally report `cohortSize == 0`.
    /// Keeping this helper shared prevents one platform from leaking closeness
    /// to k-anonymity while another shows the withheld fixed threshold.
    public static func thresholdNeededCount(kThreshold: Int, cohortSize: Int) -> Int {
        max(kThreshold - max(cohortSize, 0), 1)
    }

    public static func belowThresholdTitle(kThreshold: Int, cohortSize: Int, tierLabel: String) -> String {
        "Needs \(thresholdNeededCount(kThreshold: kThreshold, cohortSize: cohortSize)) more burners in \(tierLabel.lowercased())"
    }

    public static func leaderboardUnavailableText(geoLabel: String) -> String {
        "Leaderboard unavailable for \(geoLabel)."
    }
}

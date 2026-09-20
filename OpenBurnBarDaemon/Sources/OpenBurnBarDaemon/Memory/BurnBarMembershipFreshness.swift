import Foundation
import OpenBurnBarEngine

/// Pro gating for memory egress reads the daemon's offline membership cache.
/// The cache has no TTL of its own, so "Pro" means: an active snapshot that
/// carries a Pro entitlement id and was refreshed within `maxCacheAge`.
/// Anything else fails closed to free.
public enum BurnBarMembershipFreshness {
    public static let proEntitlementIDs: Set<String> = ["burnbar_pro", "burnbar_pro_max", "hosted_quota_sync"]
    public static let maxCacheAge: TimeInterval = 7 * 24 * 3_600

    public static func updatedAtDate(_ snapshot: BurnBarMembershipSnapshot) -> Date? {
        guard let raw = snapshot.updatedAt?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: raw)
    }

    public static func isProActive(
        _ snapshot: BurnBarMembershipSnapshot,
        now: Date,
        maxAge: TimeInterval = maxCacheAge
    ) -> Bool {
        guard snapshot.state == .active else { return false }
        guard !proEntitlementIDs.isDisjoint(with: snapshot.entitlementIds) else { return false }
        guard let updatedAt = updatedAtDate(snapshot) else { return false }
        let age = now.timeIntervalSince(updatedAt)
        return age >= 0 && age <= maxAge
    }

    public static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

import Foundation

/// Fail-closed inventory parser. Only well-known array keys produce credits.
/// Unknown payloads return `[]` so the detector never invents a banked event.
public enum QuotaResetCreditParser {
    private static let inventoryKeys = [
        "reset_credits",
        "banked_resets",
        "rate_limit_resets",
        "reset_cards",
        "usage_resets",
        "bankedResets",
        "resetCredits",
        "resetCards"
    ]

    public static func parse(payload: Data, now: Date = Date()) -> [QuotaResetCredit] {
        guard let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return []
        }
        return parse(root: root, now: now)
    }

    public static func parse(root: [String: Any], now: Date = Date()) -> [QuotaResetCredit] {
        for key in inventoryKeys {
            if let array = root[key] as? [[String: Any]] {
                let parsed = array.compactMap { parseCredit($0, now: now) }
                if !parsed.isEmpty { return parsed }
            }
        }
        return []
    }

    private static func parseCredit(_ object: [String: Any], now: Date) -> QuotaResetCredit? {
        let id = string(object["id"])
            ?? string(object["credit_id"])
            ?? string(object["reset_id"])
            ?? string(object["uuid"])
        guard let id, !id.isEmpty else { return nil }

        if bool(object["redeemed"]) == true || bool(object["used"]) == true || bool(object["consumed"]) == true {
            return nil
        }

        let expiresAt = date(object["expires_at"]) ?? date(object["expiresAt"]) ?? date(object["expiry"])
        if let expiresAt, expiresAt <= now { return nil }

        let grantedAt = date(object["granted_at"]) ?? date(object["grantedAt"]) ?? date(object["created_at"])
        let source = source(from: string(object["source"]) ?? string(object["reason"]))
        return QuotaResetCredit(id: id, expiresAt: expiresAt, grantedAt: grantedAt, source: source)
    }

    private static func source(from raw: String?) -> QuotaResetCreditSource {
        switch raw?.lowercased() {
        case "promo", "promotional", "promotion":
            return .promotional
        case "referral", "refer":
            return .referral
        case "manual", "admin", "support":
            return .manual
        default:
            return .unknown
        }
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = value as? CustomStringConvertible, !(value is NSNull) {
            let trimmed = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? String {
            switch value.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        if let value = value as? TimeInterval, value > 1_000_000_000 {
            return Date(timeIntervalSince1970: value)
        }
        if let value = value as? Int, value > 1_000_000_000 {
            return Date(timeIntervalSince1970: TimeInterval(value))
        }
        if let value = value as? String {
            return ThreadSafeISO8601DateFormatter.parse(value)
        }
        return nil
    }
}

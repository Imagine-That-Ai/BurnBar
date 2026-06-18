import Foundation

/// Naming-scheme validators. Event names are `surface.object.action`
/// (lowercase, dot-segmented, snake within a segment); property keys are
/// `snake_case`. Enforced by tests so a typo can't ship an off-taxonomy name.
enum AnalyticsName {
    // Each dot-separated segment is a snake_case word (alnum groups joined by
    // single underscores); the name has at least two segments. Accepts
    // `auth.sign_in.completed` and `mission_console.opened`; rejects leading/
    // trailing/double underscores and camelCase.
    static let eventPattern = "^[a-z0-9]+(_[a-z0-9]+)*(\\.[a-z0-9]+(_[a-z0-9]+)*)+$"
    static let propertyPattern = "^[a-z0-9]+(_[a-z0-9]+)*$"

    static func isValidEventName(_ s: String) -> Bool { matches(s, eventPattern) }
    static func isValidPropertyKey(_ s: String) -> Bool { matches(s, propertyPattern) }

    private static func matches(_ s: String, _ pattern: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}

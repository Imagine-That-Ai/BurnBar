import Foundation

/// A property value the wrapper may send. Deliberately limited to strings and
/// booleans — there is **no case for a raw number**, so a bare Int/Double can
/// never reach the wire (anti-fingerprinting). Numerics must pass through
/// `AnalyticsBuckets`, which returns a `.string` bucket label.
enum AnalyticsValue: Equatable, Sendable, ExpressibleByStringLiteral, ExpressibleByBooleanLiteral {
    case string(String)
    case bool(Bool)

    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }

    /// Native value for the Amplitude SDK's `[String: Any]` payload.
    var anyValue: Any {
        switch self {
        case .string(let s): return s
        case .bool(let b): return b
        }
    }
}

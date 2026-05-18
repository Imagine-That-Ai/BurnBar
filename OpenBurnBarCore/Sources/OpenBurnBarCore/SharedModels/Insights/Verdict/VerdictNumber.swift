import Foundation

/// A single headline KPI tile under the verdict hero.
///
/// Three to four numbers, monospace digits, each with a delta chip and a
/// sparkline. The renderer treats this as a horizontal strip on macOS/iPad
/// and a 2-column grid on iPhone.
public struct VerdictNumber: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// Short label rendered above the value ("Spend", "Cache hit", "Sonnet calls").
    public var label: String
    /// The headline value rendered prominently. Use the formatter that
    /// matches the unit (`$4.12`, `91%`, `27`).
    public var value: String
    /// Raw numeric value — preserved so renderers can use Swift Charts
    /// or animate value transitions.
    public var rawValue: Double
    public var unit: VerdictDelta.Unit
    /// Optional delta vs prior period.
    public var delta: VerdictDelta?
    /// Optional 14-point sparkline (most-recent-last) — bounded so renderers
    /// can fit it under the value without measuring.
    public var sparkline: [Double]?
    /// Tap routes to the underlying drill-down (a session list, a chart, etc).
    /// `nil` for purely informational numbers.
    public var drillIntent: VerdictAcceptAction.Intent?
    /// Payload that the renderer hands to the drill intent if the user taps.
    public var drillPayload: [String: String]?

    public init(
        id: String,
        label: String,
        value: String,
        rawValue: Double,
        unit: VerdictDelta.Unit,
        delta: VerdictDelta? = nil,
        sparkline: [Double]? = nil,
        drillIntent: VerdictAcceptAction.Intent? = nil,
        drillPayload: [String: String]? = nil
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.rawValue = rawValue
        self.unit = unit
        self.delta = delta
        self.sparkline = sparkline?.suffix(14).map { $0 }
        self.drillIntent = drillIntent
        self.drillPayload = drillPayload
    }
}

import Foundation
import OpenBurnBarInsights
import OpenBurnBarKernel

// MARK: - Vocabulary

/// What sort of thing an insight is. Drives both the visual treatment and the
/// diversity cap — a deck of seven `record` cards is a worse deck than one with
/// a record, a trend and a fun fact, even if the records score higher.
public enum RecapInsightKind: String, Codable, Hashable, Sendable, CaseIterable {
    case record
    case anomaly
    case trend
    case milestone
    case funFact
    case comparison
    case personality
}

public extension RecapInsightKind {
    /// How prominently the label is being shown.
    enum LabelStyle: Sendable {
        /// Hero cards and share exports, where there is room.
        case long
        /// Tiles and standard cards, where the eyebrow is one short line.
        case short
    }

    /// The eyebrow shown above a card's headline.
    ///
    /// Lives here rather than in each renderer so an eighth kind is one edit,
    /// not four — three of which the compiler would not catch.
    func label(_ style: LabelStyle = .long) -> String {
        switch (self, style) {
        case (.record, .long):      return "Personal record"
        case (.record, .short):     return "Record"
        case (.milestone, _):       return "Milestone"
        case (.anomaly, .long):     return "Worth a look"
        case (.anomaly, .short):    return "Unusual"
        case (.trend, .long):       return "What changed"
        case (.trend, .short):      return "Trend"
        case (.comparison, .long):  return "Compared"
        case (.comparison, .short): return "Change"
        case (.funFact, _):         return "Did you know"
        case (.personality, .long): return "How you work"
        case (.personality, .short): return "Your habit"
        }
    }
}

/// The emotional register the copy should sit in.
public enum RecapTone: String, Codable, Hashable, Sendable, CaseIterable {
    case celebratory
    case reflective
    case curious
    case playful
    case matterOfFact
}

/// How the card should draw itself. A recommendation, not a command — the
/// renderer may fall back when the data can't support the visual.
public enum RecapVisual: String, Codable, Hashable, Sendable, CaseIterable {
    /// Typography only. Some of the best cards have no chart at all.
    case none
    case bigNumber
    case ranking
    case donut
    case sparkline
    case bars
    case heatmap
    case rings
    case beforeAfter
    case timeline
    case streak
    case spotlight
}

/// Unit of a supporting metric. Determines both formatting and how the numeric
/// guard expands a value into acceptable written forms.
public enum RecapMetricUnit: String, Codable, Hashable, Sendable {
    case usd
    case tokens
    case count
    case percent
    case days
    case hours
    case minutes
    case ordinal
}

// MARK: - Metric

/// One number a candidate is allowed to talk about.
///
/// This is the whole numeric vocabulary of the card. The voice post-processor
/// rejects any figure in LLM-written copy that cannot be traced back to one of
/// these — which is what stops a fluent model from inventing a plausible number.
public struct RecapMetric: Codable, Hashable, Sendable, Identifiable {
    public let label: String
    public let value: Double
    public let unit: RecapMetricUnit
    /// Canonical rendering, e.g. "$41.20", "41%", "9".
    public let formatted: String

    public var id: String { "\(label)|\(formatted)" }

    public init(label: String, value: Double, unit: RecapMetricUnit, formatted: String) {
        self.label = label
        self.value = value
        self.unit = unit
        self.formatted = formatted
    }

    /// Convenience that derives `formatted` from the unit.
    public init(_ label: String, _ value: Double, _ unit: RecapMetricUnit) {
        self.init(label: label, value: value, unit: unit, formatted: RecapMetric.format(value, unit))
    }

    public static func format(_ value: Double, _ unit: RecapMetricUnit) -> String {
        switch unit {
        case .usd:
            return value >= 100
                ? "$\(Int(value.rounded()))"
                : String(format: "$%.2f", value)
        case .tokens:
            return abbreviatedCount(value)
        case .count:
            return String(Int(value.rounded()))
        case .percent:
            return "\(Int((value * 100).rounded()))%"
        case .days:
            let whole = Int(value.rounded())
            return "\(whole) day\(whole == 1 ? "" : "s")"
        case .hours:
            return value < 10 ? String(format: "%.1f hours", value) : "\(Int(value.rounded())) hours"
        case .minutes:
            let whole = Int(value.rounded())
            return "\(whole) minute\(whole == 1 ? "" : "s")"
        case .ordinal:
            return String(Int(value.rounded()))
        }
    }

    private static func abbreviatedCount(_ value: Double) -> String {
        let magnitude = abs(value)
        switch magnitude {
        case 1_000_000_000...:
            return String(format: "%.1fB", value / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.1fM", value / 1_000_000)
        case 1_000...:
            return String(format: "%.0fK", value / 1_000)
        default:
            return String(Int(value.rounded()))
        }
    }
}

// MARK: - Comparison

/// What a candidate is measured against. Absent when the month has no history
/// to compare with — the recap simply stops making comparisons rather than
/// inventing a baseline of zero.
public struct RecapComparison: Codable, Hashable, Sendable {

    public enum Basis: String, Codable, Hashable, Sendable {
        case previousMonth
        case personalAverage
        case allTimeRecord
        /// Compared against an even spread — used by concentration claims
        /// ("a third of your sessions were on Tuesdays").
        case uniform
        /// The first time this thing has been seen at all.
        case firstEver
    }

    public let basis: Basis
    /// Human label for the reference: "July", "your average month", "your previous best".
    public let referenceLabel: String
    public let currentValue: Double
    public let referenceValue: Double
    public let unit: RecapMetricUnit

    public init(
        basis: Basis,
        referenceLabel: String,
        currentValue: Double,
        referenceValue: Double,
        unit: RecapMetricUnit
    ) {
        self.basis = basis
        self.referenceLabel = referenceLabel
        self.currentValue = currentValue
        self.referenceValue = referenceValue
        self.unit = unit
    }

    /// Relative change, or nil when the reference is zero (in which case there
    /// is no meaningful percentage — "up from nothing" is a different claim).
    public var deltaFraction: Double? {
        guard referenceValue != 0 else { return nil }
        return (currentValue - referenceValue) / abs(referenceValue)
    }

    public var isIncrease: Bool { currentValue > referenceValue }
}

// MARK: - Visual payload

/// The data a card's visual needs, carried alongside the copy so the renderer
/// never has to reach back into the facts.
public enum RecapVisualData: Codable, Hashable, Sendable {
    /// One series, e.g. daily cost across the month.
    case series([Double])
    /// Two aligned series for before/after curves.
    case dualSeries(current: [Double], reference: [Double])
    /// Ranked rows for ranking, donut and bar treatments.
    case ranked([RecapRankedEntry])
    /// 7×24 heatmap.
    case matrix([[Double]])
    /// Progress rings, 0…1 each.
    case rings([RecapRingValue])
    /// A single before → after pair.
    case pair(before: Double, after: Double)
    /// Active-day flags across the month.
    case streak([Bool])
}

public struct RecapRankedEntry: Codable, Hashable, Sendable, Identifiable {
    public let key: String
    public let label: String
    public let value: Double
    /// 0…1 within the ranking, for bar widths and donut arcs.
    public let fraction: Double
    /// Optional colour seed — a model or provider name the renderer can tint by.
    public let colorSeed: String?

    public var id: String { key }

    public init(key: String, label: String, value: Double, fraction: Double, colorSeed: String? = nil) {
        self.key = key
        self.label = label
        self.value = value
        self.fraction = fraction
        self.colorSeed = colorSeed
    }
}

public struct RecapRingValue: Codable, Hashable, Sendable, Identifiable {
    public let label: String
    /// 0…1, may exceed 1 when a record is beaten.
    public let progress: Double
    public let caption: String

    public var id: String { label }

    public init(label: String, progress: Double, caption: String) {
        self.label = label
        self.progress = progress
        self.caption = caption
    }
}

// MARK: - Candidate

/// One thing the recap could say, with everything needed to say it.
///
/// Produced by `RecapCandidateGenerator` with real numbers and deterministic
/// copy already filled in, so a candidate is shippable as-is. The LLM layer only
/// ever *replaces the prose*, never the metrics.
public struct RecapCandidate: Codable, Hashable, Sendable, Identifiable {

    /// Stable across runs and months: `"favourite-model:claude-opus-5"`.
    /// Stability matters because the LLM addresses candidates by id.
    public let id: String
    /// Which rule produced this, for diversity capping and debugging.
    public let ruleID: String
    /// Subject grouping for the diversity pass — two candidates about the same
    /// model, or both about cache, share a family and compete for one slot.
    public let family: String

    public let kind: RecapInsightKind
    public let tone: RecapTone

    /// Deterministic headline. Shipped verbatim when there is no LLM.
    public let headline: String
    /// Deterministic supporting sentence.
    public let body: String

    public let metrics: [RecapMetric]
    public let comparison: RecapComparison?

    public let visual: RecapVisual
    public let visualData: RecapVisualData?
    public let suggestedSize: RecapCardSize

    /// How surprising this is — has the user seen it before? 0…1.
    public let novelty: Double
    /// How statistically real the effect is, from a test appropriate to the
    /// claim (proportion test, chi-square, margin over prior record). 0…1.
    public let significance: Double
    /// How much this is about *them* rather than trivia. 0…1.
    public let relevance: Double
    /// Data quality behind the claim — folds in provenance. 0…1.
    public let confidence: Double

    public init(
        id: String,
        ruleID: String,
        family: String,
        kind: RecapInsightKind,
        tone: RecapTone,
        headline: String,
        body: String,
        metrics: [RecapMetric],
        comparison: RecapComparison? = nil,
        visual: RecapVisual,
        visualData: RecapVisualData? = nil,
        suggestedSize: RecapCardSize,
        novelty: Double,
        significance: Double,
        relevance: Double,
        confidence: Double
    ) {
        self.id = id
        self.ruleID = ruleID
        self.family = family
        self.kind = kind
        self.tone = tone
        self.headline = headline
        self.body = body
        self.metrics = metrics
        self.comparison = comparison
        self.visual = visual
        self.visualData = visualData
        self.suggestedSize = suggestedSize
        self.novelty = RecapStatistics.clamp(novelty)
        self.significance = RecapStatistics.clamp(significance)
        self.relevance = RecapStatistics.clamp(relevance)
        self.confidence = RecapStatistics.clamp(confidence)
    }

    /// The ranking score from the brief:
    /// novelty x significance x personal relevance x confidence.
    ///
    /// A product, not a sum, on purpose — a candidate that is certain but
    /// unsurprising, or surprising but unreliable, should not crowd out one
    /// that is both.
    public var interestingness: Double {
        novelty * significance * relevance * confidence
    }
}

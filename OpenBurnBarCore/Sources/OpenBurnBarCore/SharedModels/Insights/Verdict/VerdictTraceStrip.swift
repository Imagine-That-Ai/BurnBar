import Foundation

/// A miniature Vercel-style horizontal flame strip of a single session,
/// rendered immediately below the verdict hero.
///
/// The trace strip is the highest-leverage new visual — it is what makes
/// the verdict feel like an *X-ray* of the day rather than a stat sheet.
/// Tap any lane to open the full session trace view; the strip itself is
/// optimized for at-a-glance pattern recognition.
public struct VerdictTraceStrip: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var sessionID: String
    /// Up to 5 horizontal lanes (model, tool, cache, prompt, response).
    public var lanes: [TraceLane]
    /// Tick marks (cost ticks every N seconds). Bounded to avoid bloat.
    public var ticks: [TraceTick]
    public var startedAt: Date
    public var endedAt: Date
    /// One-line "what happened" summary (≤80 chars).
    public var summary: String
    /// USD spend over the session.
    public var costUSD: Double
    /// Whether the session ended in a timeout or hard error.
    public var didTimeout: Bool
    /// Tint identity (typically the dominant provider for this session).
    public var tint: ProviderTint

    public init(
        id: UUID = UUID(),
        sessionID: String,
        lanes: [TraceLane],
        ticks: [TraceTick] = [],
        startedAt: Date,
        endedAt: Date,
        summary: String,
        costUSD: Double,
        didTimeout: Bool = false,
        tint: ProviderTint = .neutral
    ) {
        self.id = id
        self.sessionID = sessionID
        self.lanes = lanes
        self.ticks = ticks
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.summary = summary
        self.costUSD = costUSD
        self.didTimeout = didTimeout
        self.tint = tint
    }

    public var duration: TimeInterval {
        max(0, endedAt.timeIntervalSince(startedAt))
    }
}

/// A single lane (model call, tool dispatch, cache hit, prompt streamed,
/// response streamed) in the strip.
public struct TraceLane: Codable, Hashable, Sendable, Identifiable {

    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case model
        case tool
        case cache
        case prompt
        case response
        case retry
    }

    public var id: UUID
    public var kind: Kind
    /// Short label ("claude-sonnet-4-6", "Read", "cache_hit").
    public var label: String
    /// Time offset from the strip's `startedAt`.
    public var startOffset: TimeInterval
    public var duration: TimeInterval
    /// Optional cost stamp for the lane (used by the cost ticks).
    public var costUSD: Double?
    public var tint: ProviderTint

    public init(
        id: UUID = UUID(),
        kind: Kind,
        label: String,
        startOffset: TimeInterval,
        duration: TimeInterval,
        costUSD: Double? = nil,
        tint: ProviderTint = .neutral
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.startOffset = startOffset
        self.duration = duration
        self.costUSD = costUSD
        self.tint = tint
    }
}

/// A discrete cost or event tick rendered on the bottom axis of the strip.
public struct TraceTick: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var offset: TimeInterval
    /// USD spent at this tick.
    public var costUSD: Double
    /// Short label rendered above the tick if not crowded out.
    public var label: String?

    public init(
        id: UUID = UUID(),
        offset: TimeInterval,
        costUSD: Double,
        label: String? = nil
    ) {
        self.id = id
        self.offset = offset
        self.costUSD = costUSD
        self.label = label
    }
}

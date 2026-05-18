import Foundation

/// The single top-level value the verdict pipeline produces.
///
/// Voice contract §3.1 — the verdict is *always* present, always
/// fresh-or-stale, always the dominant frame above the canvas. The
/// schema is the design system; the renderer never invents new fields.
///
/// Voice contract §6.4 — every shipped LLM verdict survives
/// `InsightVoicePostProcessor`. The rule-based engine produces a
/// guaranteed-shape verdict in the absence of any LLM so the surface
/// never blanks.
public struct InsightVerdict: Codable, Hashable, Sendable, Identifiable {

    public static let currentSchemaVersion: Int = 1

    public var id: UUID
    public var schemaVersion: Int
    public var generatedAt: Date
    public var window: VerdictWindow
    /// ≤80 chars. Declarative; no "Welcome back". The post-processor truncates.
    public var headline: String
    /// ≤120 chars. The one-sentence amplification.
    public var subhead: String?
    /// Exactly three rings (`spend`, `cache`, `sessions`). The renderer
    /// asserts the count so the layout never breaks.
    public var rings: [VerdictRing]
    /// Three or four KPI tiles below the rings.
    public var keyNumbers: [VerdictNumber]
    /// Yesterday's most consequential session — surfaced as a horizontal
    /// flame strip. `nil` when there was no session worth surfacing.
    public var sessionTrace: VerdictTraceStrip?
    /// One to four specific claims. Always ≥1 citation each.
    public var bullets: [VerdictBullet]
    /// Surface only when the underlying robust z-score >2.
    public var anomaly: VerdictAnomaly?
    /// Surface only with an `acceptAction`.
    public var recommendation: VerdictRecommendation?
    /// Drives the dominant accent on the hero card.
    public var moodSwatch: ProviderTint
    /// Who authored this verdict — `localRules`, a user-owned model, or hosted.
    public var provenance: InsightModelTag
    public var confidence: InsightConfidence
    /// Three suggested follow-up questions for the composer's chip strip.
    public var followUps: [String]
    /// Whether this verdict was authored by the rule engine alone
    /// (true) or upgraded by an LLM after post-processing (false).
    public var isRuleBased: Bool
    /// Stable hash of the verdict's content (excluding `id`/`generatedAt`).
    /// Used by the cache to deduplicate identical re-computations.
    public var contentHash: String

    public init(
        id: UUID = UUID(),
        schemaVersion: Int = InsightVerdict.currentSchemaVersion,
        generatedAt: Date = Date(),
        window: VerdictWindow,
        headline: String,
        subhead: String? = nil,
        rings: [VerdictRing],
        keyNumbers: [VerdictNumber] = [],
        sessionTrace: VerdictTraceStrip? = nil,
        bullets: [VerdictBullet] = [],
        anomaly: VerdictAnomaly? = nil,
        recommendation: VerdictRecommendation? = nil,
        moodSwatch: ProviderTint = .neutral,
        provenance: InsightModelTag,
        confidence: InsightConfidence = .medium,
        followUps: [String] = [],
        isRuleBased: Bool = false,
        contentHash: String = ""
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.window = window
        self.headline = String(headline.prefix(InsightVerdict.headlineMaxLength))
        self.subhead = subhead.map { String($0.prefix(InsightVerdict.subheadMaxLength)) }
        self.rings = rings
        self.keyNumbers = Array(keyNumbers.prefix(InsightVerdict.maxKeyNumbers))
        self.sessionTrace = sessionTrace
        self.bullets = Array(bullets.prefix(InsightVerdict.maxBullets))
        self.anomaly = anomaly
        self.recommendation = recommendation
        self.moodSwatch = moodSwatch
        self.provenance = provenance
        self.confidence = confidence
        self.followUps = Array(followUps.prefix(InsightVerdict.maxFollowUps))
        self.isRuleBased = isRuleBased
        self.contentHash = contentHash
    }

    // MARK: - Hard limits enforced by the schema

    public static let headlineMaxLength: Int = 80
    public static let subheadMaxLength: Int = 120
    public static let maxBullets: Int = 4
    public static let maxKeyNumbers: Int = 4
    public static let maxFollowUps: Int = 3
    public static let requiredRingCount: Int = 3

    // MARK: - Safe decoding (forward-compatibility for added fields)

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, generatedAt, window
        case headline, subhead, rings, keyNumbers, sessionTrace, bullets
        case anomaly, recommendation, moodSwatch, provenance, confidence
        case followUps, isRuleBased, contentHash
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion))
            ?? InsightVerdict.currentSchemaVersion
        self.generatedAt = (try? c.decode(Date.self, forKey: .generatedAt)) ?? Date()
        self.window = try c.decode(VerdictWindow.self, forKey: .window)
        self.headline = try c.decode(String.self, forKey: .headline)
        self.subhead = try? c.decode(String.self, forKey: .subhead)
        self.rings = (try? c.decode([VerdictRing].self, forKey: .rings)) ?? []
        self.keyNumbers = (try? c.decode([VerdictNumber].self, forKey: .keyNumbers)) ?? []
        self.sessionTrace = try? c.decode(VerdictTraceStrip.self, forKey: .sessionTrace)
        self.bullets = (try? c.decode([VerdictBullet].self, forKey: .bullets)) ?? []
        self.anomaly = try? c.decode(VerdictAnomaly.self, forKey: .anomaly)
        self.recommendation = try? c.decode(VerdictRecommendation.self, forKey: .recommendation)
        self.moodSwatch = (try? c.decode(ProviderTint.self, forKey: .moodSwatch)) ?? .neutral
        self.provenance = try c.decode(InsightModelTag.self, forKey: .provenance)
        self.confidence = (try? c.decode(InsightConfidence.self, forKey: .confidence)) ?? .medium
        self.followUps = (try? c.decode([String].self, forKey: .followUps)) ?? []
        self.isRuleBased = (try? c.decode(Bool.self, forKey: .isRuleBased)) ?? false
        self.contentHash = (try? c.decode(String.self, forKey: .contentHash)) ?? ""
    }

    /// Whether this verdict has enough content to render without
    /// embarrassment. Used by the renderer's fallback gate.
    public var isRenderable: Bool {
        rings.count == InsightVerdict.requiredRingCount
        && !headline.isEmpty
        && (bullets.isEmpty || bullets.allSatisfy { !$0.citations.isEmpty })
    }
}

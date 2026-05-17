import Foundation
import CryptoKit

/// Deterministic, no-LLM verdict producer.
///
/// The rule-based engine is the spine of trust on the verdict surface —
/// no matter what's happening with the LLM adapters (offline, rate
/// limited, schema violations, paywalled), this engine produces a real
/// `InsightVerdict` from a digest in <50ms. The LLM is upgrade; the rule
/// engine is the guaranteed baseline.
///
/// Voice contract §3.2 and §3.9 are enforced here:
///   • every bullet has a number and a citation,
///   • recommendations only surface once data history is ≥14d/30d/60d
///     depending on the recommendation type,
///   • anomalies only surface when z>2 (already enforced upstream in the
///     digest's `PrecomputedAnomaly.score`).
public struct RuleBasedVerdictEngine: Sendable {

    /// Configurable thresholds — tests override; production uses defaults.
    public struct Thresholds: Sendable {
        public var cacheTargetRate: Double
        public var sessionTargetMinimum: Int
        public var spendBudgetFloor: Double
        public var spendBudgetGrowthRate: Double
        public var anomalyZThreshold: Double
        public var recommendationMinDailyHistory: Int
        public var trendsMinDailyHistory: Int
        public var forecastMinDailyHistory: Int

        public init(
            cacheTargetRate: Double = 0.85,
            sessionTargetMinimum: Int = 1,
            spendBudgetFloor: Double = 5.0,
            spendBudgetGrowthRate: Double = 1.2,
            anomalyZThreshold: Double = 2.0,
            recommendationMinDailyHistory: Int = 60,
            trendsMinDailyHistory: Int = 14,
            forecastMinDailyHistory: Int = 30
        ) {
            self.cacheTargetRate = cacheTargetRate
            self.sessionTargetMinimum = sessionTargetMinimum
            self.spendBudgetFloor = spendBudgetFloor
            self.spendBudgetGrowthRate = spendBudgetGrowthRate
            self.anomalyZThreshold = anomalyZThreshold
            self.recommendationMinDailyHistory = recommendationMinDailyHistory
            self.trendsMinDailyHistory = trendsMinDailyHistory
            self.forecastMinDailyHistory = forecastMinDailyHistory
        }

        public static let `default` = Thresholds()
    }

    public var thresholds: Thresholds
    public var calendar: Calendar

    public init(thresholds: Thresholds = .default, calendar: Calendar = .current) {
        self.thresholds = thresholds
        self.calendar = calendar
    }

    // MARK: - Entry point

    public func produce(
        digest: InsightDigest,
        window: VerdictWindow,
        priorDigest: InsightDigest? = nil,
        now: Date = Date()
    ) -> InsightVerdict {
        let rings = buildRings(digest: digest, prior: priorDigest)
        let keyNumbers = buildKeyNumbers(digest: digest, prior: priorDigest)
        let bullets = buildBullets(digest: digest, prior: priorDigest, window: window)
        let anomaly = buildAnomaly(from: digest)
        let recommendation = buildRecommendation(digest: digest, prior: priorDigest)
        let dominantProvider = digest.providers
            .max(by: { $0.costUSD < $1.costUSD })?.id
        let mood = ProviderTint.forProviderKey(dominantProvider)
        let headline = buildHeadline(
            digest: digest,
            prior: priorDigest,
            window: window
        )
        let subhead = buildSubhead(digest: digest, prior: priorDigest)
        let provenance = InsightModelTag(
            providerKey: "local-rules",
            modelID: "rule-based-v2",
            displayName: "Local rules",
            egressTier: .localOnly,
            stampedAt: now
        )
        let confidence = computeConfidence(digest: digest)
        let followUps = buildFollowUps(digest: digest, window: window)

        var verdict = InsightVerdict(
            generatedAt: now,
            window: window,
            headline: headline,
            subhead: subhead,
            rings: rings,
            keyNumbers: keyNumbers,
            sessionTrace: nil,
            bullets: bullets,
            anomaly: anomaly,
            recommendation: recommendation,
            moodSwatch: mood,
            provenance: provenance,
            confidence: confidence,
            followUps: followUps,
            isRuleBased: true,
            contentHash: ""
        )
        verdict.contentHash = RuleBasedVerdictEngine.hash(of: verdict)
        return verdict
    }

    // MARK: - Rings

    private func buildRings(
        digest: InsightDigest,
        prior: InsightDigest?
    ) -> [VerdictRing] {
        let totals = digest.totals
        let prior = prior?.totals

        let spendTarget = max(
            (prior?.costUSD ?? thresholds.spendBudgetFloor)
                * thresholds.spendBudgetGrowthRate,
            thresholds.spendBudgetFloor
        )
        let spendRing = VerdictRing(
            identity: .spend,
            label: "Spend",
            current: totals.costUSD,
            target: spendTarget,
            unit: .usd,
            valueLabel: "$\(Self.format(totals.costUSD, places: 2))"
                + " / $\(Self.format(spendTarget, places: 0))",
            delta: prior.flatMap {
                Self.delta(
                    current: totals.costUSD,
                    prior: $0.costUSD,
                    unit: .usd,
                    baseline: "vs prior period",
                    direction: .lowerIsBetter
                )
            },
            tint: ProviderTint.forProviderKey(
                digest.providers.max(by: { $0.costUSD < $1.costUSD })?.id
            )
        )

        let cacheRate = Self.cacheHitRate(totals: totals)
        let priorCacheRate = prior.map(Self.cacheHitRate(totals:))
        let cacheRing = VerdictRing(
            identity: .cache,
            label: "Cache",
            current: cacheRate * 100,
            target: thresholds.cacheTargetRate * 100,
            unit: .percent,
            valueLabel: "\(Int(round(cacheRate * 100)))%"
                + " / \(Int(round(thresholds.cacheTargetRate * 100)))%",
            delta: priorCacheRate.flatMap {
                Self.delta(
                    current: cacheRate * 100,
                    prior: $0 * 100,
                    unit: .percent,
                    baseline: "vs prior period",
                    direction: .higherIsBetter
                )
            },
            tint: .silver
        )

        let sessionTarget = max(
            Int(((prior?.sessionCount ?? 0) + 1)),
            thresholds.sessionTargetMinimum
        )
        let sessionsRing = VerdictRing(
            identity: .sessions,
            label: "Sessions",
            current: Double(totals.sessionCount),
            target: Double(sessionTarget),
            unit: .sessions,
            valueLabel: "\(totals.sessionCount) / \(sessionTarget)",
            delta: prior.flatMap {
                Self.delta(
                    current: Double(totals.sessionCount),
                    prior: Double($0.sessionCount),
                    unit: .sessions,
                    baseline: "vs prior period",
                    direction: .higherIsBetter
                )
            },
            tint: .mercury
        )

        return [spendRing, cacheRing, sessionsRing]
    }

    // MARK: - Key Numbers

    private func buildKeyNumbers(
        digest: InsightDigest,
        prior: InsightDigest?
    ) -> [VerdictNumber] {
        let totals = digest.totals
        let prior = prior?.totals

        var out: [VerdictNumber] = []

        out.append(
            VerdictNumber(
                id: "spend",
                label: "Spend",
                value: "$\(Self.format(totals.costUSD, places: 2))",
                rawValue: totals.costUSD,
                unit: .usd,
                delta: prior.flatMap {
                    Self.delta(
                        current: totals.costUSD,
                        prior: $0.costUSD,
                        unit: .usd,
                        baseline: "vs prior period",
                        direction: .lowerIsBetter
                    )
                }
            )
        )

        let cacheRate = Self.cacheHitRate(totals: totals) * 100
        out.append(
            VerdictNumber(
                id: "cache",
                label: "Cache hit",
                value: "\(Int(round(cacheRate)))%",
                rawValue: cacheRate,
                unit: .percent,
                delta: prior.flatMap {
                    Self.delta(
                        current: cacheRate,
                        prior: Self.cacheHitRate(totals: $0) * 100,
                        unit: .percent,
                        baseline: "vs prior period",
                        direction: .higherIsBetter
                    )
                }
            )
        )

        out.append(
            VerdictNumber(
                id: "sessions",
                label: "Sessions",
                value: "\(totals.sessionCount)",
                rawValue: Double(totals.sessionCount),
                unit: .sessions,
                delta: prior.flatMap {
                    Self.delta(
                        current: Double(totals.sessionCount),
                        prior: Double($0.sessionCount),
                        unit: .sessions,
                        baseline: "vs prior period",
                        direction: .higherIsBetter
                    )
                }
            )
        )

        if let topModel = digest.models.max(by: { $0.sessionCount < $1.sessionCount }) {
            out.append(
                VerdictNumber(
                    id: "top_model_calls_\(topModel.id)",
                    label: topModel.id,
                    value: "\(topModel.sessionCount)",
                    rawValue: Double(topModel.sessionCount),
                    unit: .sessions
                )
            )
        }

        return Array(out.prefix(InsightVerdict.maxKeyNumbers))
    }

    // MARK: - Bullets

    private func buildBullets(
        digest: InsightDigest,
        prior: InsightDigest?,
        window: VerdictWindow
    ) -> [VerdictBullet] {
        var bullets: [VerdictBullet] = []

        // 1. Spend vs prior period (always present when prior exists).
        if let prior = prior?.totals, prior.costUSD > 0 {
            let delta = (digest.totals.costUSD - prior.costUSD) / prior.costUSD * 100
            let direction = delta < 0 ? "under" : "over"
            let absPct = abs(delta).rounded(.toNearestOrEven)
            bullets.append(
                VerdictBullet(
                    type: .comparison,
                    claim: "You spent $\(Self.format(digest.totals.costUSD, places: 2)) "
                        + "— \(Int(absPct))% \(direction) the prior period.",
                    citations: dayCitations(from: digest, limit: 3),
                    delta: VerdictDelta(
                        value: delta,
                        unit: .percent,
                        baseline: "vs prior period",
                        direction: .lowerIsBetter
                    ),
                    confidence: .high
                )
            )
        } else if digest.totals.sessionCount > 0 {
            bullets.append(
                VerdictBullet(
                    type: .reflectiveFact,
                    claim: "You logged \(digest.totals.sessionCount) sessions, "
                        + "spending $\(Self.format(digest.totals.costUSD, places: 2)).",
                    citations: dayCitations(from: digest, limit: 3),
                    confidence: .high
                )
            )
        }

        // 2. Top use-case observation (if we have a clear winner).
        if let topUseCase = digest.useCaseHistogram
            .filter({ $0.count >= 2 })
            .max(by: { $0.count < $1.count }) {
            let pct = digest.totals.sessionCount > 0
                ? Double(topUseCase.count) / Double(digest.totals.sessionCount) * 100
                : 0
            bullets.append(
                VerdictBullet(
                    type: .pattern,
                    claim: "\(Int(pct.rounded()))% of your sessions were "
                        + "\(topUseCase.id) (\(topUseCase.count) total).",
                    citations: [
                        InsightCitation(
                            kind: .query(text: topUseCase.id),
                            label: topUseCase.id
                        )
                    ],
                    confidence: pct >= 30 ? .high : .medium
                )
            )
        }

        // 3. Cache hit observation when materially below target.
        let cacheRate = Self.cacheHitRate(totals: digest.totals)
        if cacheRate > 0 && cacheRate < thresholds.cacheTargetRate - 0.10 {
            bullets.append(
                VerdictBullet(
                    type: .pattern,
                    claim: "Cache hit rate is \(Int(round(cacheRate * 100)))% "
                        + "— \(Int(round((thresholds.cacheTargetRate - cacheRate) * 100))) "
                        + "points below the \(Int(thresholds.cacheTargetRate * 100))% target.",
                    citations: providerCitations(from: digest, limit: 2),
                    confidence: .medium
                )
            )
        } else if cacheRate >= thresholds.cacheTargetRate {
            if let topCacheProvider = digest.providers
                .filter({ $0.costUSD > 0 })
                .max(by: { $0.totalTokens < $1.totalTokens }) {
                bullets.append(
                    VerdictBullet(
                        type: .reflectiveFact,
                        claim: "Cache hit rate held at \(Int(round(cacheRate * 100)))% "
                            + "across \(digest.providers.count) providers "
                            + "(led by \(topCacheProvider.displayName)).",
                        citations: providerCitations(from: digest, limit: 2),
                        confidence: .high
                    )
                )
            }
        }

        // 4. Anomaly downgraded to bullet when there isn't an anomaly slot
        // already used at the verdict level.
        if let topAnomaly = digest.anomalies
            .filter({ $0.score >= thresholds.anomalyZThreshold })
            .max(by: { $0.score < $1.score }), bullets.count < InsightVerdict.maxBullets {
            bullets.append(
                VerdictBullet(
                    type: .anomaly,
                    claim: "\(topAnomaly.label) "
                        + "(z=\(Self.format(topAnomaly.score, places: 1))).",
                    citations: [
                        InsightCitation(
                            kind: .anomaly(id: topAnomaly.id),
                            label: topAnomaly.label
                        )
                    ],
                    confidence: .high
                )
            )
        }

        return Array(bullets.prefix(InsightVerdict.maxBullets))
    }

    // MARK: - Anomaly

    private func buildAnomaly(from digest: InsightDigest) -> VerdictAnomaly? {
        guard let top = digest.anomalies
            .filter({ $0.score >= thresholds.anomalyZThreshold })
            .max(by: { $0.score < $1.score }) else { return nil }
        return VerdictAnomaly(
            label: top.label,
            detail: top.detail ?? "",
            occurredAt: top.occurredAt,
            zScore: top.score,
            affectedSessionIDs: [],
            citations: [
                InsightCitation(
                    kind: .anomaly(id: top.id),
                    label: top.label
                )
            ],
            acceptAction: VerdictAcceptAction(
                label: "Investigate",
                intent: .investigate,
                payloadDict: ["anomalyID": top.id]
            )
        )
    }

    // MARK: - Recommendation

    private func buildRecommendation(
        digest: InsightDigest,
        prior: InsightDigest?
    ) -> VerdictRecommendation? {
        // Plan §3.9: recommendations unlock at 60 days of data.
        guard digest.daily.count >= thresholds.recommendationMinDailyHistory
        else { return nil }

        // Pick the largest model by tokens that has a meaningfully smaller
        // sibling on the same provider; recommend the sibling.
        let candidate = digest.models
            .filter { $0.sessionCount >= 5 && $0.costUSD >= 1.0 }
            .max(by: { $0.costUSD < $1.costUSD })
        guard let candidate else { return nil }

        let cheaperSibling = digest.models
            .filter {
                $0.providerID == candidate.providerID
                && $0.id != candidate.id
                && $0.avgCostPerSession < candidate.avgCostPerSession * 0.5
            }
            .min(by: { $0.avgCostPerSession < $1.avgCostPerSession })
        guard let cheaperSibling else { return nil }

        let perSessionDelta = candidate.avgCostPerSession - cheaperSibling.avgCostPerSession
        let weeklyImpact = perSessionDelta * Double(candidate.sessionCount)
        guard weeklyImpact >= 1.0 else { return nil }

        return VerdictRecommendation(
            headline: "Try \(cheaperSibling.id) for routine work",
            rationale: "\(candidate.id) cost "
                + "$\(Self.format(candidate.avgCostPerSession, places: 3)) per session; "
                + "\(cheaperSibling.id) averages "
                + "$\(Self.format(cheaperSibling.avgCostPerSession, places: 3)).",
            expectedImpact: "Saves ~$\(Self.format(weeklyImpact, places: 2))/period",
            acceptAction: VerdictAcceptAction(
                label: "Switch default",
                intent: .switchRouterRule,
                payloadDict: [
                    "providerID": candidate.providerID,
                    "fromModel": candidate.id,
                    "toModel": cheaperSibling.id
                ]
            ),
            citations: [
                InsightCitation(
                    kind: .model(id: candidate.id),
                    label: candidate.id
                ),
                InsightCitation(
                    kind: .model(id: cheaperSibling.id),
                    label: cheaperSibling.id
                )
            ],
            confidence: weeklyImpact >= 5.0 ? .high : .medium
        )
    }

    // MARK: - Headline / Subhead

    private func buildHeadline(
        digest: InsightDigest,
        prior: InsightDigest?,
        window: VerdictWindow
    ) -> String {
        let totals = digest.totals
        if totals.sessionCount == 0 {
            return "No sessions logged \(window.displayLabel.lowercased())."
        }
        let costStr = "$\(Self.format(totals.costUSD, places: 2))"
        guard let prior = prior?.totals, prior.costUSD > 0 else {
            return "You spent \(costStr) across \(totals.sessionCount) sessions "
                + "\(window.displayLabel.lowercased())."
        }
        let pct = abs((totals.costUSD - prior.costUSD) / prior.costUSD * 100)
        let direction = totals.costUSD < prior.costUSD ? "under" : "over"
        return "You spent \(costStr) \(window.displayLabel.lowercased()) "
            + "— \(Int(pct.rounded()))% \(direction) the prior period."
    }

    private func buildSubhead(
        digest: InsightDigest,
        prior: InsightDigest?
    ) -> String? {
        let cacheRate = Self.cacheHitRate(totals: digest.totals)
        guard cacheRate > 0 else { return nil }
        guard let topProvider = digest.providers
            .max(by: { $0.costUSD < $1.costUSD }) else { return nil }
        return "Cache hit \(Int(round(cacheRate * 100)))% "
            + "led by \(topProvider.displayName)."
    }

    // MARK: - Confidence

    private func computeConfidence(digest: InsightDigest) -> InsightConfidence {
        let dailyHistory = digest.daily.count
        if dailyHistory >= thresholds.recommendationMinDailyHistory {
            return .high
        }
        if dailyHistory >= thresholds.trendsMinDailyHistory {
            return .medium
        }
        return .low
    }

    // MARK: - Follow-ups

    private func buildFollowUps(digest: InsightDigest, window: VerdictWindow) -> [String] {
        var qs: [String] = []
        if let topModel = digest.models.max(by: { $0.costUSD < $1.costUSD }) {
            qs.append("Why did \(topModel.id) cost so much \(window.displayLabel.lowercased())?")
        }
        if let topProvider = digest.providers.max(by: { $0.costUSD < $1.costUSD }) {
            qs.append("Show me \(topProvider.displayName) by hour.")
        }
        if !digest.useCaseHistogram.isEmpty {
            qs.append("What was my most expensive use case?")
        }
        return Array(qs.prefix(InsightVerdict.maxFollowUps))
    }

    // MARK: - Citation helpers

    private func dayCitations(from digest: InsightDigest, limit: Int) -> [InsightCitation] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let days = digest.daily
            .sorted(by: { $0.day > $1.day })
            .prefix(limit)
        let cites = days.map { point in
            InsightCitation(
                kind: .day(date: formatter.string(from: point.day)),
                label: formatter.string(from: point.day)
            )
        }
        if cites.isEmpty {
            return [
                InsightCitation(
                    kind: .day(date: formatter.string(from: digest.generatedAt)),
                    label: formatter.string(from: digest.generatedAt)
                )
            ]
        }
        return Array(cites)
    }

    private func providerCitations(
        from digest: InsightDigest,
        limit: Int
    ) -> [InsightCitation] {
        let cites = digest.providers
            .sorted(by: { $0.costUSD > $1.costUSD })
            .prefix(limit)
            .map { p in
                InsightCitation(
                    kind: .agent(provider: p.id),
                    label: p.displayName
                )
            }
        if cites.isEmpty {
            return [
                InsightCitation(
                    kind: .agent(provider: "all"),
                    label: "All providers"
                )
            ]
        }
        return Array(cites)
    }

    // MARK: - Utilities

    static func cacheHitRate(totals: InsightDigest.Totals) -> Double {
        let denom = totals.cacheReadTokens + totals.inputTokens
        guard denom > 0 else { return 0 }
        return Double(totals.cacheReadTokens) / Double(denom)
    }

    static func delta(
        current: Double,
        prior: Double,
        unit: VerdictDelta.Unit,
        baseline: String,
        direction: VerdictDelta.Direction
    ) -> VerdictDelta? {
        guard prior != 0 else { return nil }
        let pct = (current - prior) / abs(prior) * 100
        return VerdictDelta(
            value: pct,
            unit: .percent,
            baseline: baseline,
            direction: direction
        )
    }

    static func format(_ value: Double, places: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = places
        formatter.maximumFractionDigits = places
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// SHA-256 of the encoded JSON with all synthetic UUIDs canonicalized
    /// and the volatile `generatedAt` / `contentHash` fields stripped.
    /// Two verdicts with the same semantic content always hash equal even
    /// when their bullets, citations, traces, and anomalies were re-built
    /// in different orders or in different processes.
    static func hash(of verdict: InsightVerdict) -> String {
        let canonical = canonicalized(verdict)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(canonical) else { return "" }
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private static let zeroUUID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!

    /// Returns a copy of `verdict` with every synthetic UUID replaced by
    /// the zero UUID and with `generatedAt` + `contentHash` set to fixed
    /// values. Use only for hashing/comparison — never persist.
    static func canonicalized(_ verdict: InsightVerdict) -> InsightVerdict {
        var copy = verdict
        copy.id = zeroUUID
        copy.generatedAt = Date(timeIntervalSince1970: 0)
        copy.contentHash = ""
        copy.bullets = copy.bullets.map(canonicalized(_:))
        copy.anomaly = copy.anomaly.map(canonicalized(_:))
        copy.recommendation = copy.recommendation.map(canonicalized(_:))
        copy.sessionTrace = copy.sessionTrace.map(canonicalized(_:))
        return copy
    }

    private static func canonicalized(_ b: VerdictBullet) -> VerdictBullet {
        VerdictBullet(
            id: zeroUUID,
            type: b.type,
            claim: b.claim,
            citations: b.citations.map(canonicalized(_:)),
            delta: b.delta,
            acceptAction: b.acceptAction,
            confidence: b.confidence
        )
    }

    private static func canonicalized(_ c: InsightCitation) -> InsightCitation {
        InsightCitation(id: zeroUUID, kind: c.kind, label: c.label)
    }

    private static func canonicalized(_ a: VerdictAnomaly) -> VerdictAnomaly {
        VerdictAnomaly(
            id: zeroUUID,
            label: a.label,
            detail: a.detail,
            occurredAt: a.occurredAt,
            zScore: a.zScore,
            affectedSessionIDs: a.affectedSessionIDs,
            citations: a.citations.map(canonicalized(_:)),
            acceptAction: a.acceptAction
        )
    }

    private static func canonicalized(_ r: VerdictRecommendation) -> VerdictRecommendation {
        VerdictRecommendation(
            id: zeroUUID,
            headline: r.headline,
            rationale: r.rationale,
            expectedImpact: r.expectedImpact,
            acceptAction: r.acceptAction,
            citations: r.citations.map(canonicalized(_:)),
            confidence: r.confidence
        )
    }

    private static func canonicalized(_ t: VerdictTraceStrip) -> VerdictTraceStrip {
        VerdictTraceStrip(
            id: zeroUUID,
            sessionID: t.sessionID,
            lanes: t.lanes.map { lane in
                TraceLane(
                    id: zeroUUID,
                    kind: lane.kind,
                    label: lane.label,
                    startOffset: lane.startOffset,
                    duration: lane.duration,
                    costUSD: lane.costUSD,
                    tint: lane.tint
                )
            },
            ticks: t.ticks.map { tick in
                TraceTick(
                    id: zeroUUID,
                    offset: tick.offset,
                    costUSD: tick.costUSD,
                    label: tick.label
                )
            },
            startedAt: t.startedAt,
            endedAt: t.endedAt,
            summary: t.summary,
            costUSD: t.costUSD,
            didTimeout: t.didTimeout,
            tint: t.tint
        )
    }
}

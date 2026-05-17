import Foundation

/// Enforces the voice contract on every LLM-authored verdict before it
/// reaches the renderer.
///
/// "Voice is enforced by post-processing." — voice contract §3.2. The
/// model is allowed to drift; the regex is not. Every bullet that survives
/// the post-processor:
///   • contains no banned phrase,
///   • contains at least one numeric token,
///   • cites only identifiers the caller deems valid,
///   • points to an `acceptAction.intent` in the closed registry (or has
///     its accept action demoted to absent).
///
/// If fewer than one bullet survives, the composer is expected to fall
/// back to the rule-based engine — never to ship an empty verdict.
public struct InsightVoicePostProcessor: Sendable {

    // MARK: - Inputs

    /// A closure the caller provides so the validator stays decoupled from
    /// the digest layout. Returning `true` keeps the citation; `false`
    /// drops it.
    public typealias CitationValidator = @Sendable (InsightCitation) -> Bool

    /// A blanket validator that accepts everything. Used when the caller
    /// only wants banned-phrase + numeric-token enforcement.
    public static let acceptAllCitations: CitationValidator = { _ in true }

    // MARK: - Result

    public enum Result: Sendable {
        case accepted(InsightVerdict, Report)
        case rejected(reason: RejectionReason, report: Report)
    }

    public struct Report: Sendable, Hashable {
        public var bannedPhraseHits: [String]
        public var bulletsDropped: Int
        public var bulletsAccepted: Int
        public var actionsDemoted: Int
        public var citationsRewritten: Int
        public var headlineTruncated: Bool
        public var subheadTruncated: Bool

        public init(
            bannedPhraseHits: [String] = [],
            bulletsDropped: Int = 0,
            bulletsAccepted: Int = 0,
            actionsDemoted: Int = 0,
            citationsRewritten: Int = 0,
            headlineTruncated: Bool = false,
            subheadTruncated: Bool = false
        ) {
            self.bannedPhraseHits = bannedPhraseHits
            self.bulletsDropped = bulletsDropped
            self.bulletsAccepted = bulletsAccepted
            self.actionsDemoted = actionsDemoted
            self.citationsRewritten = citationsRewritten
            self.headlineTruncated = headlineTruncated
            self.subheadTruncated = subheadTruncated
        }
    }

    public enum RejectionReason: String, Sendable, Hashable {
        case noBulletsAfterProcessing
        case headlineEmpty
        case headlineBannedPhrase
        case ringCountInvalid
        case provenanceMissing
    }

    // MARK: - State

    public var bannedPhrases: [String]
    public var allowedActionIntents: Set<String>

    public init(
        bannedPhrases: [String] = InsightVoiceSchemaV2.bannedPhrases,
        allowedActionIntents: Set<String> = InsightVoiceSchemaV2.allowedActionIntents
    ) {
        self.bannedPhrases = bannedPhrases.map { $0.lowercased() }
        self.allowedActionIntents = allowedActionIntents
    }

    // MARK: - Entry point

    public func process(
        _ candidate: InsightVerdict,
        citationValidator: CitationValidator = InsightVoicePostProcessor.acceptAllCitations
    ) -> Result {
        var report = Report()

        // Headline gate.
        if candidate.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .rejected(reason: .headlineEmpty, report: report)
        }
        if let hit = bannedPhraseHit(in: candidate.headline) {
            report.bannedPhraseHits.append(hit)
            return .rejected(reason: .headlineBannedPhrase, report: report)
        }
        var headline = candidate.headline
        if headline.count > InsightVerdict.headlineMaxLength {
            headline = String(headline.prefix(InsightVerdict.headlineMaxLength))
            report.headlineTruncated = true
        }

        // Subhead gate.
        var subhead = candidate.subhead
        if let s = subhead {
            if bannedPhraseHit(in: s) != nil {
                subhead = nil
            } else if s.count > InsightVerdict.subheadMaxLength {
                subhead = String(s.prefix(InsightVerdict.subheadMaxLength))
                report.subheadTruncated = true
            }
        }

        // Ring shape.
        guard candidate.rings.count == InsightVerdict.requiredRingCount else {
            return .rejected(reason: .ringCountInvalid, report: report)
        }

        // Provenance shape.
        guard !candidate.provenance.providerKey.isEmpty,
              !candidate.provenance.modelID.isEmpty else {
            return .rejected(reason: .provenanceMissing, report: report)
        }

        // Bullets.
        var keptBullets: [VerdictBullet] = []
        for bullet in candidate.bullets {
            switch processBullet(bullet, citationValidator: citationValidator) {
            case .keep(let cleaned, let demotedAction):
                keptBullets.append(cleaned)
                report.bulletsAccepted += 1
                if demotedAction { report.actionsDemoted += 1 }
            case .drop(let bannedHit):
                report.bulletsDropped += 1
                if let bannedHit { report.bannedPhraseHits.append(bannedHit) }
            }
        }
        keptBullets = Array(keptBullets.prefix(InsightVerdict.maxBullets))

        if keptBullets.isEmpty {
            return .rejected(reason: .noBulletsAfterProcessing, report: report)
        }

        // Anomaly / recommendation pass-through with citation validation.
        let cleanedAnomaly = candidate.anomaly.flatMap { anom -> VerdictAnomaly? in
            let validCites = anom.citations.filter(citationValidator)
            guard !validCites.isEmpty else { return nil }
            return VerdictAnomaly(
                id: anom.id,
                label: anom.label,
                detail: anom.detail,
                occurredAt: anom.occurredAt,
                zScore: anom.zScore,
                affectedSessionIDs: anom.affectedSessionIDs,
                citations: validCites,
                acceptAction: anom.acceptAction.flatMap(filterAction(_:))
            )
        }
        let cleanedRecommendation = candidate.recommendation
            .flatMap { rec -> VerdictRecommendation? in
                let validCites = rec.citations.filter(citationValidator)
                guard !validCites.isEmpty,
                      let action = filterAction(rec.acceptAction) else { return nil }
                if bannedPhraseHit(in: rec.headline) != nil
                    || bannedPhraseHit(in: rec.rationale) != nil {
                    report.bannedPhraseHits.append("recommendation")
                    return nil
                }
                return VerdictRecommendation(
                    id: rec.id,
                    headline: rec.headline,
                    rationale: rec.rationale,
                    expectedImpact: rec.expectedImpact,
                    acceptAction: action,
                    citations: validCites,
                    confidence: rec.confidence
                )
            }

        // Re-stamp content hash so the cache sees the cleaned verdict.
        var sanitized = candidate
        sanitized.headline = headline
        sanitized.subhead = subhead
        sanitized.bullets = keptBullets
        sanitized.anomaly = cleanedAnomaly
        sanitized.recommendation = cleanedRecommendation
        sanitized.confidence = recalibrate(
            base: sanitized.confidence,
            bullets: keptBullets,
            droppedCount: report.bulletsDropped
        )
        sanitized.contentHash = RuleBasedVerdictEngine.hash(of: sanitized)

        return .accepted(sanitized, report)
    }

    // MARK: - Bullet processing

    private enum BulletDecision {
        case keep(VerdictBullet, demotedAction: Bool)
        case drop(banned: String?)
    }

    private func processBullet(
        _ bullet: VerdictBullet,
        citationValidator: CitationValidator
    ) -> BulletDecision {
        if let hit = bannedPhraseHit(in: bullet.claim) {
            return .drop(banned: hit)
        }
        guard containsNumericToken(bullet.claim) else {
            return .drop(banned: nil)
        }
        let validCites = bullet.citations.filter(citationValidator)
        guard !validCites.isEmpty else {
            return .drop(banned: nil)
        }
        var demoted = false
        let action = bullet.acceptAction.flatMap { a -> VerdictAcceptAction? in
            let filtered = filterAction(a)
            if filtered == nil && bullet.acceptAction != nil {
                demoted = true
            }
            return filtered
        }
        // Recommendation type without an action is a contract violation —
        // demote it to `pattern` rather than dropping the entire bullet.
        var finalType = bullet.type
        if finalType == .recommendation && action == nil {
            finalType = .pattern
        }
        return .keep(
            VerdictBullet(
                id: bullet.id,
                type: finalType,
                claim: bullet.claim,
                citations: validCites,
                delta: bullet.delta,
                acceptAction: action,
                confidence: bullet.confidence
            ),
            demotedAction: demoted
        )
    }

    private func filterAction(_ action: VerdictAcceptAction) -> VerdictAcceptAction? {
        guard allowedActionIntents.contains(action.intent.rawValue) else { return nil }
        let label = String(action.label.prefix(28))
        return VerdictAcceptAction(
            label: label,
            intent: action.intent,
            payload: action.payload
        )
    }

    // MARK: - Confidence calibration

    private func recalibrate(
        base: InsightConfidence,
        bullets: [VerdictBullet],
        droppedCount: Int
    ) -> InsightConfidence {
        if droppedCount > bullets.count { return .low }
        if bullets.contains(where: { $0.citations.count >= 2 })
            && droppedCount == 0
            && base != .low {
            return .high
        }
        if bullets.count <= 1 { return .low }
        return base
    }

    // MARK: - Token checks

    /// True when `text` contains at least one digit run, optionally with a
    /// percent, dollar, or unit suffix.
    func containsNumericToken(_ text: String) -> Bool {
        text.range(of: "[0-9]", options: .regularExpression) != nil
    }

    /// Returns the first matched banned phrase (if any) — case-insensitive.
    func bannedPhraseHit(in text: String) -> String? {
        let lower = text.lowercased()
        return bannedPhrases.first { lower.contains($0) }
    }
}

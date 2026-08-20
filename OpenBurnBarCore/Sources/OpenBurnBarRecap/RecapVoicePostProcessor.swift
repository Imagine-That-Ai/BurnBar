import Foundation
import OpenBurnBarInsights
import OpenBurnBarKernel

/// Validates model-authored prose before any of it reaches a card.
///
/// The rule that matters is `numeric containment`: every digit-bearing token in
/// the model's copy must trace back to a number that candidate already carried.
/// A fluent model asked to improve "Grok handled 41% of your sessions" will
/// cheerfully produce "Grok handled nearly half your sessions, up from a fifth"
/// — plausible, well-written, and not something anyone computed. That copy is
/// rejected here and the deterministic sentence ships instead.
///
/// Failure is always per-field and always falls back rather than blanking: a
/// rejected headline costs the card its polish, never its content.
public struct RecapVoicePostProcessor: Sendable {

    // MARK: - Reporting

    public struct Report: Sendable, Hashable {
        public var cardsVoiced: Int = 0
        public var cardsFellBack: Int = 0
        public var cardsDropped: Int = 0
        public var unknownIDs: Int = 0
        public var bannedPhraseHits: [String] = []
        public var numericViolations: [String] = []
        public var unresolvedTokenHits: Int = 0
        public var truncations: Int = 0
        public var titleRejected: Bool = false
        public var closingRejected: Bool = false

        public init() {}
    }

    public enum RejectionReason: String, Sendable {
        case nothingSurvived
    }

    public enum Result: Sendable {
        case accepted(RecapVoiceOutcome, Report)
        case rejected(RejectionReason, Report)
    }

    // MARK: - Config

    public var bannedPhrases: [String]
    /// Fraction over the schema limit that is trimmed rather than rejected.
    public var overageTolerance: Double
    /// A model may not silently empty the recap.
    public var minimumCards: Int
    public var maxPromotions: Int

    public init(
        bannedPhrases: [String] = RecapVoiceSchema.bannedPhrases,
        overageTolerance: Double = 0.15,
        minimumCards: Int = 4,
        maxPromotions: Int = 2
    ) {
        self.bannedPhrases = bannedPhrases.map { $0.lowercased() }
        self.overageTolerance = overageTolerance
        self.minimumCards = minimumCards
        self.maxPromotions = maxPromotions
    }

    // MARK: - Entry point

    public func process(
        response: RecapVoiceResponse,
        deterministicCards: [RecapCard],
        fallbackTitle: String,
        fallbackClosing: String,
        mapping: RecapPromptMapping
    ) -> Result {
        var report = Report()
        let redaction = mapping.redaction

        let cardsByID = Dictionary(
            deterministicCards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let globalVocabulary = deterministicCards.reduce(into: Set<String>()) { partial, card in
            partial.formUnion(Self.vocabulary(for: card.candidate))
        }

        // MARK: Cards

        var emitted: [RecapCard] = []
        var handled = Set<String>()
        var promotions = 0

        for entry in response.cards {
            let resolvedID = mapping.realID(for: entry.id)
            guard let card = cardsByID[resolvedID] else {
                report.unknownIDs += 1
                continue
            }
            guard handled.insert(resolvedID).inserted else { continue }

            if entry.drop == true {
                report.cardsDropped += 1
                continue
            }

            let vocabulary = Self.vocabulary(for: card.candidate)
            let headline = validate(
                entry.headline,
                limit: RecapVoiceSchema.headlineMaxLength,
                vocabulary: vocabulary,
                redaction: redaction,
                report: &report
            )
            let body = validate(
                entry.body,
                limit: RecapVoiceSchema.bodyMaxLength,
                vocabulary: vocabulary,
                redaction: redaction,
                report: &report
            )

            var resolved: RecapCard
            if let headline, let body {
                resolved = card.withVoice(headline: headline, body: body)
                report.cardsVoiced += 1
            } else {
                // Partial acceptance would mix two voices inside one card, which
                // reads worse than either alone.
                resolved = card
                report.cardsFellBack += 1
            }

            if entry.promote == true,
               promotions < maxPromotions,
               resolved.size != .hero,
               resolved.size != .fullBleed {
                resolved = resolved.resized(to: .hero)
                promotions += 1
            }
            emitted.append(resolved)
        }

        // Anything the model neither ordered nor dropped keeps its place at the
        // back rather than vanishing — omission is not a decision.
        for card in deterministicCards where !handled.contains(card.id) {
            emitted.append(card)
        }

        guard emitted.count >= min(minimumCards, deterministicCards.count) else {
            return .rejected(.nothingSurvived, report)
        }

        // MARK: Title and closing

        let title = validate(
            response.monthTitle,
            limit: RecapVoiceSchema.titleMaxLength,
            vocabulary: globalVocabulary,
            redaction: redaction,
            report: &report
        )
        if title == nil { report.titleRejected = true }

        let subtitle = response.monthSubtitle.flatMap { raw in
            validate(
                raw,
                limit: RecapVoiceSchema.bodyMaxLength,
                vocabulary: globalVocabulary,
                redaction: redaction,
                report: &report
            )
        }

        let closing = validate(
            response.monthInOneSentence,
            limit: RecapVoiceSchema.closingMaxLength,
            vocabulary: globalVocabulary,
            redaction: redaction,
            report: &report
        )
        if closing == nil { report.closingRejected = true }

        // If the model contributed nothing usable anywhere, say so and let the
        // caller keep the deterministic recap wholesale.
        guard report.cardsVoiced > 0 || title != nil || closing != nil else {
            return .rejected(.nothingSurvived, report)
        }

        let outcome = RecapVoiceOutcome(
            title: title ?? fallbackTitle,
            subtitle: subtitle,
            closingSentence: closing ?? fallbackClosing,
            cards: emitted
        )
        return .accepted(outcome, report)
    }

    // MARK: - Field validation

    /// Returns cleaned copy, or nil when the field must fall back.
    private func validate(
        _ raw: String,
        limit: Int,
        vocabulary: Set<String>,
        redaction: RecapRedaction,
        report: inout Report
    ) -> String? {
        let restored = redaction.restore(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !restored.isEmpty else { return nil }

        // A placeholder the model invented cannot be resolved to a real name,
        // and shipping "{project7}" to the user is worse than plain copy.
        if redaction.hasUnresolvedTokens(restored) {
            report.unresolvedTokenHits += 1
            return nil
        }

        if let hit = bannedPhraseHit(in: restored) {
            report.bannedPhraseHits.append(hit)
            return nil
        }

        if let offender = Self.numericViolation(in: restored, vocabulary: vocabulary) {
            report.numericViolations.append(offender)
            return nil
        }

        guard restored.count > limit else { return restored }
        let ceiling = Int(Double(limit) * (1 + overageTolerance))
        guard restored.count <= ceiling else { return nil }
        report.truncations += 1
        return Self.trimToWordBoundary(restored, limit: limit)
    }

    private func bannedPhraseHit(in text: String) -> String? {
        let lowered = text.lowercased()
        return bannedPhrases.first { lowered.contains($0) }
    }

    // MARK: - Numeric containment

    /// Normalized digit-bearing tokens found in `text`.
    static func numericTokens(in text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for character in text {
            if character.isNumber || ((character == "." || character == ",") && !current.isEmpty) {
                current.append(character)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens.compactMap(normalize)
    }

    /// "1,842" -> "1842"; "41.20" -> "41.2"; "41." -> "41".
    static func normalize(_ token: String) -> String? {
        var cleaned = token.replacingOccurrences(of: ",", with: "")
        while cleaned.hasSuffix(".") { cleaned.removeLast() }
        guard !cleaned.isEmpty, cleaned.contains(where: \.isNumber) else { return nil }
        if cleaned.contains(".") {
            while cleaned.hasSuffix("0") { cleaned.removeLast() }
            while cleaned.hasSuffix(".") { cleaned.removeLast() }
        }
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Every number a candidate is allowed to be written about.
    ///
    /// Seeded from the metrics *and* from the rule's own deterministic copy,
    /// which is trusted text derived from those same metrics — so a rule that
    /// legitimately mentions a session count does not get its rewrite rejected.
    static func vocabulary(for candidate: RecapCandidate) -> Set<String> {
        var vocabulary = Set<String>()

        func absorb(_ text: String) {
            for token in numericTokens(in: text) {
                vocabulary.insert(token)
                // A model writing "$41" for a metric of "$41.20" is being
                // readable, not inventive.
                if let dot = token.firstIndex(of: "."), let whole = normalize(String(token[..<dot])) {
                    vocabulary.insert(whole)
                }
            }
        }

        for metric in candidate.metrics {
            absorb(metric.formatted)
            absorb(RecapMetric.format(metric.value, metric.unit))
        }
        if let comparison = candidate.comparison {
            absorb(RecapMetric.format(comparison.currentValue, comparison.unit))
            absorb(RecapMetric.format(comparison.referenceValue, comparison.unit))
            absorb(comparison.referenceLabel)
            if let delta = comparison.deltaFraction {
                absorb(RecapMetric.format(abs(delta), .percent))
            }
        }
        absorb(candidate.headline)
        absorb(candidate.body)
        return vocabulary
    }

    /// The first number in `text` that is not in `vocabulary`, or nil.
    static func numericViolation(in text: String, vocabulary: Set<String>) -> String? {
        numericTokens(in: text).first { !vocabulary.contains($0) }
    }

    // MARK: - Trimming

    static func trimToWordBoundary(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let clipped = String(text.prefix(limit))
        guard let lastSpace = clipped.lastIndex(of: " ") else { return clipped }
        var trimmed = String(clipped[..<lastSpace])
        while let last = trimmed.last, last == "," || last == ";" || last == " " {
            trimmed.removeLast()
        }
        return trimmed
    }
}

// MARK: - Outcome

/// Validated editorial output, ready to be folded into a `MonthlyRecap`.
public struct RecapVoiceOutcome: Sendable {
    public let title: String
    public let subtitle: String?
    public let closingSentence: String
    public let cards: [RecapCard]

    public init(title: String, subtitle: String?, closingSentence: String, cards: [RecapCard]) {
        self.title = title
        self.subtitle = subtitle
        self.closingSentence = closingSentence
        self.cards = cards
    }
}

import Foundation

/// Turns a pile of true statements into a deck worth swiping through.
///
/// Three passes, in order:
///   1. **Score** — rank by interestingness and drop the floor.
///   2. **Diversity** — stop one subject or one kind from taking the whole deck,
///      even when it legitimately holds the top scores.
///   3. **Narrative** — lay the survivors into an editorial rhythm rather than a
///      descending list of scores, which is what makes it read like a magazine
///      instead of a leaderboard.
public enum RecapRanker {

    // MARK: - Tuning

    public struct Limits: Sendable {
        /// Candidates below this never ship, however empty the deck would be.
        /// An honest six-card recap beats a padded sixteen.
        public var minimumInterestingness: Double
        public var maximumCards: Int
        /// How many cards may share one `RecapInsightKind`.
        public var maxPerKind: Int
        /// How many cards may share one `family` (subject).
        public var maxPerFamily: Int
        /// Oversized moments, excluding the opener.
        public var maxAdditionalHeroes: Int

        public init(
            minimumInterestingness: Double = 0.06,
            maximumCards: Int = 16,
            maxPerKind: Int = 3,
            maxPerFamily: Int = 1,
            maxAdditionalHeroes: Int = 2
        ) {
            self.minimumInterestingness = minimumInterestingness
            self.maximumCards = maximumCards
            self.maxPerKind = maxPerKind
            self.maxPerFamily = maxPerFamily
            self.maxAdditionalHeroes = maxAdditionalHeroes
        }

        public static let standard = Limits()
    }

    // MARK: - Entry point

    public static func rank(
        candidates: [RecapCandidate],
        limits: Limits = .standard
    ) -> [RecapCard] {
        let scored = candidates
            .filter { $0.interestingness >= limits.minimumInterestingness }
            // Total order: score descending, id ascending. Never a partial sort,
            // or two equally-interesting cards could swap between runs.
            .sorted { lhs, rhs in
                lhs.interestingness == rhs.interestingness
                    ? lhs.id < rhs.id
                    : lhs.interestingness > rhs.interestingness
            }

        guard !scored.isEmpty else { return [] }

        let diverse = applyDiversity(scored, limits: limits)
        let ordered = applyNarrative(diverse)
        return assignSizes(ordered, limits: limits)
    }

    // MARK: - Pass 2: diversity

    /// Caps repetition by kind and by subject, then deliberately readmits one
    /// whimsical and one comparison card if the caps excluded them.
    ///
    /// Without the readmission the deck skews to whatever scores highest, which
    /// in a heavy month is a wall of records — technically the most interesting
    /// cards, collectively a worse read.
    static func applyDiversity(
        _ candidates: [RecapCandidate],
        limits: Limits
    ) -> [RecapCandidate] {
        var kindCounts: [RecapInsightKind: Int] = [:]
        var familyCounts: [String: Int] = [:]
        var kept: [RecapCandidate] = []
        var rejected: [RecapCandidate] = []

        for candidate in candidates {
            guard kept.count < limits.maximumCards else {
                rejected.append(candidate)
                continue
            }
            let kindCount = kindCounts[candidate.kind, default: 0]
            let familyCount = familyCounts[candidate.family, default: 0]
            if kindCount >= limits.maxPerKind || familyCount >= limits.maxPerFamily {
                rejected.append(candidate)
                continue
            }
            kindCounts[candidate.kind] = kindCount + 1
            familyCounts[candidate.family] = familyCount + 1
            kept.append(candidate)
        }

        // Readmit texture the caps may have squeezed out.
        for wanted in [RecapInsightKind.funFact, .comparison] {
            guard kept.count < limits.maximumCards else { break }
            guard !kept.contains(where: { $0.kind == wanted }) else { continue }
            guard let rescue = rejected.first(where: { candidate in
                candidate.kind == wanted
                    && familyCounts[candidate.family, default: 0] < limits.maxPerFamily
            }) else { continue }
            familyCounts[rescue.family, default: 0] += 1
            kept.append(rescue)
            rejected.removeAll { $0.id == rescue.id }
        }

        return kept
    }

    // MARK: - Pass 3: narrative

    /// The editorial rhythm from the brief, expressed as preferences rather
    /// than a fixed template: each slot takes the best remaining card that fits
    /// it, and a slot with no match is simply skipped. Whatever is left over is
    /// appended by score, so the shape follows the month instead of the month
    /// being forced into the shape.
    private static let slots: [@Sendable (RecapCandidate) -> Bool] = [
        // 1. Open on the single most arresting thing.
        { $0.kind == .record || $0.kind == .milestone },
        // 2. Who they are as an operator.
        { $0.kind == .personality },
        // 3. The fleet: favourite model, then the pairing.
        { $0.ruleID == "favourite-model" },
        { $0.ruleID == "favourite-pairing" },
        // 4. What the work was about.
        { $0.family.hasPrefix("project") },
        // 5. When it happened.
        { $0.family.hasPrefix("rhythm") },
        // 6. What changed.
        { $0.kind == .trend || $0.kind == .comparison },
        // 7. Something unexpected.
        { $0.kind == .funFact },
        // 8. What it cost.
        { $0.family.hasPrefix("economy") }
    ]

    static func applyNarrative(_ candidates: [RecapCandidate]) -> [RecapCandidate] {
        var remaining = candidates
        var ordered: [RecapCandidate] = []

        for slot in slots {
            guard let index = remaining.firstIndex(where: slot) else { continue }
            ordered.append(remaining.remove(at: index))
        }

        // Everything else keeps score order behind the arranged opening.
        ordered.append(contentsOf: remaining)
        return ordered
    }

    // MARK: - Sizes

    /// Resolves each card's size, promoting the opener and a small number of
    /// standout moments while keeping the rest at what the rule asked for.
    static func assignSizes(
        _ candidates: [RecapCandidate],
        limits: Limits
    ) -> [RecapCard] {
        var heroesUsed = 0
        var cards: [RecapCard] = []

        for (index, candidate) in candidates.enumerated() {
            let size: RecapCardSize
            if index == 0 {
                // The opener is always a full-width moment.
                size = candidate.visual == .none ? .fullBleed : .hero
            } else if candidate.suggestedSize == .hero || candidate.suggestedSize == .fullBleed {
                if heroesUsed < limits.maxAdditionalHeroes {
                    heroesUsed += 1
                    size = candidate.suggestedSize
                } else {
                    // Demote rather than drop — the insight still earns a card.
                    size = .wide
                }
            } else {
                size = candidate.suggestedSize
            }
            cards.append(RecapCard(candidate: candidate, size: size))
        }
        return cards
    }
}

import Foundation
import OpenBurnBarInsights
import OpenBurnBarKernel

/// Runs every rule against a month and collects what fired.
///
/// Rules are independent and order-free: each one either has something true and
/// interesting to say or returns nil. Nothing here decides what makes the deck —
/// that is `RecapRanker`'s job — so a rule can be added without touching
/// anything else.
public enum RecapCandidateGenerator {

    /// Every rule in the system, grouped by the question it answers.
    public static var allRules: [@Sendable (RecapContext) -> RecapCandidate?] {
        RecapFleetRules.all
            + RecapRhythmRules.all
            + RecapCraftRules.all
            + RecapEconomyRules.all
    }

    /// Candidates for one month, in a stable order.
    ///
    /// Sorted by id rather than by score so the generator's output is identical
    /// across runs regardless of rule ordering — ranking happens downstream and
    /// wants a deterministic input.
    public static func candidates(for context: RecapContext) -> [RecapCandidate] {
        var seen = Set<String>()
        var result: [RecapCandidate] = []
        for rule in allRules {
            guard let candidate = rule(context) else { continue }
            // Two rules producing the same id would make the LLM's per-id
            // addressing ambiguous; first one wins.
            guard seen.insert(candidate.id).inserted else { continue }
            result.append(candidate)
        }
        return result.sorted { $0.id < $1.id }
    }
}

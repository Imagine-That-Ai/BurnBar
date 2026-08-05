import Foundation
import OpenBurnBarEngine

/// What the inbox has learned about how useful each kind of item actually is.
///
/// The inbox ships with hand-picked thresholds, and hand-picked thresholds are
/// wrong for somebody. Rather than asking the user to tune sliders they have no
/// basis to set, the inbox watches two signals it already collects and adjusts
/// itself:
///
///   • **Explicit feedback** — 👍/👎 on an item.
///   • **Time to resolution** — an item that resolves within minutes of being
///     raised was, by definition, not worth interrupting for. This is the more
///     honest signal of the two, because it costs the user nothing to produce.
///
/// The adjustment is deliberately conservative and bounded: it can demote a kind
/// by at most one priority band, and it can never silence one entirely. A user
/// who dislikes a detector should be able to turn it off explicitly, not
/// discover it has quietly stopped working.
struct BurnBarAIInboxCalibration: Codable, Sendable, Hashable {
    /// Per-kind rolling counters. Keyed by `BurnBarInboxItemKind.rawValue` so a
    /// kind added later starts neutral rather than failing to decode.
    var kinds: [String: KindStats]
    var updatedAt: Date

    struct KindStats: Codable, Sendable, Hashable {
        var useful: Int = 0
        var notUseful: Int = 0
        /// Items that resolved suspiciously fast after being raised.
        var quickResolutions: Int = 0
        /// Items that stayed open long enough to have mattered.
        var durableItems: Int = 0

        /// Total signal behind this kind's score. Below `minimumSignal` the
        /// adjustment is not applied at all — three thumbs-down on a brand-new
        /// detector is an opinion, not evidence.
        var sampleCount: Int { useful + notUseful + quickResolutions + durableItems }
    }

    static let empty = BurnBarAIInboxCalibration(kinds: [:], updatedAt: Date(timeIntervalSince1970: 0))

    /// Minimum observations before a kind's score influences anything.
    static let minimumSignal = 6
    /// A resolution faster than this suggests the condition was transient — the
    /// user fixed it incidentally, or it fixed itself, so raising it was noise.
    static let quickResolutionWindow: TimeInterval = 15 * 60
    /// Score below which a kind is demoted one band.
    static let demotionThreshold = -0.35
    /// Score above which a kind is allowed back to its natural priority even if
    /// it was previously demoted.
    static let recoveryThreshold = 0.0

    /// −1 (consistently unhelpful) … +1 (consistently useful).
    ///
    /// Explicit feedback is weighted double: it is scarcer and less ambiguous
    /// than an inferred signal.
    func score(for kind: BurnBarInboxItemKind) -> Double {
        guard let stats = kinds[kind.rawValue], stats.sampleCount >= Self.minimumSignal else { return 0 }
        let positive = Double(stats.useful * 2 + stats.durableItems)
        let negative = Double(stats.notUseful * 2 + stats.quickResolutions)
        let total = positive + negative
        guard total > 0 else { return 0 }
        return (positive - negative) / total
    }

    /// Applies the learned adjustment to a proposed priority.
    ///
    /// Only ever demotes, and only by one band. Promotion is deliberately not
    /// implemented: a detector that thinks something is P3 should not be able to
    /// escalate itself into an interruption because the user has been polite.
    func adjustedPriority(
        for kind: BurnBarInboxItemKind,
        proposed: BurnBarInboxPriority
    ) -> BurnBarInboxPriority {
        guard score(for: kind) <= Self.demotionThreshold else { return proposed }
        return BurnBarInboxPriority(clamping: proposed.rawValue + 1)
    }

    /// Human-readable explanation, surfaced in the item footer so a demotion is
    /// visible rather than mysterious.
    func explanation(for kind: BurnBarInboxItemKind) -> String? {
        let value = score(for: kind)
        guard value <= Self.demotionThreshold else { return nil }
        guard let stats = kinds[kind.rawValue] else { return nil }
        if stats.notUseful > stats.quickResolutions {
            return "Ranked lower because you have marked items like this as not useful."
        }
        return "Ranked lower because items like this usually resolve on their own within minutes."
    }

    // MARK: - Learning

    mutating func recordFeedback(kind: BurnBarInboxItemKind, useful: Bool, now: Date) {
        var stats = kinds[kind.rawValue] ?? KindStats()
        if useful { stats.useful += 1 } else { stats.notUseful += 1 }
        kinds[kind.rawValue] = Self.decayed(stats)
        updatedAt = now
    }

    /// Records how long an item survived before resolving.
    ///
    /// This is the signal that requires nothing of the user, which is what makes
    /// it the backbone of the loop.
    mutating func recordResolution(
        kind: BurnBarInboxItemKind,
        firstSeenAt: Date,
        resolvedAt: Date,
        now: Date
    ) {
        var stats = kinds[kind.rawValue] ?? KindStats()
        if resolvedAt.timeIntervalSince(firstSeenAt) <= Self.quickResolutionWindow {
            stats.quickResolutions += 1
        } else {
            stats.durableItems += 1
        }
        kinds[kind.rawValue] = Self.decayed(stats)
        updatedAt = now
    }

    /// Halves the counters once they get large.
    ///
    /// Without this the earliest weeks would dominate forever, and a detector the
    /// user retuned (or a workflow they actually fixed) could never climb back.
    /// Halving keeps the ratio while letting recent behavior outweigh old.
    static func decayed(_ stats: KindStats) -> KindStats {
        guard stats.sampleCount > 40 else { return stats }
        return KindStats(
            useful: stats.useful / 2,
            notUseful: stats.notUseful / 2,
            quickResolutions: stats.quickResolutions / 2,
            durableItems: stats.durableItems / 2
        )
    }
}

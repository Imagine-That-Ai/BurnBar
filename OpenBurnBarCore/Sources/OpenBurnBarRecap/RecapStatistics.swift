import Foundation

/// Significance tests behind the recap's claims.
///
/// Every candidate's `significance` comes from one of these rather than from a
/// hand-picked constant. That is the difference between "Tuesday is build day"
/// meaning something and it meaning "Tuesday happened to win a coin flip":
/// with 9 sessions spread over 7 weekdays, *some* day always wins.
public enum RecapStatistics {

    // MARK: - Mapping to 0…1

    /// Maps a two-tailed z-score onto 0…1.
    ///
    /// |z| ≤ 1 scores 0 (indistinguishable from noise), |z| ≥ 3 scores 1.
    /// Deliberately harsh at the bottom: a recap that reports every wobble as a
    /// trend teaches the reader to ignore it.
    public static func significance(fromZ z: Double) -> Double {
        guard z.isFinite else { return 0 }
        return clamp((abs(z) - 1.0) / 2.0)
    }

    /// Maps an effect size already bounded to 0…1 (Cramér's V, a share) onto a
    /// significance, with `full` as the point of saturation.
    public static func significance(fromEffect effect: Double, saturatingAt full: Double) -> Double {
        guard effect.isFinite, full > 0 else { return 0 }
        return clamp(effect / full)
    }

    // MARK: - Tests

    /// Two-proportion z-test — the right test for "this model went from 18% of
    /// your sessions to 41%".
    ///
    /// Returns nil when either sample is too small for the normal
    /// approximation to mean anything.
    public static func twoProportionZ(
        successes1: Int, trials1: Int,
        successes2: Int, trials2: Int
    ) -> Double? {
        guard trials1 >= 10, trials2 >= 10 else { return nil }
        let n1 = Double(trials1)
        let n2 = Double(trials2)
        let p1 = Double(successes1) / n1
        let p2 = Double(successes2) / n2
        let pooled = Double(successes1 + successes2) / (n1 + n2)
        guard pooled > 0, pooled < 1 else { return nil }
        let standardError = (pooled * (1 - pooled) * (1 / n1 + 1 / n2)).squareRoot()
        guard standardError > 0 else { return nil }
        return (p1 - p2) / standardError
    }

    /// Cramér's V for a one-way count distribution against a uniform
    /// expectation. Bounded 0…1 by construction, so it needs no calibration.
    ///
    /// Used for "a third of your sessions were on Tuesdays" and "27% of your
    /// coding happened after midnight" — both claims about concentration.
    public static func uniformityEffect(counts: [Int]) -> Double? {
        let total = counts.reduce(0, +)
        let categories = counts.count
        guard categories > 1, total >= 20 else { return nil }
        let expected = Double(total) / Double(categories)
        guard expected > 0 else { return nil }
        let chiSquare = counts.reduce(0.0) { partial, observed in
            let diff = Double(observed) - expected
            return partial + (diff * diff) / expected
        }
        let v = (chiSquare / (Double(total) * Double(categories - 1))).squareRoot()
        return clamp(v)
    }

    /// Same idea for a continuous weight (cost) rather than counts. Uses an
    /// effective sample size so a handful of expensive rows cannot masquerade
    /// as a strong pattern.
    public static func uniformityEffect(weights: [Double], effectiveSampleSize: Int) -> Double? {
        let total = weights.reduce(0, +)
        let categories = weights.count
        guard categories > 1, total > 0, effectiveSampleSize >= 20 else { return nil }
        let expected = total / Double(categories)
        let chiSquare = weights.reduce(0.0) { partial, observed in
            let diff = observed - expected
            return partial + (diff * diff) / expected
        }
        // Rescale from "units of cost" to "units of observation".
        let scaled = chiSquare * (Double(effectiveSampleSize) / total)
        let v = (scaled / (Double(effectiveSampleSize) * Double(categories - 1))).squareRoot()
        return clamp(v)
    }

    /// How convincingly a new record beats the old one.
    ///
    /// A record broken by 1% is technically a record and emotionally nothing;
    /// this saturates at a 25% margin.
    public static func recordMargin(current: Double, previousBest: Double) -> Double? {
        guard current > previousBest, previousBest > 0 else { return nil }
        return clamp((current - previousBest) / previousBest / 0.25)
    }

    // MARK: - Helpers

    public static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    public static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    /// Confidence contribution from sample size alone: a claim resting on three
    /// sessions is not as trustworthy as the same claim resting on three
    /// hundred. Saturates at `full`.
    public static func sampleConfidence(_ n: Int, full: Int = 50) -> Double {
        guard n > 0, full > 0 else { return 0 }
        return clamp(Double(n) / Double(full))
    }
}

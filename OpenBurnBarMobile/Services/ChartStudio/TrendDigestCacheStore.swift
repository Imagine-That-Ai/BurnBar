import SwiftUI
import OpenBurnBarCore

// MARK: - Trend digest memo

/// Reference-typed cache for `TrendDataDigest.build` + gallery/insights.
///
/// `@StateObject`-backed so mutations do not trigger SwiftUI re-renders.
/// Recomputes only when the input hash (or digest identity) changes.
@MainActor
final class TrendDigestCacheStore: ObservableObject {
    private var cachedDigest: TrendDataDigest?
    private var cachedInsights: [TrendInsight] = []
    private var cachedHash: Int = 0

    func digest(
        dailyPoints: [RollupDailyPoint],
        displayMode: UsageDisplayMode,
        windowTotals: [RollupWindowKey: RollupTotals],
        providerSummaries: [RollupProviderSummary],
        modelSummaries: [RollupModelSummary],
        deviceSummaries: [RollupDeviceSummary],
        recentUsages: [TokenUsage]
    ) -> TrendDataDigest {
        let hash = Self.inputHash(
            dailyPoints: dailyPoints,
            displayMode: displayMode,
            windowTotals: windowTotals,
            providerSummaries: providerSummaries,
            modelSummaries: modelSummaries,
            deviceSummaries: deviceSummaries,
            recentUsages: recentUsages
        )
        if hash != cachedHash {
            let built = TrendDataDigest.build(
                windowTotals: windowTotals,
                providerSummaries: providerSummaries,
                modelSummaries: modelSummaries,
                deviceSummaries: deviceSummaries,
                dailyPoints: dailyPoints,
                recentUsages: recentUsages,
                displayMode: displayMode
            )
            cachedDigest = built
            cachedInsights = TrendInsightEngine.insights(from: built)
            cachedHash = hash
        }
        return cachedDigest!
    }

    func insights(
        dailyPoints: [RollupDailyPoint],
        displayMode: UsageDisplayMode,
        windowTotals: [RollupWindowKey: RollupTotals],
        providerSummaries: [RollupProviderSummary],
        modelSummaries: [RollupModelSummary],
        deviceSummaries: [RollupDeviceSummary],
        recentUsages: [TokenUsage]
    ) -> [TrendInsight] {
        _ = digest(
            dailyPoints: dailyPoints,
            displayMode: displayMode,
            windowTotals: windowTotals,
            providerSummaries: providerSummaries,
            modelSummaries: modelSummaries,
            deviceSummaries: deviceSummaries,
            recentUsages: recentUsages
        )
        return cachedInsights
    }

    private static func inputHash(
        dailyPoints: [RollupDailyPoint],
        displayMode: UsageDisplayMode,
        windowTotals: [RollupWindowKey: RollupTotals],
        providerSummaries: [RollupProviderSummary],
        modelSummaries: [RollupModelSummary],
        deviceSummaries: [RollupDeviceSummary],
        recentUsages: [TokenUsage]
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(dailyPoints)
        hasher.combine(displayMode)
        hasher.combine(windowTotals)
        hasher.combine(providerSummaries)
        hasher.combine(modelSummaries)
        hasher.combine(deviceSummaries)
        hasher.combine(recentUsages)
        return hasher.finalize()
    }
}

/// Chart Studio gallery / prompt facts derived from a digest.
///
/// Hermes streaming retriggers the studio body; `StandardGallery` and the
/// prompt engine are pure over the digest and must not rerun per token.
@MainActor
final class ChartStudioDerivedCache: ObservableObject {
    private var digest: TrendDataDigest?
    private(set) var quickFacts: [QuickFact] = []
    private(set) var galleryItems: [StandardGalleryItem] = []
    private(set) var suggestedPrompts: [String] = []

    func facts(for digest: TrendDataDigest) -> [QuickFact] {
        bind(digest)
        return quickFacts
    }

    func items(for digest: TrendDataDigest) -> [StandardGalleryItem] {
        bind(digest)
        return galleryItems
    }

    func prompts(for digest: TrendDataDigest) -> [String] {
        bind(digest)
        return suggestedPrompts
    }

    func promptEngine(for digest: TrendDataDigest) -> ChartStudioPromptEngine {
        bind(digest)
        return ChartStudioPromptEngine(digest: digest)
    }

    private func bind(_ digest: TrendDataDigest) {
        guard self.digest != digest else { return }
        self.digest = digest
        quickFacts = StandardGallery.quickFacts(from: digest)
        galleryItems = StandardGallery.items(from: digest)
        suggestedPrompts = ChartStudioPromptEngine(digest: digest).suggestedPrompts()
    }
}

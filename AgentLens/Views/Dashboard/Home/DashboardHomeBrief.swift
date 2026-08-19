import Foundation
import OpenBurnBarInsights

// MARK: - Today's brief
//
// The read-only summary shown under the celebration when the inbox is empty.
//
// Built with `RuleBasedInsightAnalysisEngine`, which is a pure, deterministic,
// offline `struct` — no network, no API key, no audit log, no privacy question.
// That matters: the obvious approach is to reuse `InsightsMacEnvironment`, but
// its `init` builds an on-disk canvas store, an audit log, an analysis cache
// and a model catalog, registers network gateways, and fires
// `loadInitialCanvases()`. None of that belongs behind an empty inbox.
//
// An empty inbox is a *win*, and this is what rewards it — so it must cost
// nothing and must never be the reason the surface is slow.

enum DashboardHomeBrief {

    /// The tag stamped on a locally-computed brief, so the UI can label it
    /// honestly as rule-based rather than implying a model ran.
    static let localTag = InsightModelTag(
        providerKey: InsightProviderFamily.localRules.rawValue,
        modelID: "local-rules",
        displayName: "Local Rules",
        // Nothing leaves the device: `RuleBasedInsightAnalysisEngine` is pure
        // arithmetic over local rows, so the tag must say so.
        egressTier: .localOnly
    )

    /// Builds today's brief from local usage only.
    ///
    /// `maxGeneratedWidgets: 3` on purpose: `InboxEmptyState`'s own doc comment
    /// notes this is the screen a user sees most, and a calm celebration should
    /// not be six screens of scroll.
    @MainActor
    static func build(dataStore: DataStore, window: InsightTimeWindow = .last7d) async -> InsightAnalysisResult? {
        let source = MacInsightDataSource(dataStore: dataStore)
        let filter = InsightFilter(window: window)

        do {
            let snapshot = try await source.snapshot(window: filter.window.interval())
            let context = try InsightAggregator(digestBuilder: InsightDigestBuilder())
                .buildContext(
                    snapshot: snapshot,
                    filter: filter,
                    includedDataSources: ["datastore_usage", "local_session_logs"]
                )
            let request = InsightAnalysisRequest(
                prompt: "Today's brief.",
                context: context,
                currentCanvas: nil,
                selectedModel: localTag,
                instruction: .defaultBrief,
                allowDeepTranscriptAnalysis: false,
                maxGeneratedWidgets: 3
            )
            return try await RuleBasedInsightAnalysisEngine(platform: .macOS).analyze(request)
        } catch {
            // A brief is a reward, not a requirement. If the digest cannot be
            // built (no usage yet, a window with no rows), the celebration
            // stands on its own rather than surfacing an error on the calmest
            // screen in the app.
            return nil
        }
    }
}

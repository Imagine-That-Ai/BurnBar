import AppIntents
import Foundation
import OpenBurnBarCore

// MARK: - BurnBar Status Intent

/// Siri Shortcut / App Intent that returns the user's current burn status.
/// Speak: "What's my burn today?" → "You've spent $3.42 today across 3 providers."
@available(iOS 16.0, *)
struct BurnBarStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Burn Status"
    static let description = IntentDescription("Ask OpenBurnBar for your current spend and token usage.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let store = DashboardStore()
        // Pure read — never `load()`: intents have no `stopListening()`, so the
        // rollup snapshot listener it registers would leak for the process
        // lifetime, and a voice query must not publish widget/Live Activity
        // side effects.
        await store.refresh(publishSideEffects: false)

        guard let value = Self.statusPhrase(for: store) else {
            return .result(value: "No burn data available yet. Start using your AI agents on your Mac.")
        }

        return .result(value: value)
    }

    /// Derives the spoken phrase from the store's published fields, or `nil`
    /// when no `.today` rollup has been fetched yet.
    @MainActor
    static func statusPhrase(for store: DashboardStore) -> String? {
        guard let today = store.windowTotals[.today] else { return nil }

        let cost = today.costUsd.formatAsCost()
        let tokens = today.tokens.formatAsTokenVolume()
        let providerCount = store.topProviders.count

        let providerPhrase = providerCount == 1 ? "1 provider" : "\(providerCount) providers"
        return "You've spent \(cost) today using \(tokens) across \(providerPhrase)."
    }
}

import AppIntents
import Foundation
import OpenBurnBarCore

// MARK: - BurnBar Status Intent

/// Siri Shortcut / App Intent that returns the user's current burn status.
/// Speak: "What's my burn today?" → "You've spent $3.42 today across 3 providers."
@available(iOS 16.0, *)
struct BurnBarStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Burn Status"
    static var description = IntentDescription("Ask OpenBurnBar for your current spend and token usage.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let store = DashboardStore()
        await store.load()

        guard let today = store.windowTotals[.today] else {
            return .result(value: "No burn data available yet. Start using your AI agents on your Mac.")
        }

        let cost = today.costUsd.formatAsCost()
        let tokens = today.tokens.formatAsTokenVolume()
        let providerCount = store.topProviders.count

        let providerPhrase = providerCount == 1 ? "1 provider" : "\(providerCount) providers"
        let value = "You've spent \(cost) today using \(tokens) across \(providerPhrase)."

        return .result(value: value)
    }
}

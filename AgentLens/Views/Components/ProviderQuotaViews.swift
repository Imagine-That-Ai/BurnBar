import Foundation
import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

func providerQuotaManagementURL(
    for provider: AgentProvider,
    snapshot: ProviderQuotaSnapshot?
) -> URL? {
    if let link = snapshot?.managementLink {
        return link
    }

    let fallback: String? = switch provider {
    case .codex:
        "https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan"
    case .claudeCode:
        "https://code.claude.com/docs/en/statusline"
    case .minimax:
        "https://platform.minimax.io/docs/token-plan/faq"
    case .mimo:
        "https://platform.xiaomimimo.com/docs/en-US/tokenplan/subscription"
    case .zai:
        "https://bigmodel.cn/usercenter/glm-coding/usage"
    case .factory:
        "https://app.factory.ai"
    case .cursor:
        "https://cursor.com/pricing"
    case .xAI:
        "https://grok.com/plans"
    default:
        nil
    }

    guard let fallback else { return nil }
    return URL(string: fallback)
}

/// Thin wrapper kept for backwards compatibility with
/// `ProvidersSettingsView`. The full Nest Hub control surface now lives
/// in `NestHubSettingsCard` under Settings → Devices & Sync → Smart
/// Displays — this just embeds it so the Providers tab keeps offering
/// the same controls.
struct ProviderQuotaSmartHubsSection: View {
    @Bindable var settingsManager: SettingsManager

    var body: some View {
        NestHubSettingsCard(settingsManager: settingsManager)
    }
}

// MARK: - Cursor Inline Setup


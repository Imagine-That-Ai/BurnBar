import SwiftUI
import WidgetKit
import OpenBurnBarCore

struct DashboardLargeView: View {
    let snap: BurnBarWidgetSnapshot?

    private var totalTokens: Int {
        snap?.heroTotalTokens ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(WidgetDesignSystem.Colors.accentGradient)

                    Text("BurnBar")
                        .font(WidgetDesignSystem.Typography.micro)
                        .foregroundStyle(WidgetDesignSystem.Colors.textSecondary)
                        .textCase(.uppercase)
                        .tracking(0.6)
                }

                Spacer()

                if let window = snap?.windowKey {
                    Text(window)
                        .font(WidgetDesignSystem.Typography.micro)
                        .foregroundStyle(WidgetDesignSystem.Colors.textMuted)
                        .textCase(.uppercase)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .widgetHeaderBackground()

            // Hero metrics
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(snap?.heroTotalCost.formatAsCost() ?? "—")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .widgetAccentable()

                Text(snap?.heroTotalTokens.formatAsTokensRaw() ?? "0")
                    .font(WidgetDesignSystem.Typography.headline)
                    .foregroundStyle(.primary)

                Text("tokens")
                    .font(WidgetDesignSystem.Typography.caption)
                    .foregroundStyle(WidgetDesignSystem.Colors.textSecondary)

                Spacer()

                WidgetMetricBadge(
                    icon: "number",
                    value: "\(snap?.heroTotalRequests ?? 0)",
                    label: "requests",
                    color: WidgetDesignSystem.Colors.whimsy
                )
            }
            .padding(.horizontal, 16)

            // Sparkline
            if let points = snap?.dailyPoints, !points.isEmpty {
                TokenSparkline(data: points, color: WidgetDesignSystem.Colors.amber)
                    .frame(height: 52)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }

            // Model chips
            if let models = snap?.topModels.prefix(4), !models.isEmpty {
                HStack(spacing: 5) {
                    ForEach(Array(models), id: \.self) { model in
                        WidgetModelChip(model: model)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }

            Divider()
                .padding(.horizontal, 16)
                .opacity(0.25)

            // Provider ranking
            if let providers = snap?.topProviders.prefix(3), !providers.isEmpty {
                VStack(spacing: 6) {
                    ForEach(Array(providers.enumerated()), id: \.offset) { index, provider in
                        ProviderRow(
                            rank: index + 1,
                            name: provider,
                            tokens: snap?.topProviderTokens[safe: index] ?? 0,
                            totalTokens: totalTokens
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            Spacer(minLength: 4)

            // Ask-assistant chips — primary 2-button row + 3 quick-prompt chips.
            // Available iOS 17+ via `Button(intent:)`; matches widget target.
            VStack(spacing: 5) {
                HStack(spacing: 6) {
                    Button(intent: AskAssistantIntent(assistant: .hermes, prompt: nil)) {
                        AskChipLabel(
                            icon: "sparkle",
                            title: "Ask Hermes",
                            color: WidgetDesignSystem.Colors.amber,
                            prominent: true
                        )
                    }
                    .buttonStyle(.plain)
                    Button(intent: AskAssistantIntent(assistant: .pi, prompt: nil)) {
                        AskChipLabel(
                            icon: "cpu",
                            title: "Ask Pi",
                            color: WidgetDesignSystem.Colors.whimsy,
                            prominent: true
                        )
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 5) {
                    ForEach(AssistantQuickPromptCatalog.hermesShortlist.prefix(3), id: \.id) { prompt in
                        Button(intent: AskAssistantIntent(
                            assistant: AssistantRuntimeOption(rawValue: prompt.preferredAssistant.rawValue) ?? .hermes,
                            prompt: prompt.fullPrompt
                        )) {
                            AskChipLabel(
                                icon: nil,
                                title: prompt.chipLabel,
                                color: WidgetDesignSystem.Colors.amber,
                                prominent: false
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)

            // Footer
            HStack {
                Spacer()
                if let date = snap?.lastSync {
                    Text("Updated \(date, style: .time)")
                        .font(WidgetDesignSystem.Typography.micro)
                        .foregroundStyle(WidgetDesignSystem.Colors.textMuted)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WidgetDesignSystem.Colors.surfaceLight)
        .widgetAccentable()
    }
}

// MARK: - Provider Row

struct ProviderRow: View {
    let rank: Int
    let name: String
    let tokens: Int
    let totalTokens: Int

    var providerEnum: AgentProvider? {
        AgentProvider.fromPersistedToken(name)
    }

    var color: Color {
        if let providerEnum {
            // Deterministic provider colors (mirrors DesignSystem)
            switch providerEnum {
            case .factory:    return Color(hex: "8B5CF6")
            case .claudeCode: return Color(hex: "CC785C")
            case .copilot:    return Color(hex: "23EA3B")
            case .aider:      return Color(hex: "FF6B35")
            case .cursor:     return Color(hex: "AC8C57")
            case .openAI:     return Color(hex: "00A67E")
            case .codex:      return Color(hex: "00A67E")
            case .zai:        return Color(hex: "8B5CF6")
            case .minimax:    return Color(hex: "F59E0B")
            case .kimi:       return Color(hex: "6366F1")
            case .cline:      return Color(hex: "D4A373")
            case .kiloCode:   return Color(hex: "10B981")
            case .rooCode:    return Color(hex: "EC4899")
            case .forgeDev:   return Color(hex: "F97316")
            case .augment:    return Color(hex: "3B82F6")
            case .hermes:     return Color(hex: "A855F7")
            case .piAgent:    return Color(hex: "A855F7")
            case .geminiCLI:  return Color(hex: "4285F4")
            case .goose:      return Color(hex: "0D9488")
            case .openClaw:   return Color(hex: "FF6B6B")
            case .ollama:     return Color(hex: "6B7280")
            case .windsurf:   return Color(hex: "06B6D4")
            case .warp:       return Color(hex: "DDE4EA")
            }
        }
        return WidgetDesignSystem.Colors.amber
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text("\(rank)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(WidgetDesignSystem.Colors.textMuted)
                    .frame(width: 14, alignment: .center)

                if let providerEnum,
                   UIImage(named: providerEnum.bundledLogoName) != nil {
                    UnifiedProviderLogoView(provider: providerEnum, size: 14)
                }

                Text(name)
                    .font(WidgetDesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                Text(tokens.formatAsTokens())
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(WidgetDesignSystem.Colors.textSecondary)
                    .lineLimit(1)
            }

            WidgetProgressBar(
                value: Double(tokens),
                total: Double(max(totalTokens, 1)),
                color: color
            )
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Ask Chip Label
//
// Shared between `DashboardLargeView` and `DashboardExtraLargeView`. Two
// flavors:
//   • `prominent: true`  — used for the "Ask Hermes" / "Ask Pi" lead buttons.
//   • `prominent: false` — used for narrow quick-prompt chips ("Burn?",
//     "Forecast", "Cache") that need to fit 3 across a 4×4 widget row.

struct AskChipLabel: View {
    let icon: String?
    let title: String
    let color: Color
    let prominent: Bool

    var body: some View {
        HStack(spacing: prominent ? 4 : 0) {
            if let icon, prominent {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(color)
            }
            Text(title)
                .font(.system(size: prominent ? 11 : 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: prominent ? .infinity : nil)
        .padding(.horizontal, prominent ? 10 : 8)
        .padding(.vertical, prominent ? 6 : 4)
        .background(
            Capsule(style: .continuous)
                .fill(color.opacity(prominent ? 0.18 : 0.12))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(color.opacity(prominent ? 0.40 : 0.28), lineWidth: 0.5)
        )
    }
}

#Preview("Large", as: .systemLarge, widget: {
    BurnBarWidget()
}, timeline: {
    BurnBarEntry(date: Date(), snapshot: .preview)
})

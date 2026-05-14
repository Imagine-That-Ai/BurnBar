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
                WidgetEyebrow(text: "BurnBar", showLiveDot: false)
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

            // Hero metrics
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(snap?.heroTotalCost.formatAsCost() ?? "—")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(WidgetDesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .widgetAccentable()

                Text(snap?.heroTotalTokens.formatAsTokensRaw() ?? "0")
                    .font(WidgetDesignSystem.Typography.headline)
                    .foregroundStyle(WidgetDesignSystem.Colors.textPrimary)

                Text("tokens")
                    .font(WidgetDesignSystem.Typography.caption)
                    .foregroundStyle(WidgetDesignSystem.Colors.textSecondary)

                Spacer()

                HStack(spacing: 4) {
                    Text("\(snap?.heroTotalRequests ?? 0)")
                        .font(WidgetDesignSystem.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(WidgetDesignSystem.Colors.textPrimary)
                    Text("reqs")
                        .font(WidgetDesignSystem.Typography.micro)
                        .foregroundStyle(WidgetDesignSystem.Colors.textMuted)
                        .textCase(.uppercase)
                }
            }
            .padding(.horizontal, 16)

            // Sparkline
            if let points = snap?.dailyPoints, !points.isEmpty {
                WidgetMiniSparkline(data: points, color: WidgetDesignSystem.Colors.amber, height: 48)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }

            // Provider ranking
            if let providers = snap?.topProviders.prefix(3), !providers.isEmpty {
                VStack(spacing: 8) {
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

            // Mercury hairline + footer
            WidgetDesignSystem.Colors.mercuryGradient
                .frame(height: 1)
                .padding(.horizontal, 16)

            HStack {
                Spacer()
                if let date = snap?.lastSync {
                    Text("Updated \(date, style: .time)")
                        .font(WidgetDesignSystem.Typography.micro)
                        .foregroundStyle(WidgetDesignSystem.Colors.textMuted)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetGlassCard()
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
        guard let providerEnum else { return WidgetDesignSystem.Colors.amber }
        return DesignSystemColors.primary(for: providerEnum)
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text("\(rank)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(WidgetDesignSystem.Colors.textMuted)
                    .frame(width: 14, alignment: .center)

                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)

                if let providerEnum,
                   UIImage(named: providerEnum.bundledLogoName) != nil {
                    UnifiedProviderLogoView(provider: providerEnum, size: 14)
                }

                Text(name)
                    .font(WidgetDesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(WidgetDesignSystem.Colors.textPrimary)
                    .lineLimit(1)

                Spacer()

                Text(tokens.formatAsTokens())
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(WidgetDesignSystem.Colors.textSecondary)
                    .lineLimit(1)
            }

            WidgetCompactShareBar(
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

#Preview("Large", as: .systemLarge, widget: {
    BurnBarWidget()
}, timeline: {
    BurnBarEntry(date: Date(), snapshot: .preview)
})

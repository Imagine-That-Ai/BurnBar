import SwiftUI
import WidgetKit
import OpenBurnBarCore

struct HeroSmallView: View {
    let snap: BurnBarWidgetSnapshot?

    private var costText: String {
        snap?.heroTotalCost.formatAsCost() ?? "—"
    }

    private var tokensText: String {
        guard let snap else { return "—" }
        return snap.heroTotalTokens.formatAsTokensRaw()
    }

    private var topProvider: String {
        snap?.topProviders.first ?? "—"
    }

    var providerEnum: AgentProvider? {
        AgentProvider.fromPersistedToken(topProvider)
    }

    var body: some View {
        ZStack {
            WidgetDesignSystem.Colors.primaryGradient
                .ignoresSafeArea()

            WidgetFlameGlow()
                .offset(x: 24, y: -18)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(WidgetDesignSystem.Colors.accentGradient)

                    Text("BurnBar")
                        .font(WidgetDesignSystem.Typography.micro)
                        .foregroundStyle(WidgetDesignSystem.Colors.textSecondary)
                        .textCase(.uppercase)
                        .tracking(0.6)

                    Spacer()
                }

                Spacer(minLength: 4)

                Text(costText)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .widgetAccentable()

                Spacer(minLength: 2)

                HStack(spacing: 4) {
                    Text("\(tokensText) tokens")
                        .font(WidgetDesignSystem.Typography.caption)
                        .foregroundStyle(WidgetDesignSystem.Colors.textSecondary)

                    if topProvider != "—" {
                        Text("·")
                            .font(WidgetDesignSystem.Typography.caption)
                            .foregroundStyle(WidgetDesignSystem.Colors.textMuted)

                        if let providerEnum,
                           UIImage(named: providerEnum.bundledLogoName) != nil {
                            UnifiedProviderLogoView(provider: providerEnum, size: 12)
                        }

                        Text(topProvider)
                            .font(WidgetDesignSystem.Typography.caption)
                            .foregroundStyle(WidgetDesignSystem.Colors.amber)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                HStack(spacing: 6) {
                    WidgetMetricBadge(
                        icon: "number",
                        value: "\(snap?.heroTotalRequests ?? 0)",
                        label: "reqs",
                        color: WidgetDesignSystem.Colors.whimsy
                    )

                    if let window = snap?.windowKey {
                        WidgetMetricBadge(
                            icon: "calendar",
                            value: window,
                            label: "",
                            color: WidgetDesignSystem.Colors.textSecondary
                        )
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .widgetAccentable()
    }
}

#Preview("Small", as: .systemSmall, widget: {
    BurnBarWidget()
}, timeline: {
    BurnBarEntry(date: Date(), snapshot: .preview)
})

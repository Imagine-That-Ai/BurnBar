import SwiftUI
import WidgetKit
import OpenBurnBarCore

struct DashboardExtraLargeView: View {
    let snap: BurnBarWidgetSnapshot?

    private var totalTokens: Int {
        snap?.heroTotalTokens ?? 0
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left column: hero + sparkline
            VStack(alignment: .leading, spacing: 0) {
                headerBar

                heroMetrics
                    .padding(.horizontal, 20)
                    .padding(.top, 10)

                if let points = snap?.dailyPoints, !points.isEmpty {
                    WidgetMiniSparkline(data: points, color: WidgetDesignSystem.Colors.amber, height: 60)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                }

                modelPills
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)

                Spacer(minLength: 0)

                footerBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .widgetGlassCard()

            // Mercury column divider
            WidgetDesignSystem.Colors.mercuryGradient
                .frame(width: 1)

            // Right column: breakdown + details
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Breakdown")
                        .font(WidgetDesignSystem.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(WidgetDesignSystem.Colors.textSecondary)
                        .textCase(.uppercase)
                        .tracking(0.5)

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 8)

                providerList
                    .padding(.horizontal, 20)

                Spacer(minLength: 0)

                detailGrid
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .widgetGlassCardElevated()
        }
        .widgetAccentable()
    }

    // MARK: - Subviews

    private var headerBar: some View {
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
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var heroMetrics: some View {
        HStack(alignment: .lastTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snap?.heroTotalCost.formatAsCost() ?? "—")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(WidgetDesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .widgetAccentable()

                Text("\(snap?.heroTotalTokens.formatAsTokensRaw() ?? "0") tokens")
                    .font(WidgetDesignSystem.Typography.caption)
                    .foregroundStyle(WidgetDesignSystem.Colors.textSecondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
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

                if let first = snap?.topProviders.first {
                    WidgetProviderPill(
                        name: first,
                        tokens: snap?.topProviderTokens.first,
                        compact: true
                    )
                }
            }
        }
    }

    private var modelPills: some View {
        HStack(spacing: 6) {
            if let models = snap?.topModels.prefix(5), !models.isEmpty {
                ForEach(Array(models), id: \.self) { model in
                    WidgetModelPill(model: model)
                }
            }
        }
    }

    private var providerList: some View {
        VStack(spacing: 10) {
            if let providers = snap?.topProviders.prefix(4), !providers.isEmpty {
                ForEach(Array(providers.enumerated()), id: \.offset) { index, provider in
                    ProviderRow(
                        rank: index + 1,
                        name: provider,
                        tokens: snap?.topProviderTokens[safe: index] ?? 0,
                        totalTokens: totalTokens
                    )
                }
            }
        }
    }

    private var detailGrid: some View {
        HStack(spacing: 10) {
            WidgetMetricBadge(
                icon: "cpu",
                value: "\(snap?.topModels.count ?? 0)",
                label: "models",
                color: WidgetDesignSystem.Colors.amber
            )

            WidgetMetricBadge(
                icon: "building.2",
                value: "\(snap?.topProviders.count ?? 0)",
                label: "providers",
                color: WidgetDesignSystem.Colors.ember
            )

            if let points = snap?.dailyPoints, !points.isEmpty {
                WidgetMetricBadge(
                    icon: "chart.line.uptrend.xyaxis",
                    value: "\(points.count)d",
                    label: "trend",
                    color: WidgetDesignSystem.Colors.success
                )
            }
        }
    }

    private var footerBar: some View {
        HStack {
            Spacer()
            if let date = snap?.lastSync {
                Text("Updated \(date, style: .time)")
                    .font(WidgetDesignSystem.Typography.micro)
                    .foregroundStyle(WidgetDesignSystem.Colors.textMuted)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }
}

// MARK: - Supporting Components

struct WidgetModelPill: View {
    let model: String

    var color: Color {
        DesignSystemColors.colorForModel(model)
    }

    var body: some View {
        Text(model)
            .font(WidgetDesignSystem.Typography.micro)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(color.opacity(0.10))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(color.opacity(0.25), lineWidth: 0.5)
            )
            .foregroundStyle(color)
    }
}

struct WidgetMetricBadge: View {
    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(color)
                Text(label)
                    .font(WidgetDesignSystem.Typography.micro)
                    .foregroundStyle(WidgetDesignSystem.Colors.textMuted)
                    .textCase(.uppercase)
            }
            Text(value)
                .font(WidgetDesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(WidgetDesignSystem.Colors.textPrimary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: WidgetDesignSystem.Radius.sm, style: .continuous)
                .fill(color.opacity(0.08))
        )
    }
}

#Preview("Extra Large", as: .systemExtraLarge, widget: {
    BurnBarWidget()
}, timeline: {
    BurnBarEntry(date: Date(), snapshot: .preview)
})

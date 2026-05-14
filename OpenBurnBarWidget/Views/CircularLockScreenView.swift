import SwiftUI
import WidgetKit
import OpenBurnBarCore

struct CircularLockScreenView: View {
    let snap: BurnBarWidgetSnapshot?

    private var cost: Double { snap?.heroTotalCost ?? 0 }
    private var totalTokens: Int { snap?.heroTotalTokens ?? 0 }

    var providerEnum: AgentProvider? {
        guard let first = snap?.topProviders.first else { return nil }
        return AgentProvider.fromPersistedToken(first)
    }

    var gaugeColor: Color {
        guard let p = providerEnum else { return WidgetDesignSystem.Colors.amber }
        return DesignSystemColors.primary(for: p)
    }

    /// Gauge fill is based on cost as a fraction of a $20 daily soft cap.
    private var progress: Double {
        min(cost / 20.0, 1.0)
    }

    var body: some View {
        ZStack {
            // Background track
            Circle()
                .stroke(
                    WidgetDesignSystem.Colors.border.opacity(0.25),
                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                )

            // Progress arc with provider color
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    gaugeColor,
                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .widgetAccentable()

            // Center content
            VStack(spacing: 1) {
                Text(cost.formatAsCostCompact())
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .widgetAccentable()

                if totalTokens > 0 {
                    Text(totalTokens.formatAsTokens())
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            .padding(.horizontal, 4)
        }
        .widgetAccentable()
    }
}

#Preview("Circular", as: .accessoryCircular, widget: {
    BurnBarWidget()
}, timeline: {
    BurnBarEntry(date: Date(), snapshot: .preview)
})

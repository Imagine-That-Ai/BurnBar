import SwiftUI
import WidgetKit
import OpenBurnBarCore

struct CircularLockScreenView: View {
    let snap: BurnBarWidgetSnapshot?

    private var cost: Double { snap?.heroTotalCost ?? 0 }
    private var progress: Double { min(cost / 10.0, 1.0) }

    var body: some View {
        ZStack {
            // Background track
            Circle()
                .stroke(
                    Color.gray.opacity(0.15),
                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                )

            // Progress arc with gradient
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    WidgetDesignSystem.Colors.accentGradient,
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

                if let tokens = snap?.heroTotalTokens {
                    Text(tokens.formatAsTokens())
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

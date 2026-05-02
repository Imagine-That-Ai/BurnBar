import SwiftUI
import WidgetKit
import OpenBurnBarCore

struct CircularLockScreenView: View {
    let snap: BurnBarWidgetSnapshot?

    private var cost: Double { snap?.heroTotalCost ?? 0 }
    private var progress: Double { min(cost / 10.0, 1.0) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.gray.opacity(0.2), style: StrokeStyle(lineWidth: 5, lineCap: .round))

            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .widgetAccentable()

            VStack(spacing: 0) {
                Text(cost.formatAsCost())
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .widgetAccentable()

                if let tokens = snap?.heroTotalTokens {
                    Text("\(tokens.formatAsTokens())")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .widgetAccentable()
    }
}

#Preview("Circular", as: .accessoryCircular, widget: {
    BurnBarWidget()
}, timeline: {
    BurnBarEntry(date: Date(), snapshot: .preview)
})

import SwiftUI
import WidgetKit
import OpenBurnBarCore

struct RectangularLockScreenView: View {
    let snap: BurnBarWidgetSnapshot?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snap?.heroTotalCost.formatAsCost() ?? "—")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .widgetAccentable()

                Text("\(snap?.heroTotalTokens.formatAsTokensRaw() ?? "0") tokens")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let first = snap?.topProviders.first {
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 8, weight: .semibold))

                    Text(first)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(WidgetDesignSystem.Colors.amber.opacity(0.15))
                )
                .overlay(
                    Capsule()
                        .stroke(WidgetDesignSystem.Colors.amber.opacity(0.35), lineWidth: 1)
                )
                .foregroundStyle(WidgetDesignSystem.Colors.amber)
                .widgetAccentable()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetAccentable()
    }
}

#Preview("Rectangular", as: .accessoryRectangular, widget: {
    BurnBarWidget()
}, timeline: {
    BurnBarEntry(date: Date(), snapshot: .preview)
})

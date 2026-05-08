import SwiftUI
import WidgetKit
import OpenBurnBarCore

struct InlineLockScreenView: View {
    let snap: BurnBarWidgetSnapshot?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "flame.fill")
                .font(.system(size: 10, weight: .semibold))
                .widgetAccentable()

            Text(snap?.heroTotalCost.formatAsCost() ?? "—")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .widgetAccentable()

            Text("·")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            Text("\(snap?.heroTotalTokens.formatAsTokensRaw() ?? "0") tok")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if let first = snap?.topProviders.first {
                Text("·")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)

                Text(first)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .widgetAccentable()
    }
}

#Preview("Inline", as: .accessoryInline, widget: {
    BurnBarWidget()
}, timeline: {
    BurnBarEntry(date: Date(), snapshot: .preview)
})

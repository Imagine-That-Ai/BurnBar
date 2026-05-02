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
        return "\(snap.heroTotalTokens.formatAsTokens()) tokens"
    }

    private var topProvider: String {
        snap?.topProviders.first ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                Text("OpenBurnBar")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                Spacer()
            }

            Spacer(minLength: 2)

            Text(costText)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            HStack(spacing: 4) {
                Text(tokensText)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                Text("·")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.6))

                Text(topProvider)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetAccentable()
    }
}

#Preview("Small", as: .systemSmall, widget: {
    BurnBarWidget()
}, timeline: {
    BurnBarEntry(date: Date(), snapshot: .preview)
})

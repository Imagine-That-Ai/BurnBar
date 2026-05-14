import SwiftUI
import WidgetKit
import OpenBurnBarCore

struct RectangularLockScreenView: View {
    let snap: BurnBarWidgetSnapshot?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snap?.heroTotalCost.formatAsCost() ?? "—")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
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
                let providerEnum = AgentProvider.fromPersistedToken(first)
                let color: Color = {
                    guard let p = providerEnum else { return WidgetDesignSystem.Colors.amber }
                    return DesignSystemColors.primary(for: p)
                }()

                HStack(spacing: 4) {
                    if let p = providerEnum,
                       UIImage(named: p.bundledLogoName) != nil {
                        UnifiedProviderLogoView(provider: p, size: 12)
                    } else {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 8, weight: .semibold))
                    }

                    Text(first)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous)
                        .fill(color.opacity(0.15))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(color.opacity(0.35), lineWidth: 1)
                )
                .foregroundStyle(color)
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

import SwiftUI
import WidgetKit
import OpenBurnBarCore

struct DashboardLargeView: View {
    let snap: BurnBarWidgetSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)

                    Text("BurnBar")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                }

                Spacer()

                if let window = snap?.windowKey {
                    Text(window)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.7))
                        .textCase(.uppercase)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(snap?.heroTotalCost.formatAsCost() ?? "—")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text("\(snap?.heroTotalTokens ?? 0) tokens")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)

            if let points = snap?.dailyPoints, !points.isEmpty {
                TokenSparkline(data: points, color: Color.accentColor)
                    .frame(height: 60)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            }

            if let providers = snap?.topProviders.prefix(3), !providers.isEmpty {
                Divider()
                    .padding(.horizontal, 20)
                    .opacity(0.4)

                VStack(spacing: 8) {
                    ForEach(Array(providers.enumerated()), id: \.offset) { index, provider in
                        ProviderRow(
                            rank: index + 1,
                            name: provider,
                            tokens: snap?.topProviderTokens[safe: index] ?? 0
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }

            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetAccentable()
    }
}

private struct ProviderRow: View {
    let rank: Int
    let name: String
    let tokens: Int

    var providerEnum: AgentProvider? {
        AgentProvider.fromPersistedToken(name)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("\(rank)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.7))
                .frame(width: 16, alignment: .center)

            if let providerEnum,
               UIImage(named: providerEnum.bundledLogoName) != nil {
                UnifiedProviderLogoView(provider: providerEnum, size: 16)
            }

            Text(name)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()

            Text(tokens.formatAsTokens())
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

#Preview("Large", as: .systemLarge, widget: {
    BurnBarWidget()
}, timeline: {
    BurnBarEntry(date: Date(), snapshot: .preview)
})

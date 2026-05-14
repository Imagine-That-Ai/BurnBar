import Foundation
import SwiftUI

// MARK: - Nest Hub Mini Preview
//
// A 16:9 SwiftUI mock of the Nest Hub render surface. Mirrors the rich
// "live provider pressure" card layout served by `SmartHubBridgePage`
// — a horizontal rail of provider cards, each with a big token total,
// per-window bars, account chips, and a runs/spend footer.
//
// The preview never makes network calls. It accepts a snapshot of the
// data the Hub would render so tests can drive it deterministically.

public struct NestHubMiniPreview: View {
    public let config: SmartHubDisplayConfig
    public let snapshot: NestHubPreviewSnapshot
    public let cornerRadius: CGFloat

    public init(
        config: SmartHubDisplayConfig,
        snapshot: NestHubPreviewSnapshot = .placeholder,
        cornerRadius: CGFloat = UnifiedDesignSystem.Radius.lg
    ) {
        self.config = config
        self.snapshot = snapshot
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / 320, proxy.size.height / 180)
            ZStack {
                background
                content(scale: scale)
                    .padding(.horizontal, 10 * scale)
                    .padding(.vertical, 8 * scale)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.07), lineWidth: 0.5)
            )
            .opacity(config.clampedBrightness)
            .animation(.easeInOut(duration: 0.25), value: config.layout)
            .animation(.easeInOut(duration: 0.25), value: config.palette)
            .animation(.easeInOut(duration: 0.25), value: config.theme)
            .animation(.easeInOut(duration: 0.25), value: config.background)
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Background

    private var background: some View {
        let pair = config.theme.backgroundPair
        return ZStack {
            LinearGradient(
                colors: [Color(hex: pair.top), Color(hex: pair.bottom)],
                startPoint: .top,
                endPoint: .bottom
            )
            // Subtle whimsy/ember radial washes mirroring the Hub gradient.
            RadialGradient(
                colors: [Color(hex: config.palette.secondaryHex).opacity(0.18), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 240
            )
            RadialGradient(
                colors: [Color(hex: config.palette.primaryHex).opacity(0.10), .clear],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 240
            )
            // Faint dot grid the Hub stage uses.
            DotGrid()
                .opacity(0.18)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(scale: CGFloat) -> some View {
        switch config.background {
        case .photoBlend:
            photoBlendContent(scale: scale)
        case .ambient:
            ambientContent(scale: scale)
        case .dashboard:
            dashboardContent(scale: scale)
        }
    }

    private func dashboardContent(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            header(scale: scale)
            switch config.layout {
            case .quotaCarousel, .providerGrid:
                providerRail(scale: scale, limit: nil)
            case .bigTotal:
                bigTotalLayout(scale: scale)
            case .singleProvider:
                providerRail(scale: scale, limit: 1)
            }
        }
    }

    private func ambientContent(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            header(scale: scale)
            Spacer(minLength: 0)
            Text(snapshot.totalSpend)
                .font(.system(size: 42 * scale, weight: .bold, design: .rounded))
                .foregroundStyle(themeText)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(snapshot.subheadline)
                .font(.system(size: 10 * scale, weight: .medium))
                .foregroundStyle(themeText.opacity(0.7))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private func photoBlendContent(scale: CGFloat) -> some View {
        ZStack {
            if config.palette.isRainbow {
                LinearGradient(
                    colors: SmartHubDisplayPalette.rainbowFlag.map { Color(hex: $0).opacity(0.55) },
                    startPoint: .leading,
                    endPoint: .trailing
                )
            } else {
                LinearGradient(
                    colors: [
                        Color(hex: config.palette.primaryHex).opacity(0.55),
                        Color(hex: config.palette.secondaryHex).opacity(0.25),
                        Color.clear
                    ],
                    startPoint: .topTrailing,
                    endPoint: .bottomLeading
                )
            }
            VStack(alignment: .leading, spacing: 5 * scale) {
                header(scale: scale)
                Spacer(minLength: 0)
                Text(snapshot.totalSpend)
                    .font(.system(size: 30 * scale, weight: .bold, design: .rounded))
                    .foregroundStyle(themeText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(snapshot.headline)
                    .font(.system(size: 10 * scale, weight: .semibold))
                    .foregroundStyle(themeText.opacity(0.8))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
    }

    private func bigTotalLayout(scale: CGFloat) -> some View {
        VStack(alignment: .center, spacing: 4 * scale) {
            Spacer(minLength: 0)
            Text("TOTAL")
                .font(.system(size: 8 * scale, weight: .bold))
                .tracking(2)
                .foregroundStyle(themeText.opacity(0.55))
            Text(snapshot.totalSpend)
                .font(.system(size: 56 * scale, weight: .heavy, design: .rounded))
                .foregroundStyle(themeText)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
            Text(snapshot.headline)
                .font(.system(size: 10 * scale, weight: .semibold))
                .foregroundStyle(themeText.opacity(0.7))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Header

    private func header(scale: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 6 * scale) {
            Image("AppLogo", bundle: .main)
                .resizable()
                .renderingMode(.original)
                .aspectRatio(contentMode: .fit)
                .frame(width: 11 * scale, height: 11 * scale)
                .shadow(color: Color(hex: config.palette.primaryHex).opacity(0.25), radius: 2 * scale)
                .accessibilityHidden(true)

            Circle()
                .fill(Color(hex: "#38D898"))
                .frame(width: 5 * scale, height: 5 * scale)
                .shadow(color: Color(hex: "#38D898").opacity(0.4), radius: 2 * scale)

            Text(snapshot.headerStatus)
                .font(.system(size: 8 * scale, weight: .medium))
                .foregroundStyle(themeText.opacity(0.65))
                .lineLimit(1)

            Spacer(minLength: 4 * scale)

            // Refresh pill
            Text("Refresh")
                .font(.system(size: 7 * scale, weight: .semibold))
                .foregroundStyle(themeText.opacity(0.85))
                .padding(.horizontal, 8 * scale)
                .padding(.vertical, 2.5 * scale)
                .background(
                    Capsule()
                        .stroke(themeText.opacity(0.18), lineWidth: 0.5)
                )

            Spacer(minLength: 4 * scale)

            VStack(alignment: .trailing, spacing: 0) {
                Text(snapshot.dateText)
                    .font(.system(size: 7 * scale, weight: .medium))
                    .foregroundStyle(themeText.opacity(0.6))
                Text(snapshot.clockText)
                    .font(.system(size: 8 * scale, weight: .semibold, design: .rounded))
                    .foregroundStyle(themeText.opacity(0.85))
                    .monospacedDigit()
            }
            .lineLimit(1)
        }
    }

    // MARK: - Provider rail

    private func providerRail(scale: CGFloat, limit: Int?) -> some View {
        let providers = limit.map { Array(snapshot.providers.prefix($0)) } ?? snapshot.providers
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 6 * scale) {
                ForEach(providers) { provider in
                    providerCard(provider, scale: scale)
                        .frame(width: cardWidth(for: providers.count, scale: scale))
                }
            }
        }
        .scrollDisabled(true)
    }

    private func cardWidth(for count: Int, scale: CGFloat) -> CGFloat {
        // Aim for 4 cards visible in the preview's nominal 320pt × 180pt
        // viewport (after horizontal padding). Smaller counts get
        // proportionally larger cards.
        let nominal: CGFloat = 300 * scale
        let gap: CGFloat = 6 * scale
        let visible = max(1, min(count, 4))
        return (nominal - gap * CGFloat(visible - 1)) / CGFloat(visible)
    }

    private func providerCard(
        _ provider: NestHubPreviewSnapshot.Provider,
        scale: CGFloat
    ) -> some View {
        let accent = Color(hex: provider.accentHex.isEmpty ? config.palette.primaryHex : provider.accentHex)
        return VStack(alignment: .leading, spacing: 3 * scale) {
            // Top: name + freshness, live dot
            HStack(alignment: .top, spacing: 4 * scale) {
                providerLogo(provider, accent: accent, scale: scale)
                VStack(alignment: .leading, spacing: 0) {
                    Text(provider.name)
                        .font(.system(size: 12 * scale, weight: .bold, design: .rounded))
                        .foregroundStyle(themeText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if !provider.freshnessLabel.isEmpty {
                        Text(provider.freshnessLabel)
                            .font(.system(size: 6 * scale, weight: .medium))
                            .foregroundStyle(themeText.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Circle()
                    .fill(provider.isLive ? Color(hex: "#38D898") : themeText.opacity(0.2))
                    .frame(width: 4 * scale, height: 4 * scale)
                    .padding(.top, 3 * scale)
            }

            // Status pill (e.g. "reset passed")
            if !provider.statusPill.isEmpty {
                Text(provider.statusPill)
                    .font(.system(size: 6 * scale, weight: .semibold))
                    .foregroundStyle(toneColor(provider.statusTone))
                    .padding(.horizontal, 5 * scale)
                    .padding(.vertical, 1.5 * scale)
                    .background(
                        Capsule()
                            .fill(toneColor(provider.statusTone).opacity(0.18))
                    )
            }

            // Token total + label
            if !provider.tokenTotal.isEmpty {
                Text(provider.tokenTotal)
                    .font(.system(size: 22 * scale, weight: .heavy, design: .rounded))
                    .foregroundStyle(themeText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .padding(.top, 1 * scale)
                Text(provider.tokenTotalLabel)
                    .font(.system(size: 5.5 * scale, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(themeText.opacity(0.5))
                Rectangle()
                    .fill(themeText.opacity(0.08))
                    .frame(height: 0.5)
                    .padding(.vertical, 1 * scale)
            }

            // Buckets (top 2 fit the preview height comfortably)
            ForEach(Array(provider.buckets.prefix(2))) { bucket in
                bucketRow(bucket, accent: accent, scale: scale)
            }

            Spacer(minLength: 0)

            // Footer: runs + cost
            if !provider.runsLabel.isEmpty || !provider.costLabel.isEmpty {
                HStack(alignment: .lastTextBaseline, spacing: 0) {
                    Text(provider.runsLabel)
                        .font(.system(size: 6 * scale, weight: .medium))
                        .foregroundStyle(themeText.opacity(0.6))
                    Spacer(minLength: 2 * scale)
                    Text(provider.costLabel)
                        .font(.system(size: 7 * scale, weight: .bold, design: .rounded))
                        .foregroundStyle(themeText)
                        .monospacedDigit()
                }
                .lineLimit(1)
                .padding(.top, 1 * scale)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(themeText.opacity(0.08))
                        .frame(height: 0.5)
                        .offset(y: -1)
                }
            }
        }
        .padding(.horizontal, 6 * scale)
        .padding(.vertical, 5 * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7 * scale, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            accent.opacity(0.22),
                            accent.opacity(0.05),
                            Color.black.opacity(0.35)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7 * scale, style: .continuous)
                .stroke(accent.opacity(0.55), lineWidth: 0.75)
        )
        .shadow(color: accent.opacity(0.25), radius: 4 * scale)
    }

    private func providerLogo(
        _ provider: NestHubPreviewSnapshot.Provider,
        accent: Color,
        scale: CGFloat
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3 * scale, style: .continuous)
                .fill(accent.opacity(0.30))
            Text(provider.logoMonogram)
                .font(.system(size: 7 * scale, weight: .black, design: .rounded))
                .foregroundStyle(themeText)
        }
        .frame(width: 12 * scale, height: 12 * scale)
    }

    private func bucketRow(
        _ bucket: NestHubPreviewSnapshot.Bucket,
        accent: Color,
        scale: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 1 * scale) {
            HStack(spacing: 2 * scale) {
                Text(bucket.name)
                    .font(.system(size: 6 * scale, weight: .medium))
                    .foregroundStyle(themeText.opacity(0.65))
                    .lineLimit(1)
                Spacer(minLength: 2 * scale)
                Text(bucket.headlineValue)
                    .font(.system(size: 7 * scale, weight: .bold))
                    .foregroundStyle(themeText)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(themeText.opacity(0.10))
                    .frame(height: 2 * scale)
                Capsule()
                    .fill(toneFill(bucket.tone, accent: accent))
                    .frame(
                        width: max(1, CGFloat(min(bucket.percent, 100)) / 100 * 100 * scale),
                        height: 2 * scale
                    )
            }
            if !bucket.subLabel.isEmpty {
                Text(bucket.subLabel)
                    .font(.system(size: 5.5 * scale, weight: .medium))
                    .foregroundStyle(themeText.opacity(0.45))
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Helpers

    private var themeText: Color {
        Color(hex: config.theme.textHex)
    }

    private func toneColor(_ tone: NestHubPreviewSnapshot.Tone) -> Color {
        switch tone {
        case .ember:   return Color(hex: "#E07868")
        case .whimsy:  return Color(hex: "#A294F0")
        case .success: return Color(hex: "#38D898")
        case .warning: return Color(hex: "#F0C040")
        case .mercury: return Color(hex: "#C8BFB5")
        }
    }

    private func toneFill(
        _ tone: NestHubPreviewSnapshot.Tone,
        accent: Color
    ) -> Color {
        switch tone {
        case .ember, .whimsy:
            return accent
        case .success: return Color(hex: "#38D898")
        case .warning: return Color(hex: "#F0C040")
        case .mercury: return Color(hex: "#C8BFB5")
        }
    }

    private var accessibilityLabel: String {
        "Nest Hub preview, \(config.layout.displayName), \(config.palette.displayName) palette, \(config.theme.displayName) theme, \(config.background.displayName) background."
    }
}

// MARK: - Faint Dot Grid

private struct DotGrid: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 14
            ctx.opacity = 0.5
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    let rect = CGRect(x: x, y: y, width: 0.6, height: 0.6)
                    ctx.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.18)))
                    x += step
                }
                y += step
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Nest Hub Preview Snapshot

public struct NestHubPreviewSnapshot: Equatable, Sendable {
    public let totalSpend: String
    public let headline: String
    public let subheadline: String
    public let headerStatus: String
    public let dateText: String
    public let clockText: String
    public let providers: [Provider]

    public init(
        totalSpend: String,
        headline: String,
        subheadline: String,
        clockText: String,
        headerStatus: String = "live provider pressure",
        dateText: String = "",
        providers: [Provider]
    ) {
        self.totalSpend = totalSpend
        self.headline = headline
        self.subheadline = subheadline
        self.headerStatus = headerStatus
        self.dateText = dateText
        self.clockText = clockText
        self.providers = providers
    }

    public enum Tone: String, Sendable, Hashable {
        case ember, whimsy, success, warning, mercury
    }

    public struct Bucket: Identifiable, Equatable, Sendable, Hashable {
        public let id: String
        public let name: String
        public let percent: Int
        public let headlineValue: String
        public let subLabel: String
        public let tone: Tone

        public init(
            id: String,
            name: String,
            percent: Int,
            headlineValue: String,
            subLabel: String = "",
            tone: Tone = .mercury
        ) {
            self.id = id
            self.name = name
            self.percent = percent
            self.headlineValue = headlineValue
            self.subLabel = subLabel
            self.tone = tone
        }
    }

    public struct Account: Identifiable, Equatable, Sendable, Hashable {
        public let id: String
        public let label: String
        public let badge: String
        public let tone: Tone
        public let isActive: Bool

        public init(
            id: String,
            label: String,
            badge: String,
            tone: Tone = .mercury,
            isActive: Bool = false
        ) {
            self.id = id
            self.label = label
            self.badge = badge
            self.tone = tone
            self.isActive = isActive
        }
    }

    public struct Provider: Identifiable, Equatable, Sendable, Hashable {
        public let id: String
        public let name: String
        // Legacy single-bar fields — preserved so older serialization
        // round-trips keep working. The new rich layout reads `buckets`.
        public let percent: Int
        public let label: String
        public let windowLabel: String

        public let logoMonogram: String
        public let accentHex: String
        public let tokenTotal: String
        public let tokenTotalLabel: String
        public let statusPill: String
        public let statusTone: Tone
        public let freshnessLabel: String
        public let buckets: [Bucket]
        public let accounts: [Account]
        public let runsLabel: String
        public let costLabel: String
        public let isLive: Bool

        public init(
            id: String,
            name: String,
            percent: Int = 0,
            label: String = "",
            windowLabel: String = "",
            logoMonogram: String = "",
            accentHex: String = "",
            tokenTotal: String = "",
            tokenTotalLabel: String = "TOKENS",
            statusPill: String = "",
            statusTone: Tone = .mercury,
            freshnessLabel: String = "",
            buckets: [Bucket] = [],
            accounts: [Account] = [],
            runsLabel: String = "",
            costLabel: String = "",
            isLive: Bool = true
        ) {
            self.id = id
            self.name = name
            self.percent = percent
            self.label = label
            self.windowLabel = windowLabel
            self.logoMonogram = logoMonogram.isEmpty
                ? String(name.prefix(1)).uppercased()
                : logoMonogram
            self.accentHex = accentHex
            self.tokenTotal = tokenTotal
            self.tokenTotalLabel = tokenTotalLabel
            self.statusPill = statusPill
            self.statusTone = statusTone
            self.freshnessLabel = freshnessLabel
            self.buckets = buckets
            self.accounts = accounts
            self.runsLabel = runsLabel
            self.costLabel = costLabel
            self.isLive = isLive
        }
    }

    public static let placeholder = NestHubPreviewSnapshot(
        totalSpend: "$70,427.73",
        headline: "Last 5 hours",
        subheadline: "Updated just now",
        clockText: "10:43 PM",
        headerStatus: "live provider pressure",
        dateText: "Thu, May 7",
        providers: [
            .init(
                id: "claude",
                name: "Claude",
                logoMonogram: "C",
                accentHex: "E07868",
                tokenTotal: "5.4B",
                statusPill: "source 3h ago",
                statusTone: .ember,
                freshnessLabel: "updated 3h ago",
                buckets: [
                    .init(id: "5h", name: "5-hour limit", percent: 8, headlineValue: "8%", subLabel: "92% left", tone: .ember),
                    .init(id: "weekly", name: "Weekly limit", percent: 18, headlineValue: "18%", subLabel: "82% left", tone: .ember)
                ],
                accounts: [
                    .init(id: "cli", label: "Claude Code", badge: "CLI", tone: .ember, isActive: true)
                ],
                runsLabel: "1,002 runs",
                costLabel: "$5,835.40"
            ),
            .init(
                id: "codex",
                name: "Codex",
                logoMonogram: "C",
                accentHex: "A294F0",
                tokenTotal: "42.0B",
                statusPill: "reset passed",
                statusTone: .whimsy,
                freshnessLabel: "updated just now",
                buckets: [
                    .init(id: "5h", name: "5-hour window", percent: 33, headlineValue: "33%", subLabel: "67% left", tone: .whimsy),
                    .init(id: "7d", name: "7-day window", percent: 45, headlineValue: "45%", subLabel: "55% left", tone: .whimsy)
                ],
                accounts: [
                    .init(id: "work", label: "Work", badge: "MAIN", tone: .whimsy, isActive: true),
                    .init(id: "personal", label: "alberto8793@…", badge: "ACTIVE", tone: .success, isActive: true)
                ],
                runsLabel: "852 runs",
                costLabel: "$52,262.22"
            ),
            .init(
                id: "cursor",
                name: "Cursor",
                logoMonogram: "▣",
                accentHex: "C8BFB5",
                tokenTotal: "113.2M",
                statusPill: "$400 included",
                statusTone: .mercury,
                freshnessLabel: "updated 4m ago",
                buckets: [
                    .init(id: "auto", name: "Auto + Composer", percent: 8, headlineValue: "8%", subLabel: "92% left", tone: .mercury),
                    .init(id: "api", name: "API usage", percent: 78, headlineValue: "78%", subLabel: "22% left", tone: .warning)
                ],
                accounts: [],
                runsLabel: "216 runs",
                costLabel: "$620.13"
            ),
            .init(
                id: "droid",
                name: "Droid",
                logoMonogram: "❄︎",
                accentHex: "5F7CD9",
                tokenTotal: "11.2B",
                statusPill: "live local",
                statusTone: .success,
                freshnessLabel: "updated 4m ago",
                buckets: [
                    .init(id: "5h", name: "5-hour window", percent: 35, headlineValue: "350.8M", subLabel: "resets May 8", tone: .whimsy),
                    .init(id: "7d", name: "7-day window", percent: 39, headlineValue: "3.9B", subLabel: "resets May 14", tone: .whimsy)
                ],
                accounts: [],
                runsLabel: "2,750 runs",
                costLabel: "$12,309.98"
            )
        ]
    )
}

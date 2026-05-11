import Foundation
import SwiftUI

// MARK: - Nest Hub Mini Preview
//
// A 16:9 SwiftUI mock of the Nest Hub render surface. Reacts to layout,
// palette, theme, and background mode in real time so users can see the
// effect of each control before committing. The actual on-Hub render is
// the static HTML in `SmartHubBridgePage`; this view mirrors its
// structure using the same palette tokens.
//
// The preview never makes network calls. It accepts a snapshot of the
// data the Hub would render (provider rows + total) so tests can drive
// it deterministically.

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
                    .padding(.horizontal, 14 * scale)
                    .padding(.vertical, 12 * scale)
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
        return RadialGradient(
            colors: [
                Color(hex: pair.top),
                Color(hex: pair.bottom)
            ],
            center: .bottomTrailing,
            startRadius: 20,
            endRadius: 400
        )
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
            totalsBlock(scale: scale)
            Spacer(minLength: 0)
            switch config.layout {
            case .quotaCarousel, .providerGrid:
                providerRows(scale: scale, columns: config.layout == .providerGrid ? 2 : 1)
            case .bigTotal:
                EmptyView()
            case .singleProvider:
                providerRows(scale: scale, columns: 1, limit: 1)
            }
        }
    }

    private func ambientContent(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            header(scale: scale)
            Spacer(minLength: 0)
            Text(snapshot.totalSpend)
                .font(.system(size: 44 * scale, weight: .bold, design: .rounded))
                .foregroundStyle(themeText)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(snapshot.subheadline)
                .font(.system(size: 11 * scale, weight: .medium))
                .foregroundStyle(themeText.opacity(0.7))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private func photoBlendContent(scale: CGFloat) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hex: config.palette.primaryHex).opacity(0.55),
                    Color(hex: config.palette.secondaryHex).opacity(0.25),
                    Color.clear
                ],
                startPoint: .topTrailing,
                endPoint: .bottomLeading
            )
            VStack(alignment: .leading, spacing: 5 * scale) {
                header(scale: scale)
                Spacer(minLength: 0)
                totalsBlock(scale: scale)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Header

    private func header(scale: CGFloat) -> some View {
        HStack {
            Text("OpenBurnBar")
                .font(.system(size: 12 * scale, weight: .bold, design: .rounded))
                .foregroundStyle(themeText)
            Spacer()
            Text(snapshot.clockText)
                .font(.system(size: 11 * scale, weight: .medium, design: .rounded))
                .foregroundStyle(themeText.opacity(0.6))
                .monospacedDigit()
        }
    }

    // MARK: - Totals

    private func totalsBlock(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2 * scale) {
            Text(snapshot.totalSpend)
                .font(.system(size: 24 * scale, weight: .bold, design: .rounded))
                .foregroundStyle(themeText)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(snapshot.headline)
                .font(.system(size: 10 * scale, weight: .semibold))
                .foregroundStyle(themeText.opacity(0.75))
                .lineLimit(1)
            Text(snapshot.subheadline)
                .font(.system(size: 9 * scale, weight: .medium))
                .foregroundStyle(themeText.opacity(0.55))
                .lineLimit(1)
        }
    }

    // MARK: - Provider rows

    private func providerRows(scale: CGFloat, columns: Int, limit: Int? = nil) -> some View {
        let visible = (limit.map { Array(snapshot.providers.prefix($0)) } ?? snapshot.providers)
        let count = columns
        let grid = Array(repeating: GridItem(.flexible(), spacing: 4 * scale), count: count)
        return LazyVGrid(columns: grid, alignment: .leading, spacing: 4 * scale) {
            ForEach(visible) { provider in
                providerRow(provider, scale: scale)
            }
        }
    }

    private func providerRow(_ provider: NestHubPreviewSnapshot.Provider, scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2 * scale) {
            HStack {
                Text(provider.name)
                    .font(.system(size: 9 * scale, weight: .semibold))
                    .foregroundStyle(themeText)
                    .lineLimit(1)
                Spacer()
                Text(provider.windowLabel)
                    .font(.system(size: 7 * scale, weight: .bold, design: .rounded))
                    .foregroundStyle(themeText.opacity(0.55))
            }
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(themeText.opacity(0.08))
                Capsule()
                    .fill(tone(for: provider.percent))
                    .frame(width: max(4 * scale, CGFloat(provider.percent) / 100 * 120 * scale))
            }
            .frame(height: 4 * scale)
            Text(provider.label)
                .font(.system(size: 7 * scale, weight: .medium, design: .rounded))
                .foregroundStyle(themeText.opacity(0.65))
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, 5 * scale)
        .padding(.vertical, 4 * scale)
        .background(
            RoundedRectangle(cornerRadius: 5 * scale, style: .continuous)
                .fill(themeText.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5 * scale, style: .continuous)
                .stroke(themeText.opacity(0.08), lineWidth: 0.5)
        )
    }

    // MARK: - Helpers

    private var themeText: Color {
        Color(hex: config.theme.textHex)
    }

    private func tone(for percent: Int) -> Color {
        switch percent {
        case 0..<60:    return Color(hex: config.palette.secondaryHex)
        case 60..<85:   return Color(hex: config.palette.primaryHex)
        default:        return Color(hex: config.palette.primaryHex)
        }
    }

    private var accessibilityLabel: String {
        "Nest Hub preview, \(config.layout.displayName), \(config.palette.displayName) palette, \(config.theme.displayName) theme, \(config.background.displayName) background."
    }
}

// MARK: - Nest Hub Preview Snapshot

public struct NestHubPreviewSnapshot: Equatable, Sendable {
    public let totalSpend: String
    public let headline: String
    public let subheadline: String
    public let clockText: String
    public let providers: [Provider]

    public init(
        totalSpend: String,
        headline: String,
        subheadline: String,
        clockText: String,
        providers: [Provider]
    ) {
        self.totalSpend = totalSpend
        self.headline = headline
        self.subheadline = subheadline
        self.clockText = clockText
        self.providers = providers
    }

    public struct Provider: Identifiable, Equatable, Sendable, Hashable {
        public let id: String
        public let name: String
        public let percent: Int
        public let label: String
        public let windowLabel: String

        public init(id: String, name: String, percent: Int, label: String, windowLabel: String) {
            self.id = id
            self.name = name
            self.percent = percent
            self.label = label
            self.windowLabel = windowLabel
        }
    }

    public static let placeholder = NestHubPreviewSnapshot(
        totalSpend: "$182.40",
        headline: "Last 5 hours",
        subheadline: "Updated just now",
        clockText: "9:42",
        providers: [
            .init(id: "claude", name: "Claude Code", percent: 72, label: "$92 / $128", windowLabel: "5h"),
            .init(id: "factory", name: "Factory", percent: 41, label: "210 / 500 msgs", windowLabel: "7d"),
            .init(id: "codex", name: "Codex", percent: 18, label: "$24 / $130", windowLabel: "24h"),
            .init(id: "cursor", name: "Cursor", percent: 88, label: "440 / 500 msgs", windowLabel: "30d")
        ]
    )
}

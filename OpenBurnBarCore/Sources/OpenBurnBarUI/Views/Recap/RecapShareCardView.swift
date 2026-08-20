import SwiftUI
import OpenBurnBarInsights

// MARK: - Shared chrome
//
// Export layouts are laid out in export pixels (1080 wide), so sizes here are
// deliberately absolute rather than token-derived — a 15pt body that reads well
// in a window is invisible in a 1080-wide PNG.
//
// Nothing here uses the glass surface: `ImageRenderer` cannot sample a backdrop
// that is not there, so materials flatten to grey. Exports use solid fills.

private enum ShareMetrics {
    static let margin: CGFloat = 84
    static let footerSize: CGFloat = 26
    static let eyebrowSize: CGFloat = 28
    static let bodySize: CGFloat = 40
}

private struct ShareBackground: View {
    let accent: Color

    var body: some View {
        ZStack {
            UnifiedDesignSystem.Colors.background
            LinearGradient(
                colors: [accent.opacity(0.30), accent.opacity(0.06), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

private struct SharePartialBadge: View {
    var body: some View {
        Text("SUMMARISED FROM PART OF THE MONTH")
            .font(.system(size: 22, weight: .bold, design: .rounded))
            .tracking(2)
            .foregroundStyle(UnifiedDesignSystem.Colors.warning)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(UnifiedDesignSystem.Colors.warning.opacity(0.16), in: Capsule())
    }
}

private struct ShareFooter: View {
    let leading: String

    var body: some View {
        HStack(spacing: 10) {
            Text(leading.uppercased())
                .tracking(2)
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            Spacer(minLength: 0)
            Text("OpenBurnBar · burnbar.ai")
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
        }
        .font(.system(size: ShareMetrics.footerSize, weight: .semibold, design: .rounded))
    }
}

// MARK: - Card export

/// One recap card, re-composed to stand on its own in a group chat.
public struct RecapShareCardView: View {

    public let card: RecapCard
    public let window: RecapWindow
    public let width: CGFloat
    public let height: CGFloat
    /// A shared image outlives the app's own caveat, so it carries its own.
    public let isPartial: Bool

    public init(
        card: RecapCard,
        window: RecapWindow,
        width: CGFloat,
        height: CGFloat,
        isPartial: Bool = false
    ) {
        self.card = card
        self.window = window
        self.width = width
        self.height = height
        self.isPartial = isPartial
    }

    private var accent: Color { RecapTheme.accent(for: card) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 18) {
                Text(window.displayLabel().uppercased())
                    .font(.system(size: ShareMetrics.eyebrowSize, weight: .bold, design: .rounded))
                    .tracking(3)
                    .foregroundStyle(accent)
                if isPartial { SharePartialBadge() }
                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)

            if let metric = card.primaryMetric {
                Text(metric.formatted)
                    .font(.system(size: 156, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(RecapTheme.numeralFill(accent))
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                Text(metric.label.uppercased())
                    .font(.system(size: ShareMetrics.eyebrowSize, weight: .semibold, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                    .padding(.top, -18)
            }

            Text(card.headline)
                .font(.system(size: 62, weight: .bold, design: .rounded))
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(card.body)
                .font(.system(size: ShareMetrics.bodySize, weight: .regular, design: .rounded))
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(6)

            if visual.hasVisual {
                visual
                    .frame(height: height * 0.16)
                    .frame(maxWidth: .infinity)
            }

            Spacer(minLength: 0)
            ShareFooter(leading: card.kind.label(.long))
        }
        .padding(ShareMetrics.margin)
        .frame(width: width, height: height, alignment: .topLeading)
        .background(ShareBackground(accent: accent))
    }

    private var visual: RecapCardVisual { RecapCardVisual(card: card, accent: accent) }
}

// MARK: - Summary export

/// The closing sentence as a standalone image — the one people actually post.
public struct RecapShareSummaryView: View {

    public let recap: MonthlyRecap
    public let width: CGFloat
    public let height: CGFloat
    public let isPartial: Bool

    public init(recap: MonthlyRecap, width: CGFloat, height: CGFloat, isPartial: Bool = false) {
        self.recap = recap
        self.width = width
        self.height = height
        self.isPartial = isPartial
    }

    private var accent: Color { UnifiedDesignSystem.Colors.ember }

    public var body: some View {
        VStack(alignment: .leading, spacing: 34) {
            HStack(spacing: 18) {
                Text(recap.window.displayLabel().uppercased())
                    .font(.system(size: ShareMetrics.eyebrowSize, weight: .bold, design: .rounded))
                    .tracking(3)
                    .foregroundStyle(accent)
                if isPartial { SharePartialBadge() }
                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)

            Text(recap.title)
                .font(.system(size: 72, weight: .bold, design: .rounded))
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(recap.closingSentence)
                .font(.system(size: 42, weight: .regular, design: .rounded))
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(10)

            Spacer(minLength: 0)
            ShareFooter(leading: "Your month with AI")
        }
        .padding(ShareMetrics.margin)
        .frame(width: width, height: height, alignment: .topLeading)
        .background(ShareBackground(accent: accent))
    }
}

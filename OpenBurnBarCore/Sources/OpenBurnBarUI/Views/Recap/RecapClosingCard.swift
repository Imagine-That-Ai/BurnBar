import SwiftUI
import OpenBurnBarInsights
import OpenBurnBarRecap

/// The last card: the month in a sentence or three.
///
/// The one card that is allowed to generalise, because by the time a reader
/// reaches it every claim in it has already been shown above.
public struct RecapClosingCard: View {

    public let recap: MonthlyRecap
    public var onShare: (() -> Void)?

    public init(recap: MonthlyRecap, onShare: (() -> Void)? = nil) {
        self.recap = recap
        self.onShare = onShare
    }

    private var accent: Color { UnifiedDesignSystem.Colors.ember }

    public var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.md) {
            RecapEyebrow(text: "Your month in a sentence", accent: accent)

            Text(recap.closingSentence)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)

            Spacer(minLength: UnifiedDesignSystem.Spacing.sm)
            provenance
        }
        .padding(RecapTheme.Layout.heroPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .recapSurface(accent: accent, cornerRadius: RecapTheme.Layout.heroCornerRadius, isProminent: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Your month in a sentence. \(recap.closingSentence)")
    }

    /// Names who wrote the prose and whether it left the device. The recap is a
    /// thing people share, so where the words came from should never be a guess.
    @ViewBuilder
    private var provenance: some View {
        HStack(spacing: 6) {
            Image(systemName: recap.isVoiceAuthored ? "sparkles" : "function")
                .font(.system(size: 10, weight: .semibold))
            Text(provenanceText)
                .font(RecapTheme.Typography.eyebrow)
            Spacer(minLength: 0)
            if let onShare {
                Button(action: onShare) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(RecapTheme.Typography.eyebrow)
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
            }
        }
        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
    }

    private var provenanceText: String {
        guard recap.isVoiceAuthored, let tag = recap.provenance else {
            return "Written from your own numbers, on this device"
        }
        switch tag.egressTier {
        case .localOnly:
            return "Written by \(tag.displayName), on this device"
        default:
            return "Written by \(tag.displayName) · \(tag.egressTier.displayLabel)"
        }
    }
}

import SwiftUI
import OpenBurnBarInsights
import OpenBurnBarRecap

/// What the recap surface shows when there is no deck worth showing.
///
/// The honest alternative to padding a thin month out to sixteen cards. Says
/// what is missing and when it will be there, rather than apologising.
public struct RecapEmptyStateView: View {

    public enum Reason: Sendable, Equatable {
        /// The month exists but is below the substance floor.
        case notEnoughActivity(RecapWindow)
        /// Reading the month failed.
        case failed(String)
    }

    public let reason: Reason

    public init(reason: Reason) {
        self.reason = reason
    }

    private var accent: Color { UnifiedDesignSystem.Colors.ember }

    public var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.md) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(accent.opacity(0.8))
                .padding(.bottom, UnifiedDesignSystem.Spacing.xs)

            Text(title)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)

            Text(message)
                .font(RecapTheme.Typography.cardBody)
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(RecapTheme.Layout.heroPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .recapSurface(accent: accent, cornerRadius: RecapTheme.Layout.heroCornerRadius)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(message)")
    }

    private var symbol: String {
        switch reason {
        case .notEnoughActivity: return "hourglass"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var title: String {
        switch reason {
        case let .notEnoughActivity(window):
            return "\(window.monthLabel()) was quiet"
        case .failed:
            return "Couldn't read that month"
        }
    }

    private var message: String {
        switch reason {
        case .notEnoughActivity:
            return "There wasn't enough agent activity to say anything true about it. A recap needs about five active days before it can tell you something you didn't already know."
        case let .failed(detail):
            return detail
        }
    }
}

import SwiftUI

// MARK: - Aurora Section
//
// Section heading used across Pulse / Burn / Streams / You. A small accent
// dot, caption-cased label, optional right-aligned CTA, and a hairline
// underline that fades from the brand color into transparency.

struct AuroraSection<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let accent: Color
    @ViewBuilder let trailing: () -> Trailing

    init(
        _ title: String,
        subtitle: String? = nil,
        accent: Color = MobileTheme.ember,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accent = accent
        self.trailing = trailing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: MobileTheme.Spacing.sm) {
                Circle()
                    .fill(accent)
                    .frame(width: 6, height: 6)
                    .shadow(color: accent.opacity(0.6), radius: 4, y: 0)
                Text(title.uppercased())
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
                    .tracking(1.4)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                Spacer(minLength: 0)
                trailing()
            }
            if let subtitle {
                Text(subtitle)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
            }
            LinearGradient(
                colors: [accent.opacity(0.55), accent.opacity(0.0)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1)
            .opacity(0.7)
        }
    }
}

extension AuroraSection where Trailing == EmptyView {
    init(
        _ title: String,
        subtitle: String? = nil,
        accent: Color = MobileTheme.ember
    ) {
        self.init(title, subtitle: subtitle, accent: accent) { EmptyView() }
    }
}

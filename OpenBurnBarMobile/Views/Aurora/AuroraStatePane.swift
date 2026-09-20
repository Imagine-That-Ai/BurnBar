import SwiftUI

// MARK: - Aurora State Pane
//
// Empty / loading / error illustration panel. Replaces the legacy
// `EmptyStateView` and `ErrorStateView` for every Aurora surface.
// Centered illustration → headline → message → optional CTA.

struct AuroraStatePane: View {

    enum Kind {
        case empty
        case error
        case loading
    }

    let kind: Kind
    let icon: String
    let title: String
    let message: String
    let ctaLabel: String?
    let onCTA: (() -> Void)?

    init(
        kind: Kind,
        icon: String,
        title: String,
        message: String,
        ctaLabel: String? = nil,
        onCTA: (() -> Void)? = nil
    ) {
        self.kind = kind
        self.icon = icon
        self.title = title
        self.message = message
        self.ctaLabel = ctaLabel
        self.onCTA = onCTA
    }

    var body: some View {
        VStack(spacing: MobileTheme.Spacing.lg) {
            illustration
            VStack(spacing: 6) {
                Text(title)
                    .font(MobileTheme.Typography.headline)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Text(message)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
            }
            if let ctaLabel, let onCTA {
                Button(ctaLabel, action: onCTA)
                    .buttonStyle(.bordered)
            }
        }
        .padding(MobileTheme.Spacing.xl)
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Illustration

    private var illustration: some View {
        Image(systemName: icon)
            .font(.system(size: 36, weight: .regular))
            .foregroundStyle(kind == .error ? MobileTheme.error : Color.secondary)
            .symbolRenderingMode(.monochrome)
            .frame(height: 48)
    }
}

#Preview {
    ZStack {
        Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
        AuroraStatePane(
            kind: .empty,
            icon: "tray",
            title: "Nothing here yet",
            message: "The AI Inbox runs on your Mac and syncs here.",
            ctaLabel: "Open Mac App",
            onCTA: {}
        )
    }
}

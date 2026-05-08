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

    @State private var pulse = false

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
                    .buttonStyle(.aurora(.primary))
            }
        }
        .padding(MobileTheme.Spacing.xl)
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .onAppear { pulse = true }
    }

    // MARK: - Illustration

    private var illustration: some View {
        ZStack {
            // Halo
            Circle()
                .fill(haloColor.opacity(0.18))
                .frame(width: 160, height: 160)
                .blur(radius: 28)
                .scaleEffect(pulse ? 1.06 : 0.98)
                .animation(
                    .easeInOut(duration: 2.4).repeatForever(autoreverses: true),
                    value: pulse
                )

            // Ring
            Circle()
                .stroke(haloColor.opacity(0.32), lineWidth: 1)
                .frame(width: 132, height: 132)

            Image(systemName: icon)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(iconStyle)
                .symbolEffect(.bounce, options: .nonRepeating, value: pulse)
        }
        .frame(height: 160)
    }

    private var haloColor: Color {
        switch kind {
        case .empty: return MobileTheme.ember
        case .error: return MobileTheme.warning
        case .loading: return MobileTheme.hermesAureate
        }
    }

    private var iconStyle: AnyShapeStyle {
        switch kind {
        case .empty:
            return AnyShapeStyle(MobileTheme.primaryGradient)
        case .error:
            return AnyShapeStyle(MobileTheme.warning)
        case .loading:
            return AnyShapeStyle(AuroraDesign.Gradients.mercuryFoil)
        }
    }
}

#Preview {
    ZStack {
        AuroraBackdrop()
        AuroraStatePane(
            kind: .empty,
            icon: "chart.bar.fill",
            title: "No usage yet",
            message: "Open OpenBurnBar on your Mac to start streaming usage data.",
            ctaLabel: "Open Mac App",
            onCTA: {}
        )
    }
}

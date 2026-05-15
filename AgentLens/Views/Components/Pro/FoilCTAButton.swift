import SwiftUI
import AppKit

// MARK: - Foil CTA Button (macOS)
//
// Primary Pro action — obsidian fill, foil border, mercury shimmer, haptic
// alignment feedback on click. Mirrors the iOS variant.

struct FoilCTAButton: View {
    let title: String
    var subtitle: String? = nil
    var icon: String = "sparkle"
    var isLoading: Bool = false
    var fillWidth: Bool = true
    let action: () -> Void

    @State private var isPressed = false
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            action()
        } label: {
            HStack(spacing: 12) {
                leadingIcon
                titleStack
                if fillWidth { Spacer(minLength: 0) }
                if !isLoading {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(ProTheme.Palette.aureate)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: fillWidth ? .infinity : nil)
            .background(backgroundLayers)
            .overlay(
                RoundedRectangle(cornerRadius: ProTheme.Layout.bandRadius, style: .continuous)
                    .stroke(ProTheme.Palette.aureateStroke, lineWidth: 1.0)
            )
            .scaleEffect(isPressed ? 0.98 : (isHovered ? 1.01 : 1.0))
            .shadow(color: ProTheme.Palette.aureate.opacity(isHovered ? 0.30 : 0.18), radius: 18, y: 8)
            .animation(.spring(response: 0.25, dampingFraction: 0.78), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !isPressed { isPressed = true } }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) { isPressed = false }
                }
        )
        .disabled(isLoading)
        .accessibilityLabel(subtitle.map { "\(title). \($0)" } ?? title)
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if isLoading {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(ProTheme.Palette.mercury)
        } else {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(ProTheme.Palette.aureate)
        }
    }

    @ViewBuilder
    private var titleStack: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(ProTheme.Typography.headlineSerif)
                .foregroundStyle(ProTheme.Palette.mercury)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(ProTheme.Palette.mercury.opacity(0.68))
            }
        }
    }

    @ViewBuilder
    private var backgroundLayers: some View {
        ZStack {
            RoundedRectangle(cornerRadius: ProTheme.Layout.bandRadius, style: .continuous)
                .fill(ProTheme.Palette.obsidianElevated)

            if !reduceMotion {
                RoundedRectangle(cornerRadius: ProTheme.Layout.bandRadius, style: .continuous)
                    .fill(Color.clear)
                    .mercuryShimmer(active: true)
                    .opacity(isPressed ? 0.85 : 0.55)
                    .allowsHitTesting(false)
            }
        }
    }
}

#Preview("Foil CTA Button (macOS)") {
    ZStack {
        ProTheme.Palette.obsidian.ignoresSafeArea()
        VStack(spacing: 14) {
            FoilCTAButton(title: "Become a Member", subtitle: "$4.99 / month") {}
            FoilCTAButton(title: "Continue on iPhone", icon: "iphone", fillWidth: false) {}
            FoilCTAButton(title: "Processing", isLoading: true) {}
        }
        .padding(28)
        .frame(maxWidth: 460)
    }
    .frame(width: 540, height: 280)
}

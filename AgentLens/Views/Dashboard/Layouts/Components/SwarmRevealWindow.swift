import SwiftUI

// MARK: - Swarm Reveal Window
//
// A bordered glass "stage" whose centre is transparent so the always-on
// kernel + provider-swarm backdrop (rendered behind the whole dashboard via
// `DashboardBackdrop`) shows through. Concepts that want a *contained* swarm
// stage (Nebula, Cockpit) frame this instead of instantiating a second
// `SwarmCanvasView` / WebGL canvas — the app only ever runs one swarm
// instance, so this keeps the GPU budget flat (see the note in
// `DashboardDepthBackdrop`).
//
// Decorative; the optional overlay slot carries the "forming · <algorithm>"
// chip and any stage labels.

struct SwarmRevealWindow<Overlay: View>: View {
    var cornerRadius: CGFloat = DesignSystem.Radius.lg
    @ViewBuilder var overlay: () -> Overlay

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            backgroundLayer
            overlay()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(DesignSystem.Spacing.md)
        }
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(DesignSystem.Colors.border.opacity(0.45), lineWidth: 0.75)
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            // No live backdrop should bleed through under Reduce Transparency;
            // present a calm solid plate instead of a moving reveal.
            shape.fill(DesignSystem.Colors.surface.opacity(0.5))
        } else {
            // Transparent centre reveals the backdrop swarm; a faint accent
            // vignette gives the stage a focal glow without hiding it.
            shape.fill(
                RadialGradient(
                    colors: [DesignSystem.Colors.ember.opacity(0.06), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: 320
                )
            )
        }
    }
}

extension SwarmRevealWindow where Overlay == EmptyView {
    init(cornerRadius: CGFloat = DesignSystem.Radius.lg) {
        self.init(cornerRadius: cornerRadius) { EmptyView() }
    }
}

// MARK: - Forming chip
//
// The small "forming · <algorithm>" pill the prototype floats over each swarm
// stage. Purely decorative status text matching the backdrop's current motion.

struct SwarmFormingChip: View {
    var label: String = "forming"

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(DesignSystem.Colors.ember)
                .frame(width: 7, height: 7)
                .shadow(color: DesignSystem.Colors.ember.opacity(0.8), radius: 5)
            Text(label)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(DesignSystem.Colors.border.opacity(0.4), lineWidth: 0.5))
    }
}

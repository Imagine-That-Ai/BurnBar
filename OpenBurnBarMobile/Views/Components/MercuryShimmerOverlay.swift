import SwiftUI
import OpenBurnBarCore

// MARK: - Mercury Shimmer Overlay

/// A slow-moving mercury-tinted shimmer stroke used on assistant chat bubbles.
struct MercuryShimmerOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false

    var body: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [
                    .clear,
                    UnifiedDesignSystem.Colors.hermesMercury.opacity(0.15),
                    UnifiedDesignSystem.Colors.hermesAureate.opacity(0.10),
                    .clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: geo.size.width * 0.5)
            .offset(x: isAnimating ? geo.size.width * 0.75 : -geo.size.width * 0.25)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(UnifiedDesignSystem.Animation.mercuryShimmer) {
                isAnimating = true
            }
        }
    }
}

// MARK: - Preview

#Preview {
    RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(UnifiedDesignSystem.Colors.surface)
        .overlay(MercuryShimmerOverlay())
        .frame(height: 80)
        .padding()
}

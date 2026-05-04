import SwiftUI
import OpenBurnBarCore

// MARK: - Ember Skeleton

/// Branded skeleton loading component with warm ember-tinted shimmer.
/// Respects `accessibilityReduceMotion`.
struct EmberSkeleton: View {
    var height: CGFloat = 16
    var cornerRadius: CGFloat = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(UnifiedDesignSystem.Colors.surfaceElevated)
            .frame(height: height)
            .overlay(
                GeometryReader { geo in
                    shimmerBand
                        .frame(width: geo.size.width * 0.6)
                        .offset(x: isAnimating ? geo.size.width : -geo.size.width * 0.6)
                }
                .mask(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            )
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    isAnimating = true
                }
            }
    }

    private var shimmerBand: some View {
        LinearGradient(
            colors: [
                .clear,
                UnifiedDesignSystem.Colors.ember.opacity(0.12),
                UnifiedDesignSystem.Colors.amber.opacity(0.08),
                .clear
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 12) {
        EmberSkeleton(height: 120, cornerRadius: 16)
        EmberSkeleton(height: 16)
        EmberSkeleton(height: 16)
    }
    .padding()
    .background(UnifiedDesignSystem.Colors.background)
}

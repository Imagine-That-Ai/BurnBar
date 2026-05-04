import SwiftUI

/// Cross-platform skeleton loading view with ember-tinted shimmer animation.
/// Respects `accessibilityReduceMotion`.
public struct UnifiedSkeletonView: View {
    public var height: CGFloat = 16
    public var cornerRadius: CGFloat = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false

    public init(height: CGFloat = 16, cornerRadius: CGFloat = 8) {
        self.height = height
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.gray.opacity(0.2))
            .frame(height: height)
            .overlay(
                GeometryReader { geo in
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
}

#Preview {
    VStack(spacing: 12) {
        UnifiedSkeletonView(height: 120, cornerRadius: 16)
        UnifiedSkeletonView(height: 16)
        UnifiedSkeletonView(height: 16)
    }
    .padding()
}

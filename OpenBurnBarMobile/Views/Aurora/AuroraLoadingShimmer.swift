import SwiftUI

// MARK: - Aurora Loading Shimmer
//
// Aurora-flavored skeleton — replaces `EmberSkeleton` for new screens. The
// existing `EmberSkeleton` keeps working for legacy callers.

struct AuroraLoadingShimmer: View {
    var height: CGFloat = 16
    var cornerRadius: CGFloat = 10
    var width: CGFloat? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep: CGFloat = -1

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(MobileTheme.Colors.surface.opacity(0.6))
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        colors: [
                            Color.clear,
                            MobileTheme.ember.opacity(0.18),
                            MobileTheme.amber.opacity(0.10),
                            Color.clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.55)
                    .offset(x: sweep * (geo.size.width + geo.size.width * 0.55))
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(MobileTheme.Colors.border.opacity(0.35), lineWidth: 0.5)
            )
            .frame(width: width, height: height)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                    sweep = 1
                }
            }
    }
}

#Preview {
    VStack(spacing: 12) {
        AuroraLoadingShimmer(height: 120, cornerRadius: 22)
        AuroraLoadingShimmer(height: 16, cornerRadius: 8)
        AuroraLoadingShimmer(height: 16, cornerRadius: 8)
    }
    .padding()
    .background(MobileTheme.Colors.background)
}

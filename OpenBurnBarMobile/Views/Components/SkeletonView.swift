import SwiftUI

struct SkeletonView: View {
    var height: CGFloat = 16
    var cornerRadius: CGFloat = 8

    @State private var isAnimating = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.gray.opacity(0.2))
            .frame(height: height)
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.3), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.6)
                    .offset(x: isAnimating ? geo.size.width : -geo.size.width * 0.6)
                }
                .mask(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            )
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    isAnimating = true
                }
            }
    }
}

#Preview {
    VStack(spacing: 12) {
        SkeletonView(height: 120, cornerRadius: 16)
        SkeletonView(height: 16)
        SkeletonView(height: 16)
    }
    .padding()
}

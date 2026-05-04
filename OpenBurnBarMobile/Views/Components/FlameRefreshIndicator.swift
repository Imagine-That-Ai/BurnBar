import SwiftUI
import OpenBurnBarCore

// MARK: - Flame Refresh Indicator

/// A brief flame-arc spinner shown during pull-to-refresh.
struct FlameRefreshIndicator: View {
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            Image(systemName: "flame.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(UnifiedDesignSystem.Colors.ember)
                .rotationEffect(.degrees(isAnimating ? 360 : 0))
                .opacity(isAnimating ? 1 : 0.6)
        }
        .onAppear {
            withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                isAnimating = true
            }
        }
    }
}

// MARK: - Preview

#Preview {
    FlameRefreshIndicator()
        .padding()
}

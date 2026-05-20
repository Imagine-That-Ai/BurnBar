import SwiftUI

// MARK: - Chat FAB

struct ChatFAB: View {
    var hasNewInsights: Bool
    var action: () -> Void

    @State private var appeared = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    // Soft ambient glow
                    Circle()
                        .fill(DesignSystem.Colors.primaryGradient)
                        .frame(width: 54, height: 54)
                        .blur(radius: 14)
                        .opacity(hasNewInsights ? 0.22 : 0.16)

                    // Dark glass face
                    Circle()
                        .fill(DesignSystem.Colors.surfaceElevated)
                        .frame(width: 50, height: 50)
                        .overlay(
                            Circle()
                                .strokeBorder(DesignSystem.Colors.primaryGradient.opacity(0.65), lineWidth: 1.5)
                        )
                        .shadow(color: DesignSystem.Colors.background.opacity(0.5), radius: 12, y: 6)

                    Image(systemName: "sparkles")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(DesignSystem.Colors.primaryGradient)
                }

                if hasNewInsights {
                    Circle()
                        .fill(DesignSystem.Colors.amber)
                        .frame(width: 9, height: 9)
                        .offset(x: 3, y: -3)
                        .shadow(color: DesignSystem.Colors.amber.opacity(0.7), radius: 4)
                }
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(appeared ? 1 : 0.001)
        .animation(.spring(response: 0.42, dampingFraction: 0.72), value: appeared)
        .onAppear {
            appeared = true
        }
    }
}

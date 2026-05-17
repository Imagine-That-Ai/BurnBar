#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import OpenBurnBarComputerUseCore

struct ComputerUseTrustModeBadge: View {
    let mode: ComputerUseTrustMode

    var body: some View {
        Label(mode.rawValue.capitalized, systemImage: icon)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.16))
            )
            .accessibilityLabel("Trust mode \(mode.rawValue)")
    }

    private var icon: String {
        switch mode {
        case .manual: return "hand.raised.fill"
        case .step: return "figure.walk.motion"
        case .trusted: return "checkmark.shield.fill"
        }
    }

    private var tint: Color {
        switch mode {
        case .manual: return .orange
        case .step: return .blue
        case .trusted: return .green
        }
    }
}
#endif

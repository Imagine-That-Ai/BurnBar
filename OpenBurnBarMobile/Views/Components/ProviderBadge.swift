import SwiftUI
import OpenBurnBarCore

struct ProviderBadge: View {
    let provider: AgentProvider
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            Circle()
                .fill(MobileTheme.Colors.primary(for: provider).opacity(0.15))
                .frame(width: size, height: size)
            Image(systemName: provider.iconName)
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(MobileTheme.Colors.primary(for: provider))
        }
        .accessibilityLabel(provider.displayName)
    }
}

#Preview {
    HStack {
        ProviderBadge(provider: .claudeCode)
        ProviderBadge(provider: .cursor)
        ProviderBadge(provider: .codex)
    }
    .padding()
}

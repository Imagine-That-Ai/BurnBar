import SwiftUI
import OpenBurnBarCore

/// Deprecated — use `ProviderAvatar` instead.
/// Kept for backward compatibility; delegates to `.tile` mode.
struct ProviderBadge: View {
    let provider: AgentProvider
    var size: CGFloat = 32

    var body: some View {
        ProviderAvatar(provider: provider, mode: .tile, size: size)
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

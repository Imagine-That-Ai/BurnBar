import SwiftUI
import OpenBurnBarCore

/// Manual "Add Account" sheet shown post-onboarding from `ProviderConnectionsView`.
///
/// Hosts `MobileProviderWizardView` — the new beautiful card-based wizard
/// that mirrors the macOS `ProviderPlanWizardView`. When `provider` is
/// non-nil, the wizard opens at the first interactive step (auth method
/// or sync mode or credential, whichever comes first). When `provider` is
/// nil, the wizard opens at a searchable provider grid so users can pick
/// from any backend-supported provider in one place.
struct AddProviderConnectionView: View {
    let provider: AgentProvider?

    @Environment(\.dismiss) private var dismiss

    init(provider: AgentProvider? = nil) {
        self.provider = provider
    }

    var body: some View {
        NavigationStack {
            ZStack {
                EmberSurfaceBackground().ignoresSafeArea()

                MobileProviderWizardView(
                    preselectedProvider: provider,
                    onConnected: { _ in dismiss() },
                    onCancel: { dismiss() }
                )
            }
            .navigationTitle(provider.map { "Add \($0.displayName)" } ?? "Add provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

#Preview("Searchable picker") {
    AddProviderConnectionView(provider: nil)
}

#Preview("Standard cloud — Cursor") {
    AddProviderConnectionView(provider: .cursor)
}

#Preview("Codex — hosted & self-hosted") {
    AddProviderConnectionView(provider: .codex)
}

#Preview("Claude Code — self-hosted only") {
    AddProviderConnectionView(provider: .claudeCode)
}

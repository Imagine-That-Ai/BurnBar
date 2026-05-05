import SwiftUI
import OpenBurnBarCore

/// Manual "Add Account" sheet shown post-onboarding from `ProviderConnectionsView`.
///
/// Internally this is the **same** `OnboardingProviderConnectStep` the wizard
/// uses, just hosted inside its own NavigationStack with a Cancel button. The
/// user enters at the *Guide* sub-step and exits when the credential is
/// connected (or they cancel).
///
/// Renovating this surface to share components means:
///   - One place to keep "where do I find the credential?" copy
///     (`ProviderSetupGuide`).
///   - The connect/error/result UX is identical at first-run and afterwards,
///     so muscle memory transfers.
struct AddProviderConnectionView: View {
    let provider: AgentProvider

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                EmberSurfaceBackground().ignoresSafeArea()

                OnboardingProviderConnectStep(
                    provider: provider,
                    queuePosition: nil,
                    onConnected: { _ in
                        dismiss()
                    },
                    onSkip: {
                        dismiss()
                    }
                )
            }
            .navigationTitle("Add \(provider.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
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

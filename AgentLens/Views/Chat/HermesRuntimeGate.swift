import SwiftUI

/// Shared modifier that handles Hermes runtime presentation logic from the
/// floating `ChatPanel`, the maximized `DashboardChatWorkspaceView`, and
/// the pop-out chat window. Responsible for:
///   • Opening the Hermes setup wizard on first run when Hermes is selected.
///   • Surfacing the "Open Hermes + Gateway?" confirmation dialog when the
///     gateway is unreachable.
///   • Probing Hermes/OpenClaw availability when enabled backends change.
struct HermesRuntimeGate: ViewModifier {
    @Bindable var controller: ChatSessionController
    var settingsManager: SettingsManager
    var dataStore: DataStore?

    @State private var didRequestHermesFirstRunSetup = false
    @State private var showHermesRuntimePrompt = false
    @State private var hermesRuntimeLauncher = HermesRuntimeLauncher()

    func body(content: Content) -> some View {
        content
            .onAppear {
                controller.syncChatBackendWithEnabledBackends()
                presentHermesSetupIfNeeded()
                Task {
                    let enabled = settingsManager.enabledChatBackends
                    if enabled.contains(.hermes) {
                        await controller.probeHermesAvailability()
                    }
                    if enabled.contains(.openclaw) {
                        await controller.probeOpenClawAvailability()
                    }
                }
            }
            .onChange(of: controller.chatBackend) { _, _ in
                presentHermesSetupIfNeeded()
            }
            .onChange(of: settingsManager.enabledChatBackendIDsCSV) { _, _ in
                controller.syncChatBackendWithEnabledBackends()
                Task {
                    let enabled = settingsManager.enabledChatBackends
                    if enabled.contains(.hermes) {
                        await controller.probeHermesAvailability()
                    } else {
                        controller.hermesAvailable = false
                    }
                    if enabled.contains(.openclaw) {
                        await controller.probeOpenClawAvailability()
                    } else {
                        controller.openClawAvailable = false
                    }
                }
            }
            .confirmationDialog("Open Hermes?", isPresented: $showHermesRuntimePrompt) {
                Button("Open Hermes + Gateway") {
                    Task { await openHermesRuntime() }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Hermes is enabled but the local gateway is not reachable. OpenBurnBar can start the Hermes Dashboard and gateway for you.")
            }
    }

    private func presentHermesSetupIfNeeded() {
        guard controller.chatBackend == .hermes else { return }
        if settingsManager.hermesSetupWizardCompleted {
            if controller.hermesAvailable == false {
                Task {
                    await controller.probeHermesAvailability()
                    if controller.hermesAvailable == false {
                        showHermesRuntimePrompt = true
                    }
                }
            }
            return
        }
        guard !didRequestHermesFirstRunSetup else { return }
        didRequestHermesFirstRunSetup = true
        WindowManager.shared.openHermesSetupWizard(
            settingsManager: settingsManager,
            chatController: controller,
            dataStore: dataStore
        )
    }

    private func openHermesRuntime() async {
        await hermesRuntimeLauncher.openHermesAndGateway(
            baseURL: resolvedHermesGatewayBaseURL,
            bearerToken: resolvedHermesBearerToken
        )
        await controller.probeHermesAvailability()
        if controller.hermesAvailable {
            controller.setChatBackend(.hermes)
        }
    }

    private var resolvedHermesGatewayBaseURL: URL {
        URL(string: settingsManager.hermesGatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? URL(string: "http://127.0.0.1:8642")!
    }

    private var resolvedHermesBearerToken: String? {
        let token = settingsManager.hermesBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}

extension View {
    /// Attach the Hermes runtime gating behavior to a chat surface.
    func hermesRuntimeGate(
        controller: ChatSessionController,
        settingsManager: SettingsManager,
        dataStore: DataStore? = nil
    ) -> some View {
        modifier(HermesRuntimeGate(
            controller: controller,
            settingsManager: settingsManager,
            dataStore: dataStore
        ))
    }
}

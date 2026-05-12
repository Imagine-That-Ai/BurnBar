import SwiftUI

/// Shared modifier that handles managed-runtime presentation logic from the
/// floating `ChatPanel`, the maximized `DashboardChatWorkspaceView`, and the
/// pop-out chat window. Responsible for:
///   • Opening the Hermes setup wizard on first run when Hermes is selected.
///   • Surfacing the "Open Hermes + Gateway?" / "Open Pi + Gateway?"
///     confirmation dialog when the active backend's gateway is unreachable.
///   • Probing Hermes / OpenClaw / Pi availability when enabled backends
///     change.
///
/// Originally Hermes-only; the same flow now serves Pi via the shared
/// `ManagedAgentRuntimeAdapter` contract.
struct HermesRuntimeGate: ViewModifier {
    @Bindable var controller: ChatSessionController
    var settingsManager: SettingsManager
    var dataStore: DataStore?

    @State private var didRequestHermesFirstRunSetup = false
    @State private var showHermesRuntimePrompt = false
    @State private var showPiAgentRuntimePrompt = false
    @State private var hermesRuntimeLauncher = HermesRuntimeLauncher()
    @State private var piAgentRuntimeAdapter = PiAgentRuntimeAdapter()

    func body(content: Content) -> some View {
        content
            .onAppear {
                controller.syncChatBackendWithEnabledBackends()
                presentHermesSetupIfNeeded()
                presentPiAgentLaunchIfNeeded()
                Task {
                    let enabled = settingsManager.enabledChatBackends
                    if enabled.contains(.hermes) {
                        await controller.probeHermesAvailability()
                    }
                    if enabled.contains(.openclaw) {
                        await controller.probeOpenClawAvailability()
                    }
                    if enabled.contains(.piAgent) {
                        await controller.probePiAgentAvailability()
                    }
                }
            }
            .onChange(of: controller.chatBackend) { _, _ in
                presentHermesSetupIfNeeded()
                presentPiAgentLaunchIfNeeded()
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
                    if enabled.contains(.piAgent) {
                        await controller.probePiAgentAvailability()
                    } else {
                        controller.piAgentAvailable = false
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
            .confirmationDialog("Open Pi Agent?", isPresented: $showPiAgentRuntimePrompt) {
                Button("Open Pi + Gateway") {
                    Task { await openPiAgentRuntime() }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Pi Agent is selected but the local gateway is not reachable. OpenBurnBar can start the Pi agent and its gateway for you.")
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

    private func presentPiAgentLaunchIfNeeded() {
        guard controller.chatBackend == .piAgent else { return }
        Task {
            await controller.probePiAgentAvailability()
            if controller.piAgentAvailable == false {
                showPiAgentRuntimePrompt = true
            }
        }
    }

    private func openHermesRuntime() async {
        _ = await hermesRuntimeLauncher.openHermesAndGateway(
            baseURL: resolvedHermesGatewayBaseURL,
            bearerToken: resolvedHermesBearerToken
        )
        await controller.probeHermesAvailability()
        if controller.hermesAvailable {
            controller.setChatBackend(.hermes)
        }
    }

    private func openPiAgentRuntime() async {
        syncPiAgentAdapterPreferences()
        _ = await piAgentRuntimeAdapter.openManagedRuntime(
            baseURL: resolvedPiAgentGatewayBaseURL,
            bearerToken: resolvedPiAgentBearerToken
        )
        await controller.probePiAgentAvailability()
        if controller.piAgentAvailable {
            controller.setChatBackend(.piAgent)
        }
    }

    private func syncPiAgentAdapterPreferences() {
        let preferred = settingsManager.piAgentSelectedInstanceID.trimmingCharacters(in: .whitespacesAndNewlines)
        piAgentRuntimeAdapter.preferredInstanceID = preferred.isEmpty ? nil : preferred
        let redisRaw = settingsManager.piAgentRedisURL.trimmingCharacters(in: .whitespacesAndNewlines)
        piAgentRuntimeAdapter.redisURL = redisRaw.isEmpty ? nil : URL(string: redisRaw)
    }

    private var resolvedHermesGatewayBaseURL: URL {
        URL(string: settingsManager.hermesGatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? URL(string: "http://127.0.0.1:8642")!
    }

    private var resolvedHermesBearerToken: String? {
        let token = settingsManager.hermesBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private var resolvedPiAgentGatewayBaseURL: URL {
        URL(string: settingsManager.piAgentGatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? URL(string: "http://127.0.0.1:8765")!
    }

    private var resolvedPiAgentBearerToken: String? {
        let token = settingsManager.piAgentBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}

extension View {
    /// Attach the managed-runtime gating behavior to a chat surface (Hermes
    /// + Pi Agent).
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

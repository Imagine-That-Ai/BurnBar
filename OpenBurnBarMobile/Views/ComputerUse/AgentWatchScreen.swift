#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

struct AgentWatchScreen: View {
    private let authUID: String?
    private let hermesService: HermesService
    @StateObject private var coordinator: AgentWatchOverlayCoordinator
    @State private var connectionError: String?

    init(
        authUID: String? = nil,
        hermesService: HermesService = .shared,
        coordinator: AgentWatchOverlayCoordinator = AgentWatchOverlayCoordinator()
    ) {
        self.authUID = authUID
        self.hermesService = hermesService
        self._coordinator = StateObject(wrappedValue: coordinator)
    }

    var body: some View {
        AgentWatchView(
            state: coordinator.state,
            downgradeTrustMode: { mode in
                coordinator.state.setTrustMode(mode)
            },
            approveAction: { request in
                Task { try? await coordinator.receiver?.approve(request) }
            },
            rejectAction: { request, halt in
                Task { try? await coordinator.receiver?.reject(request, halt: halt) }
            },
            panicHalt: {
                Task {
                    do {
                        try await coordinator.receiver?.panicHalt()
                    } catch {
                        connectionError = "Could not send panic halt: \(error.localizedDescription)"
                    }
                    await coordinator.stop()
                }
            },
            sendTapIntent: { x, y in
                Task { try? await coordinator.receiver?.tap(normalizedX: x, normalizedY: y) }
            },
            sendScrollIntent: { x1, y1, x2, y2 in
                Task {
                    try? await coordinator.receiver?.scrollDrag(
                        startNormalizedX: x1,
                        startNormalizedY: y1,
                        endNormalizedX: x2,
                        endNormalizedY: y2
                    )
                }
            },
            sendTextIntent: { text in
                Task { try? await coordinator.receiver?.type(text) }
            },
            sendShortcutIntent: { key, modifiers in
                Task { try? await coordinator.receiver?.shortcut(key: key, modifiers: modifiers) }
            }
        )
        .overlay(alignment: .top) {
            if let connectionError {
                Text(connectionError)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.red.opacity(0.82), in: Capsule())
                    .padding(.top, 54)
                    .padding(.horizontal, 16)
            }
        }
        .navigationTitle("Agent Watch")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: watchConnectionKey) {
            await connectIfPossible()
        }
        .onDisappear {
            Task { await coordinator.stop() }
        }
    }

    private var watchConnectionKey: String {
        [
            authUID ?? "signed-out",
            hermesService.selectedConnection.id,
            hermesService.selectedConnection.relayPublicKey ?? "no-relay-key"
        ].joined(separator: "|")
    }

    private func connectIfPossible() async {
        await coordinator.stop()
        connectionError = nil

        guard let uid = authUID, !uid.isEmpty else {
            connectionError = "Sign in to watch a Mac session."
            return
        }
        let connection = hermesService.selectedConnection
        guard connection.mode == .relayLink,
              connection.id != HermesConnectionRecord.localDefault.id else {
            connectionError = "Select an online Mac Remote Relay in Hermes first."
            return
        }

        do {
            let pairingPublicKey = try await FirestoreIrohPairingPublicKeyProvider.shared.fetchPublicKey(uid: uid)
            coordinator.start(
                uid: uid,
                connectionID: connection.id,
                relayPublicKey: pairingPublicKey
            )
        } catch {
            connectionError = "Could not verify Mac pairing key: \(error.localizedDescription)"
        }
    }
}
#endif

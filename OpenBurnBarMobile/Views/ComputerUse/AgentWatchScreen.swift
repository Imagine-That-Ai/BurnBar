#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

struct AgentWatchScreen: View {
    private let authUID: String?
    private let hermesService: HermesService
    @StateObject private var coordinator: AgentWatchOverlayCoordinator
    @State private var connectionError: String?
    #if DEBUG
    @State private var didRunComputerUseE2EProof = false
    #endif

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
        .onChange(of: coordinator.phase) { _, phase in
            runComputerUseE2EProofIfNeeded(phase: phase)
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
            computerUseE2EProofLog("pairing_key_loaded connection=\(connection.id)")
            coordinator.start(
                uid: uid,
                connectionID: connection.id,
                relayPublicKey: pairingPublicKey
            )
            runComputerUseE2EProofIfNeeded(phase: coordinator.phase)
        } catch {
            computerUseE2EProofLog("connect_failed error=\(error.localizedDescription)")
            connectionError = "Could not verify Mac pairing key: \(error.localizedDescription)"
        }
    }

    private func runComputerUseE2EProofIfNeeded(phase: AgentWatchOverlayCoordinator.Phase) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["OPENBURNBAR_E2E_COMPUTER_USE_PROOF"] == "1" else { return }
        guard !didRunComputerUseE2EProof else { return }
        computerUseE2EProofLog("phase=\(phase.e2eLabel)")
        guard phase == .live else { return }
        didRunComputerUseE2EProof = true
        computerUseE2EProofLog("live_observed_by_view")
        #endif
    }

    #if DEBUG
    private func computerUseE2EProofLog(_ message: String) {
        let line = "OpenBurnBarMobile ComputerUseE2E \(message)"
        print(line)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("computer-use-e2e-proof.jsonl")
        let payload: [String: String] = [
            "event": message,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        guard
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            var text = String(data: data, encoding: .utf8)
        else { return }
        text.append("\n")
        guard let encoded = text.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: encoded)
            try? handle.close()
        } else {
            try? encoded.write(to: url, options: [.atomic])
        }
    }
    #else
    private func computerUseE2EProofLog(_ message: String) {}
    #endif
}

#if DEBUG
private extension AgentWatchOverlayCoordinator.Phase {
    var e2eLabel: String {
        switch self {
        case .idle: return "idle"
        case .dialing: return "dialing"
        case .live: return "live"
        case .reconnecting(let nextAttemptIn): return "reconnecting:\(nextAttemptIn)"
        case .stopped: return "stopped"
        case .failed(let reason): return "failed:\(reason)"
        }
    }
}
#endif
#endif

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

/// Read-only viewer that surfaces the persistent Agent Watch session
/// owned by `AgentWatchOverlaySingleton`. Dialing, redialing and
/// teardown all live in the singleton — this screen only binds to its
/// `coordinator.state` and routes input back through the shared
/// receiver. That way the You-tab subscreen and the floating Agent
/// Live Stage agree on a single coordinator, single relay stream, and
/// single Ed25519 phone authority.
struct AgentWatchScreen: View {
    private let authUID: String?
    private let hermesService: HermesService
    @ObservedObject private var singleton: AgentWatchOverlaySingleton
    #if DEBUG
    @State private var didRunComputerUseE2EProof = false
    #endif

    init(
        authUID: String? = nil,
        hermesService: HermesService = .shared,
        singleton: AgentWatchOverlaySingleton = .shared
    ) {
        self.authUID = authUID
        self.hermesService = hermesService
        self._singleton = ObservedObject(wrappedValue: singleton)
    }

    var body: some View {
        Group {
            if shouldShowMirror {
                AgentWatchView(
                    state: singleton.state,
                    downgradeTrustMode: { mode in
                        singleton.state.setTrustMode(mode)
                    },
                    approveAction: { request in
                        Task { try? await singleton.coordinator.receiver?.approve(request) }
                    },
                    rejectAction: { request, halt in
                        Task { try? await singleton.coordinator.receiver?.reject(request, halt: halt) }
                    },
                    panicHalt: {
                        Task {
                            try? await singleton.coordinator.receiver?.panicHalt()
                            await singleton.stop()
                        }
                    },
                    sendTapIntent: { x, y in
                        Task { try? await singleton.coordinator.receiver?.tap(normalizedX: x, normalizedY: y) }
                    },
                    sendScrollIntent: { x1, y1, x2, y2 in
                        Task {
                            try? await singleton.coordinator.receiver?.scrollDrag(
                                startNormalizedX: x1,
                                startNormalizedY: y1,
                                endNormalizedX: x2,
                                endNormalizedY: y2
                            )
                        }
                    },
                    sendTextIntent: { text in
                        Task { try? await singleton.coordinator.receiver?.type(text) }
                    },
                    sendShortcutIntent: { key, modifiers in
                        Task { try? await singleton.coordinator.receiver?.shortcut(key: key, modifiers: modifiers) }
                    }
                )
            } else {
                AgentWatchEmptyStateView(
                    isSignedIn: (authUID ?? "").isEmpty == false,
                    selectedConnection: hermesService.selectedConnection,
                    suggestedRelay: hermesService.suggestedRelayConnection,
                    sessionId: singleton.state.sessionId?.rawValue,
                    connectionMessage: singleton.connectionMessage,
                    phase: singleton.phase,
                    onOpenHermes: {
                        NotificationCenter.default.post(name: .init("ShowHermesChat"), object: nil)
                    },
                    onUseSuggestedRelay: {
                        _ = hermesService.connectToSuggestedRelay(refresh: true)
                        singleton.evaluate(authUID: authUID, hermesService: hermesService)
                    },
                    onOpenSettings: {
                        NotificationCenter.default.post(name: .init("ShowSettings"), object: nil)
                    }
                )
            }
        }
        .navigationTitle("Agent Watch")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: watchConnectionKey) {
            singleton.evaluate(authUID: authUID, hermesService: hermesService)
        }
        .onChange(of: singleton.phase) { _, phase in
            runComputerUseE2EProofIfNeeded(phase: phase)
        }
    }

    private var shouldShowMirror: Bool {
        if singleton.state.currentFrame != nil { return true }
        switch singleton.phase {
        case .live, .reconnecting, .dialing:
            return singleton.state.sessionId != nil
        case .idle, .stopped, .failed:
            return false
        }
    }

    private var watchConnectionKey: String {
        [
            authUID ?? "signed-out",
            hermesService.selectedConnection.id,
            hermesService.selectedConnection.relayPublicKey ?? "no-relay-key"
        ].joined(separator: "|")
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
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: encoded)
            _ = try? handle.close()
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

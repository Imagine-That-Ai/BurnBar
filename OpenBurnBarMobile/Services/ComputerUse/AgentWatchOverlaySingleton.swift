#if canImport(UIKit)
import Combine
import Foundation
import OpenBurnBarCore

/// Process-scoped owner of the persistent Computer Use control stream.
///
/// `AgentWatchOverlayCoordinator` is the working horse: it dials the relay,
/// signs the phone authority, publishes the public key, and consumes
/// `control.*` frames. Historically it was created per-screen via
/// `@StateObject` inside `AgentWatchScreen` and torn down on `.onDisappear`.
/// That model can't surface the live mirror inside the Hermes chat: the
/// stream needs to be alive *before* the user navigates to the You tab.
///
/// This singleton hoists the coordinator to the app lifecycle:
///   • Observe auth identity + the selected Hermes relay-link connection.
///   • When both are available, fetch the pairing public key and call
///     `coordinator.start(...)`.
///   • Restart on connection swap; stop when the user signs out or
///     selects the local-only "OpenBurnBar Daemon" connection.
///   • Survive tab changes; expose the underlying `AgentWatchState` so
///     `AgentLiveStage`, `AgentWatchScreen`, or any other surface can
///     bind to the same live model.
///
/// `start(refresh:)` is idempotent and safe to call from `.task`. The
/// singleton silently noops while the prerequisites aren't met.
@MainActor
final class AgentWatchOverlaySingleton: ObservableObject {
    static let shared = AgentWatchOverlaySingleton()

    /// Underlying coordinator owning the iroh stream + receiver + sender.
    let coordinator: AgentWatchOverlayCoordinator

    /// Live state mirrored from the coordinator. `AgentWatchState` is the
    /// store of record for `sessionId`, `currentFrame`, `actionTimeline`,
    /// `pendingApproval`, `liveTrustMode`.
    var state: AgentWatchState { coordinator.state }

    /// Latest dialing phase, mirrored for SwiftUI observation.
    @Published private(set) var phase: AgentWatchOverlayCoordinator.Phase = .idle

    /// Last error surfaced to the user (e.g. signed-out / no relay).
    @Published private(set) var connectionMessage: String?

    private var currentUID: String?
    private var currentConnectionID: String?
    private var cancellables: Set<AnyCancellable> = []
    private var pairingKeyProvider: any IrohPairingPublicKeyProviding
    private var dialTask: Task<Void, Never>?

    init(
        coordinator: AgentWatchOverlayCoordinator = AgentWatchOverlayCoordinator(),
        pairingKeyProvider: any IrohPairingPublicKeyProviding = FirestoreIrohPairingPublicKeyProvider.shared
    ) {
        self.coordinator = coordinator
        self.pairingKeyProvider = pairingKeyProvider
        bindPhase()
    }

    /// Drive the singleton from a SwiftUI surface (typically `RootTabView`).
    /// Re-evaluates the (uid, connection) input whenever auth flips or the
    /// user selects a different Hermes relay. Cheap to call on every
    /// `.task(id:)` change.
    func evaluate(authUID: String?, hermesService: HermesService) {
        let connection = hermesService.selectedConnection
        let isRelayLink = connection.mode == .relayLink &&
            connection.id != HermesConnectionRecord.localDefault.id
        guard let uid = authUID, !uid.isEmpty, isRelayLink else {
            connectionMessage = (authUID ?? "").isEmpty
                ? "Sign in to watch the Mac agent."
                : "Select an online Mac Remote Relay in Hermes to watch the agent live."
            Task { await self.stop() }
            return
        }

        if currentUID == uid, currentConnectionID == connection.id {
            // Already dialing or live on the right inputs.
            return
        }

        currentUID = uid
        currentConnectionID = connection.id
        connectionMessage = nil

        dialTask?.cancel()
        dialTask = Task { [weak self] in
            guard let self else { return }
            // Stop any previous session before redialing.
            await self.coordinator.stop()
            do {
                let pairingKey = try await self.pairingKeyProvider.fetchPublicKey(uid: uid)
                self.coordinator.start(
                    uid: uid,
                    connectionID: connection.id,
                    relayPublicKey: pairingKey
                )
            } catch {
                self.connectionMessage = "Could not verify Mac pairing key: \(error.localizedDescription)"
            }
        }
    }

    /// Hard-stop the persistent stream (sign-out, kill switch, manual halt).
    func stop() async {
        dialTask?.cancel()
        dialTask = nil
        currentUID = nil
        currentConnectionID = nil
        await coordinator.stop()
    }

    private func bindPhase() {
        coordinator.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                self?.phase = phase
            }
            .store(in: &cancellables)
    }
}
#endif

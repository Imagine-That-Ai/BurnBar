#if canImport(UIKit)
import Combine
import Foundation
import OpenBurnBarCore
import OpenBurnBarMedia

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

    /// Canonical video decode/display layer for the live stage and system PiP.
    /// Only one SwiftUI surface mounts this layer at a time; the layer retains
    /// its last frame between dock/split/maximize transitions.
    let videoCoordinator: AgentWatchVideoCoordinator

    /// System PiP bridge bound to `videoCoordinator.displayLayer`.
    let pipController: ScreenSharePiPController

    private let audioSession: AgentWatchAudioSession

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
    private var didAttachPiPController = false

    init(
        coordinator: AgentWatchOverlayCoordinator = AgentWatchOverlayCoordinator(),
        pairingKeyProvider: any IrohPairingPublicKeyProviding = FirestoreIrohPairingPublicKeyProvider.shared,
        videoCoordinator: AgentWatchVideoCoordinator = AgentWatchVideoCoordinator(),
        pipController: ScreenSharePiPController = ScreenSharePiPController(),
        audioSession: AgentWatchAudioSession = AgentWatchAudioSession()
    ) {
        self.coordinator = coordinator
        self.pairingKeyProvider = pairingKeyProvider
        self.videoCoordinator = videoCoordinator
        self.pipController = pipController
        self.audioSession = audioSession
        bindPhase()
        bindState()
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
            // Already dialing or live on the right inputs. Still clear
            // any stale error so a transient failure that resolves on
            // its own doesn't leave a permanent error banner.
            connectionMessage = nil
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
        audioSession.deactivate()
        pipController.stop()
        await coordinator.stop()
    }

    /// RootTabView installs the presenter callbacks once. The controller is
    /// attached lazily on the first live frame so PiP always binds to a layer
    /// that has actually received video.
    func configurePictureInPicture(
        onDidStart: @escaping () -> Void,
        onDidStop: @escaping () -> Void
    ) {
        pipController.onDidStart = onDidStart
        pipController.onDidStop = onDidStop
        if state.currentFrame != nil {
            attachPictureInPictureIfNeeded()
        }
    }

    private func bindPhase() {
        coordinator.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                self?.phase = phase
            }
            .store(in: &cancellables)
    }

    private func bindState() {
        state.$currentFrame
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] frame in
                guard let self else { return }
                self.attachPictureInPictureIfNeeded()
                Task { await self.videoCoordinator.ingest(frame: frame) }
            }
            .store(in: &cancellables)

        state.$sessionId
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] sessionId in
                guard let self else { return }
                if sessionId == nil {
                    self.audioSession.deactivate()
                    self.pipController.stop()
                    if #available(iOS 16.1, *) {
                        AgentWatchLiveActivityManager.shared.end()
                    }
                } else {
                    self.audioSession.activateForLiveWatchIfAllowed()
                    self.refreshLiveActivity()
                }
            }
            .store(in: &cancellables)

        state.$currentFocus
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshLiveActivity() }
            .store(in: &cancellables)

        state.$actionTimeline
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshLiveActivity() }
            .store(in: &cancellables)

        state.$pendingApproval
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshLiveActivity() }
            .store(in: &cancellables)
    }

    private func attachPictureInPictureIfNeeded() {
        guard !didAttachPiPController else { return }
        pipController.attach(displayLayer: videoCoordinator.displayLayer)
        didAttachPiPController = true
    }

    private func refreshLiveActivity() {
        guard let sessionId = state.sessionId else { return }
        let startedAt = state.sessionStartedAt ?? Date()
        if #available(iOS 16.1, *) {
            let focusName = state.currentFocus?.appName ?? "Agent Live"
            let lastAction = state.pendingApproval?.actionSummary
                ?? state.actionTimeline.last?.summary
                ?? "Watching Mac"
            AgentWatchLiveActivityManager.shared.start(
                sessionId: sessionId.rawValue,
                startedAt: startedAt
            )
            AgentWatchLiveActivityManager.shared.update(
                appName: focusName,
                lastAction: lastAction,
                actionsCount: state.actionsExecuted,
                approvalPending: state.pendingApproval != nil,
                elapsed: Date().timeIntervalSince(startedAt)
            )
        }
    }

    func installLiveActivityIntentRouter() {
        AgentWatchLiveActivityIntentRouter.install { command in
            await AgentWatchOverlaySingleton.shared.handleLiveActivityCommand(command)
        }
    }

    private func handleLiveActivityCommand(_ command: AgentWatchLiveActivityCommand) async {
        guard let receiver = coordinator.receiver else { return }
        switch command {
        case .approve:
            guard let request = state.pendingApproval else { return }
            try? await receiver.approve(request)
        case .reject:
            guard let request = state.pendingApproval else { return }
            try? await receiver.reject(request, halt: false)
        case .halt:
            try? await receiver.panicHalt()
        }
    }
}
#endif

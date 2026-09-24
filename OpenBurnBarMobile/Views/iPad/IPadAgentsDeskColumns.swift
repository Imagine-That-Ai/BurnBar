import Combine
import SwiftUI
import OpenBurnBarAssistantModels
import OpenBurnBarInboxModels
import OpenBurnBarKernel
import OpenBurnBarUI
import OpenBurnBarMedia

/// Agents rail + canvas for the iPad desk.
///
/// Hermes Square’s left column is the decision rail; the thread / mission /
/// composer is the canvas. This does **not** nest `HermesSquareSplitLayout`
/// (that `HStack` hid the destination sidebar below 720 pt by falling back
/// to the phone `HermesSquareRoot`). Compact iPhone still uses Square via
/// `RootTabView`.
@MainActor
final class IPadAgentsDeskController: ObservableObject {
    @Published var selectedDetail: HermesSquareSplitLayout.DetailRoute? = .runtimeNative(.codex)
    @Published var mercuryBootError: String?
    @Published var bootingMercuryConnectionID: String?

    let mercuryPeerSource: MercuryPeerSource
    private let hermesBox: HermesServiceBox
    private var started = false
    private var mercuryPeerCancellable: AnyCancellable?

    init() {
        let box = HermesServiceBox()
        hermesBox = box
        mercuryPeerSource = MercuryPeerSource(
            relayConnectionProvider: { box.service?.mercuryRelayConnection }
        )
    }

    func bind(hermesService: HermesService) {
        hermesBox.service = hermesService
        if mercuryPeerCancellable == nil {
            mercuryPeerCancellable = mercuryPeerSource.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }

    func startIfNeeded() async {
        guard let hermesService = hermesBox.service else { return }
        guard !started else {
            consumePendingHermesThread()
            return
        }
        started = true
        await hermesService.refreshConnections(refreshSelectedConnection: false)
        HermesIrohRelayTransport.shared.mediaPresenceHeartbeatHandler = { [weak self] heartbeat in
            await MainActor.run {
                self?.mercuryPeerSource.ingestHeartbeat(heartbeat)
            }
        }
        mercuryPeerSource.start()
        consumePendingHermesThread()
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            await hermesService.refreshConnections(refreshSelectedConnection: false)
        }
    }

    func stop() {
        mercuryPeerSource.stop()
        started = false
    }

    func openThread(_ item: ThreadInboxItem) {
        selectedDetail = .thread(item.id)
        HapticBus.tabChange()
    }

    func openRuntimeThread(runtime _: AssistantRuntimeID, inboxID: String) {
        selectedDetail = .thread(inboxID)
        HapticBus.tabChange()
    }

    func consumePendingHermesThread() {
        guard let inboxID = HermesSquarePendingThreadRoute.consumeHermesInboxID() else { return }
        selectedDetail = .thread(inboxID)
    }

    func ensureMercuryLive(connectionID: String) async {
        guard let hermesService = hermesBox.service else { return }
        let resolvedID = resolvedMercuryConnectionID(connectionID, hermesService: hermesService)
        guard bootingMercuryConnectionID != resolvedID else { return }
        bootingMercuryConnectionID = resolvedID
        mercuryBootError = nil
        defer { bootingMercuryConnectionID = nil }

        mercuryBootError = await hermesService.ensureMercuryMediaControlStream(connectionID: resolvedID)
    }

    private func resolvedMercuryConnectionID(
        _ routedConnectionID: String,
        hermesService: HermesService
    ) -> String {
        guard routedConnectionID.hasPrefix("paired-mac:") else { return routedConnectionID }
        return hermesService.mercuryRelayConnection?.id ?? routedConnectionID
    }
}

/// Avoids capturing `self` inside `IPadAgentsDeskController.init`.
private final class HermesServiceBox {
    var service: HermesService?
}

struct IPadAgentsRail: View {
    let hermesService: HermesService
    let missionHost: MobileMissionConsoleHost
    @ObservedObject var controller: IPadAgentsDeskController
    var searchQuery: String = ""

    var body: some View {
        HermesSquareLeftColumn(
            hermesService: hermesService,
            missionHost: missionHost,
            mercuryPeer: controller.mercuryPeerSource.peer,
            onSelect: { route in
                if case .mercuryLive = route {
                    NotificationCenter.default.post(name: IPadAwayDeskNotifications.pinWatch, object: nil)
                }
                controller.selectedDetail = route
            },
            onOpenThread: { item in
                controller.openThread(item)
            },
            externalSearchQuery: searchQuery,
            hidesInlineSearchField: true
        )
        .navigationTitle("Agents")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("ipad.agents.rail")
        .task {
            controller.bind(hermesService: hermesService)
            await controller.startIfNeeded()
        }
        .task(id: AssistantPendingThread.shared.hermes) {
            controller.consumePendingHermesThread()
        }
        .onDisappear {
            controller.stop()
        }
    }
}

struct IPadAgentsCanvas: View {
    let hermesService: HermesService
    let missionHost: MobileMissionConsoleHost
    @ObservedObject var controller: IPadAgentsDeskController

    var body: some View {
        HermesSquareDetailColumn(
            hermesService: hermesService,
            missionHost: missionHost,
            detail: controller.selectedDetail,
            mercuryPeer: controller.mercuryPeerSource.peer,
            mercuryBootError: controller.mercuryBootError,
            isBootingMercury: controller.bootingMercuryConnectionID != nil,
            ensureMercuryLive: { connectionID in
                await controller.ensureMercuryLive(connectionID: connectionID)
            },
            onOpenRuntimeThread: { runtime, inboxID in
                controller.openRuntimeThread(runtime: runtime, inboxID: inboxID)
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("ipad.agents.canvas")
    }
}

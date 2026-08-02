import SwiftUI
import OpenBurnBarCore
import OpenBurnBarMedia
import FirebaseAuth

// MARK: - Hermes Square Split Layout (Agents Split Layout §6.11 / S6)
//
// iPad-adaptive two-column layout that activates at width ≥ 720pt. Thread
// list + pinned grid live on the left; active thread / mission situation
// room lives on the right. Below 720pt, this view delegates back to
// `HermesSquareRoot` (the single-column phone layout) so iPhone is
// unaffected.
//
// Full parity with the compact root: federated search, approval inbox,
// fan-out group card, project memory wiki, rollback sections, voice
// command, discover drawer, subscriptions folder — all wired.

//
// iPad-adaptive two-column layout that activates at width ≥ 720pt. Thread
// list + pinned grid live on the left; active thread / mission situation
// room lives on the right. Below 720pt, this view delegates back to
// `HermesSquareRoot` (the single-column phone layout) so iPhone is
// unaffected.
//
// Full parity with the compact root: federated search, approval inbox,
// fan-out group card, project memory wiki, rollback sections, voice
// command, discover drawer, subscriptions folder — all wired.
struct HermesSquareSplitLayout: View {
    let hermesService: HermesService
    let missionHost: MobileMissionConsoleHost

    @State private var selectedDetail: DetailRoute? = .runtimeNative(.codex)
    @State private var sidebarMode: SidebarMode = .square
    @State private var resizeStartWidth: CGFloat?
    @StateObject private var mercuryPeerSource: MercuryPeerSource
    @State private var bootingMercuryConnectionID: String?
    @State private var mercuryBootError: String?
    @AppStorage("hermes_square_ipad_left_column_width") private var storedLeftColumnWidth: Double = 0

    init(hermesService: HermesService, missionHost: MobileMissionConsoleHost) {
        self.hermesService = hermesService
        self.missionHost = missionHost
        _mercuryPeerSource = StateObject(wrappedValue: MercuryPeerSource(
            relayConnectionProvider: {
                hermesService.suggestedRelayConnection
                    ?? (hermesService.selectedConnection.mode == .relayLink ? hermesService.selectedConnection : nil)
            }
        ))
    }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 720 {
                twoColumnLayout(width: geometry.size.width)
            } else {
                HermesSquareRoot(
                    hermesService: hermesService,
                    missionHost: missionHost
                )
            }
        }
    }

    private func twoColumnLayout(width: CGFloat) -> some View {
        let limits = leftColumnWidthLimits(for: width)
        let defaultWidth = min(max(width * 0.46, limits.min), limits.max)
        let leftWidth = storedLeftColumnWidth > 0
            ? min(max(CGFloat(storedLeftColumnWidth), limits.min), limits.max)
            : defaultWidth

        return HStack(spacing: 0) {
            NavigationStack {
                switch sidebarMode {
                case .square:
                    HermesSquareLeftColumn(
                        hermesService: hermesService,
                        missionHost: missionHost,
                        mercuryPeer: mercuryPeerSource.peer,
                        onSelect: { route in selectedDetail = route },
                        onOpenThread: openThreadFromSidebar
                    )
                case .history(let runtime):
                    HermesSquareRuntimeHistorySidebar(
                        runtime: runtime,
                        missionHost: missionHost,
                        onBack: {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                sidebarMode = .square
                            }
                        },
                        onOpenThread: openThreadFromSidebar
                    )
                }
            }
            .frame(width: leftWidth)
            .frame(maxHeight: .infinity)
            .clipped()

            HermesSquareResizeHandle()
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let startWidth = resizeStartWidth ?? leftWidth
                            resizeStartWidth = startWidth
                            let resizedWidth = startWidth + value.translation.width
                            storedLeftColumnWidth = Double(min(max(resizedWidth, limits.min), limits.max))
                        }
                        .onEnded { _ in
                            resizeStartWidth = nil
                        }
                )
                .accessibilityLabel("Resize Agents sidebar")
                .accessibilityHint("Drag left or right to resize the Agents sidebar.")

            HermesSquareDetailColumn(
                hermesService: hermesService,
                missionHost: missionHost,
                detail: selectedDetail,
                mercuryPeer: mercuryPeerSource.peer,
                mercuryBootError: mercuryBootError,
                isBootingMercury: bootingMercuryConnectionID != nil,
                ensureMercuryLive: { connectionID in
                    await ensureMercuryLive(connectionID: connectionID)
                },
                onOpenRuntimeThread: openRuntimeThreadFromDetail
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            WebsiteBackgroundView(accent: .purple, visibility: .prominent).ignoresSafeArea()
        }
        .task {
            // Refresh the relay catalog before Mercury starts polling it.
            // The iPad split layout can be the first Hermes surface opened
            // after sign-in, so its in-memory connection list may still be
            // empty even though the paired Mac is online in Firestore.
            await hermesService.refreshConnections(refreshSelectedConnection: false)
            HermesIrohRelayTransport.shared.mediaPresenceHeartbeatHandler = { heartbeat in
                await MainActor.run {
                    mercuryPeerSource.ingestHeartbeat(heartbeat)
                }
            }
            mercuryPeerSource.start()
            // A Mac can publish its relay after Agents is already visible
            // (for example immediately after the desktop app wakes). Keep
            // discovery fresh instead of permanently polling an empty
            // in-memory snapshot.
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
                await hermesService.refreshConnections(refreshSelectedConnection: false)
            }
        }
        .task(id: AssistantPendingThread.shared.hermes) {
            consumePendingHermesThread()
        }
        .onDisappear {
            mercuryPeerSource.stop()
        }
    }

    @MainActor
    private func consumePendingHermesThread() {
        guard let inboxID = HermesSquarePendingThreadRoute.consumeHermesInboxID() else { return }
        selectedDetail = .thread(inboxID)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            sidebarMode = .history(.hermes)
        }
    }

    private func openThreadFromSidebar(_ item: ThreadInboxItem) {
        selectedDetail = .thread(item.id)
        if let runtime = HermesSquareThreadRouting.runtime(for: item) {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                sidebarMode = .history(runtime)
            }
        }
        HapticBus.tabChange()
    }

    private func openRuntimeThreadFromDetail(runtime: AssistantRuntimeID, inboxID: String) {
        selectedDetail = .thread(inboxID)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            sidebarMode = .history(runtime)
        }
        HapticBus.tabChange()
    }

    private func leftColumnWidthLimits(for width: CGFloat) -> (min: CGFloat, max: CGFloat) {
        let minWidth = min(max(width * 0.34, 390), 460)
        let maxWidth = min(max(width * 0.58, 560), width - 520)
        return (minWidth, max(minWidth, maxWidth))
    }

    // MARK: Detail routes — mirrors HermesSquareRoot.NavTarget

    enum DetailRoute: Hashable {
        case thread(String)           // thread inbox id
        case mission(String)          // mission id
        case brandZone(String)        // agent URI
        case runtimeNative(AssistantRuntimeID)
        case runtimeThread(AssistantRuntimeID)
        case cloudSession(String)     // cloud conversation search row id
        case projectMemory(String)    // project id
        case mercuryLive(String)      // paired Mac iroh connection id
    }

    private enum SidebarMode: Hashable {
        case square
        case history(AssistantRuntimeID)
    }

    private func resolvedMercuryConnectionID(for routedConnectionID: String) -> String {
        if !routedConnectionID.hasPrefix("paired-mac:") {
            return routedConnectionID
        }
        if let relay = hermesService.suggestedRelayConnection {
            return relay.id
        }
        if hermesService.selectedConnection.mode == .relayLink {
            return hermesService.selectedConnection.id
        }
        return routedConnectionID
    }

    private func ensureMercuryLive(connectionID: String) async {
        let resolvedID = resolvedMercuryConnectionID(for: connectionID)
        guard bootingMercuryConnectionID != resolvedID else { return }
        bootingMercuryConnectionID = resolvedID
        mercuryBootError = nil
        defer { bootingMercuryConnectionID = nil }

        await hermesService.refreshConnections(refreshSelectedConnection: false)

        let relay: HermesConnectionRecord?
        if let exact = hermesService.relayConnections.first(where: { $0.id == resolvedID }) {
            _ = hermesService.selectConnection(exact, refresh: false)
            relay = exact
        } else if let selected = hermesService.relayConnections.first(where: { $0.id == hermesService.selectedConnection.id }) {
            relay = selected
        } else if let suggested = hermesService.suggestedRelayConnection {
            _ = hermesService.selectConnection(suggested, refresh: false)
            relay = suggested
        } else {
            relay = hermesService.suggestedRelayConnection
            if let relay {
                _ = hermesService.selectConnection(relay, refresh: false)
            }
        }

        guard let relay else {
            mercuryBootError = "No online Mac relay found. Open BurnBar on the Mac, enable Remote Relay, then refresh."
            return
        }

        do {
            try await HermesIrohRelayTransport.shared.ensureMediaControlStream(connectionID: relay.id)
            mercuryBootError = nil
        } catch {
            mercuryBootError = error.localizedDescription
        }
    }
}

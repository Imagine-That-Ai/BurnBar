import Foundation
import Observation
import OpenBurnBarIrohRelay
import OpenBurnBarKernel

/// The loop that keeps the Wire's lanes open (W1 of
/// `plans/2026-08-17-war-room-master-plan.md`).
///
/// Deliberately thin. Who to dial, who to hang up on, and who to leave alone is
/// decided by `WarWirePlanner` in the Kernel, which is unit-tested without a
/// transport, Firestore, or an entitlement service. This type owns only the
/// sockets and the clock.
///
/// Safe by construction: the planner runs `WarWireGate`, which denies on every
/// unknown. With no grants, no Pro/Ultra entitlement, or the kill switch
/// engaged — the default state of a fresh install — this host opens nothing.
@MainActor
@Observable
final class WarWireHost {
    /// Slower than the fleet heartbeat on purpose. Re-dialling is cheap to get
    /// wrong and expensive to get wrong often; a machine that just came online
    /// is picked up on the next pass rather than being raced for.
    static let refreshInterval: TimeInterval = 45

    private(set) var linkedBodyIDs: Set<String> = []
    private(set) var lastPlan: WarWirePlan?
    private(set) var lastRefreshAt: Date?
    /// Fleet slices received from each connected peer, keyed by the peer body
    /// id. The local body is deliberately not folded into this map: the
    /// directory remains the source of truth for this Mac.
    private(set) var wireFleets: [String: [FleetBodySnapshot]] = [:]

    private let directory: HermesBodyDirectory
    private let grantStore: WarWireGrantStore
    private let accountManager: AccountManaging
    private let tierProvider: @MainActor () -> CloudTier
    private let killSwitchProvider: @MainActor () -> Bool
    private let transportProvider: @MainActor () -> (any IrohRelayTransport)?

    @ObservationIgnored private var links: [String: WarWireLink] = [:]
    @ObservationIgnored private var readers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var refreshInFlight = false
    private static let cadenceID = "war-wire-refresh"

    init(
        directory: HermesBodyDirectory,
        grantStore: WarWireGrantStore,
        accountManager: AccountManaging,
        tierProvider: @escaping @MainActor () -> CloudTier,
        killSwitchProvider: @escaping @MainActor () -> Bool,
        transportProvider: @escaping @MainActor () -> (any IrohRelayTransport)?
    ) {
        self.directory = directory
        self.grantStore = grantStore
        self.accountManager = accountManager
        self.tierProvider = tierProvider
        self.killSwitchProvider = killSwitchProvider
        self.transportProvider = transportProvider
    }

    func start() {
        guard !started else { return }
        started = true
        generation &+= 1
        grantStore.start()
        BackgroundCadenceCoordinator.shared.register(
            BackgroundCadenceCoordinator.Cadence(
                id: Self.cadenceID,
                activeInterval: Self.refreshInterval,
                backgroundInterval: Self.refreshInterval * 5,
                sleepInterval: nil,
                isEnabled: { [weak self] in
                    self?.accountManager.isCloudSyncEnabled ?? false
                },
                fireImmediately: true,
                cancellableInFlight: false,
                work: { [weak self] in
                    await self?.refresh()
                }
            )
        )
    }

    func stop() {
        started = false
        generation &+= 1
        BackgroundCadenceCoordinator.shared.unregister(id: Self.cadenceID)
        grantStore.stop()
        for bodyID in Array(links.keys) { closeLink(to: bodyID) }
        wireFleets.removeAll()
    }

    /// One pass. Separated from the loop so it can be driven directly.
    func refresh(now: Date = Date()) async {
        // Direct callers can drive the first pass before `start()` in tests.
        // Once a started host is stopped, the generation guard below must keep
        // a late cadence invocation from reopening a lane.
        guard started || generation == 0 else { return }
        guard !refreshInFlight else { return }
        refreshInFlight = true
        defer { refreshInFlight = false }
        let refreshGeneration = generation
        lastRefreshAt = now
        guard let localBody = directory.localBody else {
            // Without a published identity for this Mac there is no `localBodyID`
            // to evaluate a grant against, and the gate would deny everything
            // anyway. Staying quiet beats emitting a plan full of `.unidentified`.
            lastPlan = nil
            return
        }

        let plan = WarWirePlanner.plan(
            peers: directory.bodies
                .filter { $0.id != localBody.id }
                .map {
                    WarWirePeer(
                        bodyID: $0.id,
                        displayName: $0.displayName,
                        irohNodeID: $0.irohNodeID,
                        isOnline: $0.presence(now: now) == .online
                    )
                },
            localBodyID: localBody.id,
            tier: tierProvider(),
            killSwitchEngaged: killSwitchProvider(),
            grants: Array(grantStore.grantsByPairID.values),
            linkedBodyIDs: linkedBodyIDs
        )
        lastPlan = plan

        // Hang up before dialling: a revoked lane should close even if the
        // subsequent dials fail.
        for drop in plan.drops {
            closeLink(to: drop.bodyID)
            AppLogger.network.info(
                "war_wire_lane_closed",
                metadata: ["bodyID": drop.bodyID, "reason": drop.reason.rawValue]
            )
        }

        if let transport = transportProvider() {
            let credentials = makeCredentials(localBody: localBody)
            for intent in plan.dials {
                guard generation == refreshGeneration, started || refreshGeneration == 0 else { return }
                await dial(
                    intent,
                    transport: transport,
                    credentials: credentials,
                    generation: refreshGeneration
                )
            }
        }

        guard generation == refreshGeneration, started || refreshGeneration == 0 else { return }
        let localFleet = [localFleetSnapshot(localBody)]
        for (bodyID, link) in links {
            guard await link.isReady else { continue }
            do {
                _ = try await link.pushFleetSnapshot(localFleet)
            } catch {
                AppLogger.network.silentFailure(
                    "war_wire_fleet_snapshot_push_failed",
                    error: error,
                    context: ["bodyID": bodyID]
                )
            }
        }
    }

    private func makeCredentials(localBody: HermesBodyRecord) -> WarWireCredentials {
        var capabilities = localBody.capabilities
        if !capabilities.contains(WarWireFrameCodec.capability) {
            capabilities.append(WarWireFrameCodec.capability)
        }
        return WarWireCredentials(
            localBodyID: localBody.id,
            localDisplayName: localBody.displayName,
            uid: accountManager.currentUID ?? "",
            connectionID: localBody.id,
            tier: tierProvider(),
            killSwitchEngaged: killSwitchProvider(),
            capabilities: capabilities
        )
    }

    /// Accept an inbound Wire whose opening hello was consumed by the relay
    /// request handler for first-frame classification.
    func acceptInbound(
        stream: any IrohRelayStream,
        opening: HermesRealtimeRelayFrame
    ) async {
        let acceptGeneration = generation
        guard let localBody = directory.localBody else {
            await stream.close()
            return
        }
        let credentials = makeCredentials(localBody: localBody)
        // The dialer asks for the grant synchronously while folding the hello.
        // Capture the current MainActor-owned view once, then perform a pure
        // lookup from the accepted stream's async context.
        let grants = grantStore.grantsByPairID
        let outcome = await WarWireDialer.accept(
            opening: opening,
            on: stream,
            credentials: credentials,
            grantForPeer: { remoteBodyID in
                grants[WarWireGrant.pairID(credentials.localBodyID, remoteBodyID)]
            }
        )
        guard generation == acceptGeneration, started || acceptGeneration == 0 else {
            if case let .connected(link) = outcome {
                await link.close()
            }
            return
        }
        switch outcome {
        case let .connected(link):
            install(link: link, bodyID: await link.remoteBodyID)
        case let .fallBackToFirestore(closure):
            AppLogger.network.info(
                "war_wire_inbound_firestore_fallback",
                metadata: ["closure": String(describing: closure)]
            )
        }
    }

    private func dial(
        _ intent: WarWireDialIntent,
        transport: any IrohRelayTransport,
        credentials: WarWireCredentials,
        generation dialGeneration: UInt64
    ) async {
        let outcome = await WarWireDialer.dial(
            transport: transport,
            target: IrohDialTarget(nodeId: intent.nodeID),
            remoteBodyID: intent.bodyID,
            grant: grantStore.grant(between: credentials.localBodyID, and: intent.bodyID),
            credentials: credentials
        )
        guard generation == dialGeneration, started || dialGeneration == 0 else {
            if case let .connected(link) = outcome {
                await link.close()
            }
            return
        }
        switch outcome {
        case let .connected(link):
            install(link: link, bodyID: intent.bodyID)
        case let .fallBackToFirestore(closure):
            // Not an error. The Wire is an upgrade, never a dependency, so a
            // refused dial means this peer keeps the Firestore relay path.
            AppLogger.network.info(
                "war_wire_firestore_fallback",
                metadata: ["bodyID": intent.bodyID, "closure": String(describing: closure)]
            )
        }
    }

    private func install(link: WarWireLink, bodyID: String) {
        if links[bodyID] != nil {
            closeLink(to: bodyID)
        }
        links[bodyID] = link
        linkedBodyIDs.insert(bodyID)
        readers[bodyID] = Task { [weak self] in
            await self?.read(link, bodyID: bodyID)
        }
    }

    private func localFleetSnapshot(_ localBody: HermesBodyRecord) -> FleetBodySnapshot {
        FleetBodySnapshot(
            bodyID: localBody.id,
            displayName: localBody.displayName,
            // The receiving Mac owns the local/remote perspective.
            isLocal: false,
            isOnline: true,
            hermesGatewayReachable: localBody.hermesGatewayReachable,
            wireReachable: true,
            capabilities: Set(localBody.capabilities),
            activeRunCount: localBody.botCount ?? 0,
            performanceCores: localBody.coresPerformance
        )
    }

    private func read(_ link: WarWireLink, bodyID: String) async {
        while !Task.isCancelled {
            switch await link.next() {
            case let .event(event):
                switch event {
                case let .fleetSnapshot(fleet):
                    if wireFleets[bodyID] != fleet {
                        wireFleets[bodyID] = fleet
                    }
                case let .dispatch(request):
                    // Work travels on the mission document stamped with
                    // `targetBodyID`, which every Mac already listens to;
                    // the Wire carries liveness. Executing an inbound
                    // dispatch frame here would run the same mission twice.
                    AppLogger.network.info(
                        "war_wire_dispatch_ignored_mission_document_is_the_work_road",
                        metadata: ["dispatchId": request.dispatchId]
                    )
                default:
                    break
                }
            case .handled:
                continue
            case .finished, .closed:
                forgetLink(bodyID)
                return
            }
        }
    }

    private func closeLink(to bodyID: String) {
        guard let link = links[bodyID] else { return }
        forgetLink(bodyID)
        Task { await link.close() }
    }

    /// Drop bookkeeping for a lane that is already gone. Split from
    /// `closeLink` so the reader can report a peer hangup without asking the
    /// actor to close a stream the peer already closed.
    private func forgetLink(_ bodyID: String) {
        readers[bodyID]?.cancel()
        readers[bodyID] = nil
        links[bodyID] = nil
        linkedBodyIDs.remove(bodyID)
        wireFleets[bodyID] = nil
    }
}

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

    private let directory: HermesBodyDirectory
    private let grantStore: WarWireGrantStore
    private let accountManager: AccountManaging
    private let tierProvider: @MainActor () -> CloudTier
    private let killSwitchProvider: @MainActor () -> Bool
    private let transportProvider: @MainActor () -> (any IrohRelayTransport)?

    @ObservationIgnored private var links: [String: WarWireLink] = [:]
    @ObservationIgnored private var readers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?

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
        guard loop == nil else { return }
        grantStore.start()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(Self.refreshInterval)) // try?-ok(cancellation only; the loop condition handles it)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        grantStore.stop()
        for bodyID in links.keys { closeLink(to: bodyID) }
    }

    deinit {
        loop?.cancel()
    }

    /// One pass. Separated from the loop so it can be driven directly.
    func refresh(now: Date = Date()) async {
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

        guard !plan.dials.isEmpty, let transport = transportProvider() else { return }
        let credentials = makeCredentials(localBody: localBody)
        for intent in plan.dials {
            await dial(intent, transport: transport, credentials: credentials)
        }
    }

    private func makeCredentials(localBody: HermesBodyRecord) -> WarWireCredentials {
        WarWireCredentials(
            localBodyID: localBody.id,
            localDisplayName: localBody.displayName,
            uid: accountManager.currentUID ?? "",
            connectionID: localBody.deviceID,
            tier: tierProvider(),
            killSwitchEngaged: killSwitchProvider(),
            capabilities: localBody.capabilities
        )
    }

    private func dial(
        _ intent: WarWireDialIntent,
        transport: any IrohRelayTransport,
        credentials: WarWireCredentials
    ) async {
        let outcome = await WarWireDialer.dial(
            transport: transport,
            target: IrohDialTarget(nodeId: intent.nodeID),
            remoteBodyID: intent.bodyID,
            grant: grantStore.grant(between: credentials.localBodyID, and: intent.bodyID),
            credentials: credentials
        )
        switch outcome {
        case let .connected(link):
            links[intent.bodyID] = link
            linkedBodyIDs.insert(intent.bodyID)
            readers[intent.bodyID] = Task { [weak self] in
                await self?.read(link, bodyID: intent.bodyID)
            }
        case let .fallBackToFirestore(closure):
            // Not an error. The Wire is an upgrade, never a dependency, so a
            // refused dial means this peer keeps the Firestore relay path.
            AppLogger.network.info(
                "war_wire_firestore_fallback",
                metadata: ["bodyID": intent.bodyID, "closure": String(describing: closure)]
            )
        }
    }

    private func read(_ link: WarWireLink, bodyID: String) async {
        while !Task.isCancelled {
            switch await link.next() {
            case .event, .handled:
                continue
            case .finished, .closed:
                await MainActor.run { self.forgetLink(bodyID) }
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
    }
}

import XCTest
import Foundation
import OpenBurnBarCore
@testable import OpenBurnBarMobile

/// Behavior contract for the mobile fleet dashboard store.
///
/// The board is produced by another machine on a cadence, so the failure
/// modes this suite pins are the SILENT ones a user cannot spot on screen:
///
///   1. a stale mirror must render as "Mac offline", never as a current
///      board (`updatedAt` older than max(3× cadence, 15 minutes)),
///   2. a missing document is the offline state too — not a spinner and not
///      an invented empty fleet,
///   3. an unreadable document surfaces an error and never fabricates (or
///      blanks) a board,
///   4. the header readout never says "0 running" without a snapshot to
///      back it, and machine metrics never format absence as a value.
///
/// No live Firestore: the store's outcome-application seam and the injected
/// clock drive the full state machine; the codec round-trip uses real sealed
/// bytes like `AIInboxStoreTests` does.
@MainActor
final class MobileFleetStoreTests: XCTestCase {

    private let uid = "user-fleet-tests"
    private lazy var vaultKey = Data(repeating: 0x5C, count: 32)
    private lazy var vaultKeyID = (try? CloudVaultCrypto.vaultKeyID(for: vaultKey)) ?? ""

    /// Reference wall clock — whole seconds so sealed ISO-8601 dates
    /// round-trip exactly.
    private let now = Date(timeIntervalSince1970: 1_755_000_000)

    // MARK: - Fixtures

    /// Mutable clock injected as the store's `now` seam.
    private final class TestClock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private func makeStore(clock: TestClock) -> MobileFleetStore {
        MobileFleetStore(now: { clock.now }, observeAuthChanges: false)
    }

    private func makeMachine() -> BurnBarMachineStatus {
        BurnBarMachineStatus(
            cpuPercent: 12.34,
            memoryUsedBytes: 8_000_000_000,
            memoryTotalBytes: 36_000_000_000,
            loadAverage: [1.5, 2.0, 2.5],
            diskFreeBytes: 512_000_000_000,
            thermal: .unavailable(reason: "No public thermal API"),
            power: .unavailable(reason: "No public power API")
        )
    }

    private func makeAgent(
        id: BurnBarFleetAgentID = .claudeCode,
        status: BurnBarFleetAgentStatus = .idle,
        confidence: BurnBarFleetConfidence = .logHeartbeat,
        projectName: String? = "Ajnunezg/BurnBar"
    ) -> BurnBarFleetAgent {
        BurnBarFleetAgent(
            id: id,
            displayName: id.wireValue,
            status: status,
            confidence: confidence,
            currentTask: status == .running ? "Reviewing PR #2336" : nil,
            projectName: projectName,
            model: "claude-fable-5",
            lastActivityAt: now.addingTimeInterval(-120),
            signals: [BurnBarFleetSignalSource(kind: "log-mtime", path: "/tmp/agent.log")],
            note: nil
        )
    }

    private func makeSnapshot(
        cadenceSeconds: Int = 15,
        agents: [BurnBarFleetAgent]? = nil
    ) -> BurnBarFleetSnapshot {
        let rows = agents ?? [
            makeAgent(id: .claudeCode, status: .running, confidence: .exactProcess),
            makeAgent(id: .codex, status: .idle)
        ]
        return BurnBarFleetSnapshot(
            generatedAt: now.addingTimeInterval(-5),
            cadenceSeconds: cadenceSeconds,
            machine: makeMachine(),
            agents: rows,
            repos: [
                BurnBarFleetRepoGroup(
                    projectName: "Ajnunezg/BurnBar",
                    agents: rows.map(\.id)
                )
            ],
            runningCount: rows.filter { $0.status == .running }.count,
            countsByAgent: [:],
            orchestrator: BurnBarOrchestratorState(designation: .none),
            probeHealth: [],
            persistenceHealth: .ok
        )
    }

    private func makeDocument(
        cadenceSeconds: Int = 15,
        agents: [BurnBarFleetAgent]? = nil,
        updatedAgo: TimeInterval
    ) -> FleetMirrorDocument {
        let snapshot = makeSnapshot(cadenceSeconds: cadenceSeconds, agents: agents)
        return FleetMirrorDocument(
            snapshot: snapshot,
            updatedAt: now.addingTimeInterval(-updatedAgo),
            generatedAt: snapshot.generatedAt
        )
    }

    // MARK: - State derivation

    func test_freshDocument_withRunningAgents_reachesReady() {
        let clock = TestClock(now)
        let store = makeStore(clock: clock)
        let document = makeDocument(updatedAgo: 30)

        store.apply(.decoded(document))

        XCTAssertEqual(store.state, .ready(document.snapshot))
        XCTAssertTrue(store.hasLoadedOnce)
        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.lastUpdatedAt, document.updatedAt)
        XCTAssertEqual(store.lastGeneratedAt, document.generatedAt)
    }

    func test_freshDocument_withZeroRunning_reachesEmptyWithTheSnapshot() {
        let clock = TestClock(now)
        let store = makeStore(clock: clock)
        let document = makeDocument(agents: [makeAgent(status: .idle)], updatedAgo: 30)

        store.apply(.decoded(document))

        XCTAssertEqual(store.state, .empty(document.snapshot))
    }

    /// The staleness contract: `updatedAt` older than
    /// `max(3 × cadenceSeconds, 15 minutes)` means the Mac stopped publishing.
    func test_staleUpdatedAt_reachesMacOffline() {
        let clock = TestClock(now)
        let store = makeStore(clock: clock)
        // Cadence 600s → threshold 1800s. 1900s old is offline.
        let document = makeDocument(cadenceSeconds: 600, updatedAgo: 1_900)

        store.apply(.decoded(document))

        XCTAssertEqual(store.state, .macOffline(lastUpdatedAt: document.updatedAt))
        // The provenance dates survive: "last heard from the Mac at X" is
        // exactly what the offline pane says.
        XCTAssertEqual(store.lastUpdatedAt, document.updatedAt)
    }

    func test_staleness_usesTheThreeCadenceThresholdWhenLargerThanTheFloor() {
        let clock = TestClock(now)
        let store = makeStore(clock: clock)
        // Cadence 600s → threshold 1800s. 1700s old is still fresh.
        let document = makeDocument(cadenceSeconds: 600, updatedAgo: 1_700)

        store.apply(.decoded(document))

        XCTAssertEqual(store.state, .ready(document.snapshot))
    }

    /// A short cadence must not declare the Mac offline the moment it naps:
    /// the 15-minute floor dominates 3× a small cadence.
    func test_staleness_fifteenMinuteFloor_keepsShortCadenceSnapshotsFresh() {
        let clock = TestClock(now)
        let store = makeStore(clock: clock)
        // Cadence 15s → 3× = 45s, but the floor is 900s. 500s old is fresh.
        let fresh = makeDocument(cadenceSeconds: 15, updatedAgo: 500)
        store.apply(.decoded(fresh))
        XCTAssertEqual(store.state, .ready(fresh.snapshot))

        // 901s old crosses the floor.
        let stale = makeDocument(cadenceSeconds: 15, updatedAgo: 901)
        store.apply(.decoded(stale))
        XCTAssertEqual(store.state, .macOffline(lastUpdatedAt: stale.updatedAt))
    }

    func test_offlineThreshold_clampsAtTheFloor() {
        XCTAssertEqual(MobileFleetStore.offlineThresholdSeconds(cadenceSeconds: 600), 1_800)
        XCTAssertEqual(MobileFleetStore.offlineThresholdSeconds(cadenceSeconds: 15), 900)
        XCTAssertEqual(MobileFleetStore.offlineThresholdSeconds(cadenceSeconds: -5), 900)
    }

    func test_missingDocument_reachesMacOfflineWithoutALastHeardDate() {
        let clock = TestClock(now)
        let store = makeStore(clock: clock)

        store.apply(.missing)

        XCTAssertEqual(store.state, .macOffline(lastUpdatedAt: nil))
        XCTAssertTrue(store.hasLoadedOnce, "A missing document is still an answer — the store must read warm")
        XCTAssertFalse(store.isLoading)
    }

    /// A document that was seen and then deleted must say when the Mac was
    /// last heard from — and the ticker must not resurrect the deleted board.
    func test_missingDocument_afterABoard_keepsTheLastHeardDateAndNeverResurrects() {
        let clock = TestClock(now)
        let store = makeStore(clock: clock)
        let document = makeDocument(updatedAgo: 30)
        store.apply(.decoded(document))

        store.apply(.missing)

        XCTAssertEqual(store.state, .macOffline(lastUpdatedAt: document.updatedAt))

        store.refreshDerivedState()
        XCTAssertEqual(
            store.state,
            .macOffline(lastUpdatedAt: document.updatedAt),
            "A re-derivation tick must not bring back a board the mirror no longer carries"
        )
    }

    // MARK: - Decode failures

    func test_decodeFailure_surfacesTheErrorWithoutFabricatingABoard() {
        let clock = TestClock(now)
        let store = makeStore(clock: clock)

        store.apply(.undecodable(reason: "vault key unavailable"))

        XCTAssertEqual(store.lastError, "vault key unavailable")
        XCTAssertEqual(
            store.state,
            .empty(nil),
            "The document exists — the Mac IS publishing — so macOffline would point at the wrong machine"
        )
        XCTAssertTrue(store.hasLoadedOnce)
    }

    func test_decodeFailure_neverBlanksAHealthyBoard() {
        let clock = TestClock(now)
        let store = makeStore(clock: clock)
        let document = makeDocument(updatedAgo: 30)
        store.apply(.decoded(document))

        store.apply(.undecodable(reason: "future schema"))

        XCTAssertEqual(store.state, .ready(document.snapshot), "One bad delivery must not blank a healthy board")
        XCTAssertEqual(store.lastError, "future schema")
    }

    /// The retained board is not immortal: with no readable writes arriving,
    /// its `updatedAt` keeps aging and the ticker must flip it offline.
    func test_retainedBoardAfterDecodeFailure_stillAgesToMacOffline() {
        let clock = TestClock(now)
        let store = makeStore(clock: clock)
        let document = makeDocument(cadenceSeconds: 15, updatedAgo: 30)
        store.apply(.decoded(document))
        store.apply(.undecodable(reason: "future schema"))
        XCTAssertEqual(store.state, .ready(document.snapshot))

        clock.now = now.addingTimeInterval(1_000)
        store.refreshDerivedState()

        XCTAssertEqual(store.state, .macOffline(lastUpdatedAt: document.updatedAt))
    }

    func test_successfulDecode_clearsAPriorError() {
        let clock = TestClock(now)
        let store = makeStore(clock: clock)
        store.apply(.undecodable(reason: "vault key unavailable"))

        store.apply(.decoded(makeDocument(updatedAgo: 30)))

        XCTAssertNil(store.lastError, "A readable write is the proof the previous failure no longer applies")
    }

    // MARK: - Re-derivation over time

    /// Firestore only calls back on writes, so the flip to `macOffline` must
    /// come from re-deriving the same document as the clock advances.
    func test_refreshDerivedState_flipsAQuietBoardToMacOfflineAsTimePasses() {
        let clock = TestClock(now)
        let store = makeStore(clock: clock)
        let document = makeDocument(cadenceSeconds: 15, updatedAgo: 30)
        store.apply(.decoded(document))
        XCTAssertEqual(store.state, .ready(document.snapshot))

        clock.now = now.addingTimeInterval(600)
        store.refreshDerivedState()
        XCTAssertEqual(store.state, .ready(document.snapshot), "630s old is inside the 900s floor")

        clock.now = now.addingTimeInterval(1_000)
        store.refreshDerivedState()
        XCTAssertEqual(store.state, .macOffline(lastUpdatedAt: document.updatedAt))
    }

    // MARK: - Sign-out

    func test_reset_dropsEveryTraceOfTheSignedOutAccount() {
        let clock = TestClock(now)
        let store = makeStore(clock: clock)
        store.apply(.decoded(makeDocument(updatedAgo: 30)))
        store.apply(.undecodable(reason: "later failure"))

        store.reset()

        XCTAssertEqual(store.state, .loading)
        XCTAssertNil(store.lastError)
        XCTAssertNil(store.lastUpdatedAt)
        XCTAssertNil(store.lastGeneratedAt)
        XCTAssertFalse(store.hasLoadedOnce)

        // The retained document must be gone too: a re-derivation tick after
        // reset must not resurrect the previous user's board.
        store.refreshDerivedState()
        XCTAssertEqual(store.state, .loading)
    }

    // MARK: - Codec round trip

    func test_decodeDocument_roundTripsASealedMirrorDocument() throws {
        let snapshot = makeSnapshot(cadenceSeconds: 60)
        let updatedAt = now
        let encoded = try FleetMirrorCodec.encodeSealed(
            snapshot,
            vaultKey: vaultKey,
            vaultKeyID: vaultKeyID,
            uid: uid,
            updatedAt: updatedAt
        )

        let decoded = try XCTUnwrap(
            MobileFleetStore.decodeDocument(
                documentID: FleetMirrorCodec.documentID,
                uid: uid,
                data: encoded,
                vaultKey: vaultKey
            )
        )

        XCTAssertEqual(decoded.updatedAt, updatedAt)
        XCTAssertEqual(decoded.snapshot.schemaVersion, snapshot.schemaVersion)
        XCTAssertEqual(decoded.snapshot.cadenceSeconds, 60)
        XCTAssertEqual(decoded.snapshot.runningCount, snapshot.runningCount)
        XCTAssertEqual(decoded.snapshot.agents.map(\.id), snapshot.agents.map(\.id))
        XCTAssertEqual(decoded.snapshot.agents.map(\.status), snapshot.agents.map(\.status))
    }

    /// The whole board is sealed — no plaintext fallback — so a device
    /// without the vault key must show no board rather than a fabricated one.
    func test_decodeDocument_withoutVaultKey_returnsNil() throws {
        let encoded = try FleetMirrorCodec.encodeSealed(
            makeSnapshot(),
            vaultKey: vaultKey,
            vaultKeyID: vaultKeyID,
            uid: uid,
            updatedAt: now
        )

        XCTAssertNil(
            MobileFleetStore.decodeDocument(
                documentID: FleetMirrorCodec.documentID,
                uid: uid,
                data: encoded,
                vaultKey: nil
            )
        )
    }

    func test_decodeDocument_withWrongVaultKey_returnsNil() throws {
        let encoded = try FleetMirrorCodec.encodeSealed(
            makeSnapshot(),
            vaultKey: vaultKey,
            vaultKeyID: vaultKeyID,
            uid: uid,
            updatedAt: now
        )

        XCTAssertNil(
            MobileFleetStore.decodeDocument(
                documentID: FleetMirrorCodec.documentID,
                uid: uid,
                data: encoded,
                vaultKey: Data(repeating: 0x11, count: 32)
            )
        )
    }

    // MARK: - Presentation: ordering

    /// The phone's single column promotes running rows; within each partition
    /// the daemon's payload order is preserved untouched.
    func test_orderedAgents_putRunningFirstPreservingPayloadOrder() {
        let agents = [
            makeAgent(id: .claudeCode, status: .idle),
            makeAgent(id: .codex, status: .running, confidence: .exactProcess),
            makeAgent(id: .hermes, status: .stale),
            makeAgent(id: .factoryDroid, status: .running, confidence: .activeSessionFile),
            makeAgent(id: .kimi, status: .unknown, confidence: .unsupported)
        ]

        let ordered = FleetAgentOrdering.runningFirst(agents)

        XCTAssertEqual(
            ordered.map(\.id),
            [.codex, .factoryDroid, .claudeCode, .hermes, .kimi]
        )
    }

    // MARK: - Presentation: header honesty

    /// A missing snapshot is never shown as "0 running" (VAL-DASH-028).
    func test_headerReadout_neverSaysZeroRunningWithoutASnapshot() {
        XCTAssertEqual(FleetHeaderCopy.readout(for: .loading), .checking)
        XCTAssertEqual(FleetHeaderCopy.readout(for: .macOffline(lastUpdatedAt: nil)), .unavailable)
        XCTAssertEqual(
            FleetHeaderCopy.readout(for: .empty(nil)),
            .unavailable,
            "An unreadable document has no snapshot — a zero would be invented"
        )

        let running = makeSnapshot()
        XCTAssertEqual(FleetHeaderCopy.readout(for: .ready(running)), .running(running.runningCount))

        let idle = makeSnapshot(agents: [makeAgent(status: .idle)])
        XCTAssertEqual(FleetHeaderCopy.readout(for: .empty(idle)), .running(0))

        XCTAssertEqual(FleetHeaderCopy.runningReadout(.checking), "Checking…")
        XCTAssertEqual(FleetHeaderCopy.runningReadout(.unavailable), "Unavailable")
        XCTAssertEqual(FleetHeaderCopy.runningReadout(.running(2)), "2 running")
    }

    // MARK: - Presentation: machine honesty

    /// Absent optional metrics are typed unavailable — never formatted as 0,
    /// NaN, or a current-looking value (VAL-DASH-011/030).
    func test_machineRows_neverFabricateAbsentMetrics() throws {
        let machine = BurnBarMachineStatus(
            memoryTotalBytes: 36_000_000_000,
            thermal: .unavailable(reason: "No public thermal API"),
            power: .available(value: 42.5)
        )

        let rows = FleetMachineRow.rows(for: machine)
        let byLabel = Dictionary(uniqueKeysWithValues: rows.map { ($0.label, $0) })

        for label in ["CPU", "Memory", "Load", "Disk free"] {
            let row = try XCTUnwrap(byLabel[label])
            XCTAssertNil(row.value, "\(label) is absent and must carry no value")
            XCTAssertTrue(row.isUnavailable)
            XCTAssertEqual(row.accessibilityLabel, "\(label): unavailable")
        }

        let thermal = try XCTUnwrap(byLabel["Thermal"])
        XCTAssertEqual(thermal.value, "Unavailable (No public thermal API)")
        XCTAssertTrue(thermal.isUnavailable)

        let power = try XCTUnwrap(byLabel["Power"])
        XCTAssertEqual(power.value, "42.5")
        XCTAssertFalse(power.isUnavailable)
    }

    func test_machineRows_formatPresentMetricsWithUnits() {
        let rows = FleetMachineRow.rows(for: makeMachine())
        let byLabel = Dictionary(uniqueKeysWithValues: rows.map { ($0.label, $0) })

        XCTAssertEqual(byLabel["CPU"]?.value, "12.3%")
        XCTAssertEqual(byLabel["Memory"]?.value, "8.0 GB / 36.0 GB")
        XCTAssertEqual(byLabel["Load"]?.value, "1.50, 2.00, 2.50")
        XCTAssertEqual(byLabel["Disk free"]?.value, "512.0 GB")
    }

    // MARK: - Presentation: repo grouping

    /// Agents with nil/empty projectName land in the explicit "No repo"
    /// bucket — never dropped (VAL-DASH-010).
    func test_repoGroupRows_keepAgentsWithoutARepoInTheNoRepoBucket() {
        let agents = [
            makeAgent(id: .claudeCode, projectName: "Ajnunezg/BurnBar"),
            makeAgent(id: .codex, projectName: nil),
            makeAgent(id: .hermes, projectName: "")
        ]
        let snapshot = BurnBarFleetSnapshot(
            generatedAt: now,
            cadenceSeconds: 15,
            machine: makeMachine(),
            agents: agents,
            repos: [
                BurnBarFleetRepoGroup(projectName: "Ajnunezg/BurnBar", agents: [.claudeCode])
            ],
            runningCount: 0,
            countsByAgent: [:],
            orchestrator: BurnBarOrchestratorState(designation: .none),
            probeHealth: [],
            persistenceHealth: .ok
        )

        let rows = FleetRepoGroupRowModel.rows(for: snapshot)

        XCTAssertEqual(rows.map(\.projectName), ["Ajnunezg/BurnBar", FleetRepoGroupRowModel.noRepoBucketName])
        XCTAssertEqual(rows.last?.agentIDs, [.codex, .hermes])
        XCTAssertEqual(rows.last?.count, 2)
    }
}

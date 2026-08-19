import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

/// Covers the four properties the fleet mirror must hold: gating (a disabled
/// preference or a signed-out account publishes nothing), the content-hash
/// watermark (an unchanged snapshot costs zero writes, a changed one
/// re-publishes), a silent skip when the daemon is down, and that a failed
/// write never advances the watermark — the next cycle retries the same bytes
/// rather than skipping work that never reached the cloud.
@MainActor
final class FleetSyncServiceTests: XCTestCase {
    private var dataStore: DataStore!
    private var accountManager: FakeAccountManager!
    private var settingsManager: SettingsManager!
    private var fakeGateway: CloudSyncFirestoreFakeGateway!
    private var context: CloudSyncContext!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!
    private var snapshotBox: Locked<BurnBarFleetSnapshot?>!

    private static let uid = "test-uid-1"
    private static let vaultKeyData = Data(repeating: 0x42, count: 32)

    private var documentPath: String { "users/\(Self.uid)/fleet_snapshot/current" }

    override func setUp() async throws {
        let queue = try DatabaseQueue()
        dataStore = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        accountManager = FakeAccountManager.makeSignedIn(uid: Self.uid)
        settingsManager = SettingsManager(defaults: UserDefaults(suiteName: "settings-\(UUID().uuidString)")!)
        fakeGateway = CloudSyncFirestoreFakeGateway()
        defaultsSuiteName = "fleet-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        snapshotBox = Locked<BurnBarFleetSnapshot?>(Self.makeSnapshot())
        context = CloudSyncContext(
            dataStore: dataStore,
            accountManager: accountManager,
            settingsManager: settingsManager,
            firestoreGateway: fakeGateway,
            // Single attempt so the write-failure test fails fast instead of
            // sleeping through exponential backoff.
            retryPolicy: CloudSyncRetryPolicy(maxAttempts: 1)
        )
    }

    override func tearDown() {
        if let defaultsSuiteName {
            UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
        }
        dataStore = nil
        accountManager = nil
        settingsManager = nil
        fakeGateway = nil
        context = nil
        defaults = nil
        defaultsSuiteName = nil
        snapshotBox = nil
        super.tearDown()
    }

    // MARK: - Publish

    func testPublishesSealedSnapshotDocument() async throws {
        let service = makeService()
        await service.sync()
        XCTAssertNil(service.lastSyncError)
        XCTAssertNotNil(service.lastSyncDate)

        let document = try XCTUnwrap(fakeGateway.documentData(at: documentPath))
        XCTAssertEqual(document["schemaVersion"] as? Int, 1)
        XCTAssertEqual(document["contentSealed"] as? Bool, true)
        XCTAssertEqual(document["sealedSchemaVersion"] as? Int, 2)
        XCTAssertNotNil(document["updatedAt"])
        XCTAssertNotNil(document["generatedAt"])
        // Every key written must be in the rules allowlist.
        XCTAssertEqual(Set(document.keys), Set(FleetMirrorCodec.documentKeys))

        // Nothing about the fleet may be legible in the document.
        let rendered = String(describing: document)
        XCTAssertFalse(rendered.contains("Refactor probe layer"), "task text leaked in cleartext")
        XCTAssertFalse(rendered.contains("claude-code"), "agent identity leaked in cleartext")

        // And the seal opens back to the exact snapshot that was published.
        let decoded = try XCTUnwrap(
            FleetMirrorCodec.decodeSealed(
                documentID: FleetMirrorCodec.documentID,
                uid: Self.uid,
                data: document,
                vaultKey: Self.vaultKeyData
            )
        )
        XCTAssertEqual(decoded.snapshot, snapshotBox.read())
    }

    // MARK: - Watermark

    func testUnchangedSecondSyncUploadsNothing() async throws {
        let service = makeService()
        await service.sync()
        XCTAssertNil(service.lastSyncError)

        let firstWrite = try XCTUnwrap(fakeGateway.documentData(at: documentPath))
        let firstSealed = try XCTUnwrap(firstWrite["sealedPayload"] as? [String: Any])
        let firstCiphertext = try XCTUnwrap(firstSealed["sealedBoxBase64"] as? String)

        await service.sync()

        // A fresh AES-GCM nonce per seal means an unsuppressed re-upload would
        // produce a DIFFERENT ciphertext — so comparing the sealed box proves
        // the watermark suppressed the write rather than merely overwriting it
        // with equal bytes.
        let secondWrite = try XCTUnwrap(fakeGateway.documentData(at: documentPath))
        let secondSealed = try XCTUnwrap(secondWrite["sealedPayload"] as? [String: Any])
        XCTAssertEqual(secondSealed["sealedBoxBase64"] as? String, firstCiphertext)
        XCTAssertNil(service.lastSyncError)
        XCTAssertNotNil(service.lastSyncDate, "a skipped-unchanged cycle still counts as a healthy sync")
    }

    func testChangedSnapshotRePublishes() async throws {
        let service = makeService()
        await service.sync()
        let firstCiphertext = try XCTUnwrap(
            (fakeGateway.documentData(at: documentPath)?["sealedPayload"] as? [String: Any])?["sealedBoxBase64"] as? String
        )

        // The daemon completed another tick with real changes.
        snapshotBox.write(Self.makeSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_755_600_060),
            currentTask: "Fix flaky sim tests"
        ))
        await service.sync()

        let document = try XCTUnwrap(fakeGateway.documentData(at: documentPath))
        let secondCiphertext = try XCTUnwrap((document["sealedPayload"] as? [String: Any])?["sealedBoxBase64"] as? String)
        XCTAssertNotEqual(secondCiphertext, firstCiphertext)
        XCTAssertNil(service.lastSyncError)
    }

    func testFailedWriteDoesNotAdvanceTheWatermark() async throws {
        let service = makeService()
        fakeGateway.nextError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])

        await service.sync()
        XCTAssertNotNil(service.lastSyncError)
        XCTAssertNil(fakeGateway.documentData(at: documentPath))
        XCTAssertNil(
            defaults.string(forKey: FleetSyncService.watermarkDefaultsKey(uid: Self.uid)),
            "a watermark persisted before the write commits would skip bytes that never reached the cloud"
        )

        // The transient fault clears; the SAME snapshot must now publish.
        fakeGateway.nextError = nil
        await service.sync()
        XCTAssertNil(service.lastSyncError)
        XCTAssertNotNil(fakeGateway.documentData(at: documentPath))
        XCTAssertNotNil(defaults.string(forKey: FleetSyncService.watermarkDefaultsKey(uid: Self.uid)))
    }

    // MARK: - Gates

    func testDisabledPreferenceUploadsNothing() async throws {
        defaults.set(false, forKey: FleetSyncService.preferenceKey)

        let service = makeService()
        await service.sync()

        XCTAssertNil(fakeGateway.documentData(at: documentPath))
        XCTAssertNil(service.lastSyncDate)
        XCTAssertNil(service.lastSyncError)
    }

    func testSignedOutUploadsNothing() async throws {
        accountManager.isSignedIn = false

        let service = makeService()
        await service.sync()

        XCTAssertNil(fakeGateway.documentData(at: documentPath))
        XCTAssertNil(service.lastSyncDate)
    }

    func testDaemonDownSkipsSilently() async throws {
        snapshotBox.write(nil)

        let service = makeService()
        await service.sync()

        // No snapshot is a normal state (daemon stopped, file absent) — not an
        // error, and not a sync the status surface should report as completed.
        XCTAssertNil(fakeGateway.documentData(at: documentPath))
        XCTAssertNil(service.lastSyncError)
        XCTAssertNil(service.lastSyncDate)
    }

    // MARK: - Helpers

    private func makeService() -> FleetSyncService {
        let box = snapshotBox!
        return FleetSyncService(
            context: context,
            vaultKeyProvider: TestConversationVaultKeyProvider(keyData: Self.vaultKeyData),
            defaults: defaults,
            fetchSnapshot: { box.read() }
        )
    }

    private static func makeSnapshot(
        generatedAt: Date = Date(timeIntervalSince1970: 1_755_600_000),
        currentTask: String = "Refactor probe layer"
    ) -> BurnBarFleetSnapshot {
        BurnBarFleetSnapshot(
            schemaVersion: 1,
            generatedAt: generatedAt,
            cadenceSeconds: 15,
            machine: BurnBarMachineStatus(
                cpuPercent: 12.5,
                memoryUsedBytes: 8_000_000_000,
                memoryTotalBytes: 48_000_000_000,
                loadAverage: [1.2, 1.0, 0.8],
                diskFreeBytes: 500_000_000_000,
                thermal: .unavailable(reason: "pmset thermlog empty"),
                power: .unavailable(reason: "no cheap power API")
            ),
            agents: [
                BurnBarFleetAgent(
                    id: .claudeCode,
                    displayName: "Claude Code",
                    status: .running,
                    confidence: .exactProcess,
                    currentTask: currentTask,
                    projectName: "/Users/albertonunez/Developer/AgentLens",
                    lastActivityAt: generatedAt,
                    signals: [
                        BurnBarFleetSignalSource(
                            kind: "session-registry",
                            path: "/Users/albertonunez/.claude/sessions/1.json"
                        )
                    ]
                )
            ],
            repos: [
                BurnBarFleetRepoGroup(
                    projectName: "/Users/albertonunez/Developer/AgentLens",
                    agents: [.claudeCode]
                )
            ],
            runningCount: 1,
            countsByAgent: ["claude-code": 1],
            orchestrator: BurnBarOrchestratorState(
                designation: .burnBarManaged,
                setAt: generatedAt,
                pendingDirectives: 0
            ),
            probeHealth: [
                BurnBarFleetProbeHealth(
                    agent: .claudeCode,
                    state: .ok,
                    rootPath: "/Users/albertonunez/.claude",
                    checkedAt: generatedAt
                )
            ],
            persistenceHealth: .ok
        )
    }
}

import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// Memory Blind Sync PR-2 — the device-sync gate: the sub-toggle, the backup
/// opt-in, the Data Vault entitlement, and the Remote Config fleet ceiling, all
/// fail-closed and persisted through the same settings coordinator
/// `MemoryCloudModelsSettingsTests` uses.
///
/// Every case here targets the EFFECTIVE gate — `SettingsManager.memoryDeviceSyncEnabled`,
/// what `MemoryCloudSyncDomain` consults before issuing a single `memory_facts`
/// read — and asserts the row's displayed value (`memoryDeviceSyncRowEnabled`)
/// alongside it, because the two are one computation (`MemoryDeviceSyncGate`)
/// and must never drift.
///
/// The entitlement lever is load-bearing on the client, not decoration:
/// `firestore.rules` gates `memory_facts` **writes** on
/// `hasActiveDataVaultEntitlement(userId)`, while **reads** are granted by the
/// per-user namespace rule with no entitlement check at all. That the gate
/// actually suppresses the network read is proved by
/// `MemoryCloudSyncDomainTests.test_sync_doesNotPull_whenTheDataVaultEntitlementIsAbsent`.
///
/// Run via: `./scripts/test-openburnbar-app.sh -only-testing:OpenBurnBarTests/MemoryDeviceSyncSettingsTests`.
@MainActor
final class MemoryDeviceSyncSettingsTests: XCTestCase {

    private func makeDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "\(Self.self)-\(UUID().uuidString)"))
    }

    // MARK: - Pure gate matrix

    func testTheEffectiveGateIsFailClosedAcrossTheMatrix() {
        for deviceSyncOptIn in [false, true] {
            for backupOptIn in [false, true] {
                for entitlementSatisfied in [false, true] {
                    for remoteConfigEnabled in [false, true] {
                        XCTAssertEqual(
                            MemoryDeviceSyncGate.isEnabled(
                                deviceSyncOptIn: deviceSyncOptIn,
                                backupOptIn: backupOptIn,
                                entitlementSatisfied: entitlementSatisfied,
                                remoteConfigEnabled: remoteConfigEnabled
                            ),
                            deviceSyncOptIn && backupOptIn && entitlementSatisfied && remoteConfigEnabled,
                            "deviceSyncOptIn=\(deviceSyncOptIn) backupOptIn=\(backupOptIn) "
                                + "entitlementSatisfied=\(entitlementSatisfied) remoteConfigEnabled=\(remoteConfigEnabled)"
                        )
                    }
                }
            }
        }
    }

    func testEverySingleLeverOffReadsFalseWithEveryOtherLeverOn() {
        XCTAssertFalse(MemoryDeviceSyncGate.isEnabled(
            deviceSyncOptIn: false, backupOptIn: true, entitlementSatisfied: true, remoteConfigEnabled: true
        ), "sub-toggle off alone must close the gate")
        XCTAssertFalse(MemoryDeviceSyncGate.isEnabled(
            deviceSyncOptIn: true, backupOptIn: false, entitlementSatisfied: true, remoteConfigEnabled: true
        ), "backup opt-in off alone must close the gate")
        XCTAssertFalse(MemoryDeviceSyncGate.isEnabled(
            deviceSyncOptIn: true, backupOptIn: true, entitlementSatisfied: false, remoteConfigEnabled: true
        ), "missing entitlement alone must close the gate")
        XCTAssertFalse(MemoryDeviceSyncGate.isEnabled(
            deviceSyncOptIn: true, backupOptIn: true, entitlementSatisfied: true, remoteConfigEnabled: false
        ), "the Remote Config fleet ceiling alone must close the gate")
        XCTAssertTrue(MemoryDeviceSyncGate.isEnabled(
            deviceSyncOptIn: true, backupOptIn: true, entitlementSatisfied: true, remoteConfigEnabled: true
        ), "every lever on must open the gate")
    }

    // MARK: - SettingsManager integration

    func testFreshSettingsAreDormant() throws {
        let manager = makeSettingsManager(defaults: try makeDefaults())
        XCTAssertFalse(manager.memory.deviceSyncEnabled, "the sub-toggle defaults off")
        XCTAssertFalse(manager.memory.deviceSyncEntitlementSatisfied, "the entitlement snapshot defaults unresolved")
        XCTAssertFalse(manager.memoryDeviceSyncOptIn)
        XCTAssertFalse(manager.memoryDeviceSyncEnabled)
        XCTAssertFalse(manager.memoryDeviceSyncRowUnlocked)
        XCTAssertFalse(manager.memoryDeviceSyncRowEnabled)
    }

    func testSubToggleSettingsPersistAcrossInstances() throws {
        let defaults = try makeDefaults()
        let first = makeSettingsManager(defaults: defaults)
        first.memoryDeviceSyncOptIn = true
        first.persistence.flush()

        let second = makeSettingsManager(defaults: defaults)
        XCTAssertTrue(second.memoryDeviceSyncOptIn, "the sub-toggle persists through the settings coordinator")
        // Still closed: entitlement is never persisted, so a fresh process must
        // re-resolve it before the pull can run or the row can read on, even
        // with the sub-toggle already true on disk.
        XCTAssertFalse(second.memoryDeviceSyncEnabled)
        XCTAssertFalse(second.memoryDeviceSyncRowEnabled)
    }

    func testEntitlementIsNotPersisted() throws {
        let defaults = try makeDefaults()
        let first = makeSettingsManager(defaults: defaults)
        first.memoryApprovedCloudBackupOptIn = true
        first.memoryDeviceSyncOptIn = true
        first.memoryDeviceSyncEntitlementSatisfied = true
        XCTAssertTrue(first.memoryDeviceSyncEnabled)
        XCTAssertTrue(first.memoryDeviceSyncRowEnabled)
        first.persistence.flush()

        let persistedKeys = defaults.dictionaryRepresentation().keys.map { $0.lowercased() }
        XCTAssertFalse(
            persistedKeys.contains { $0.contains("devicesyncentitlement") },
            "the entitlement snapshot must never be written to disk"
        )
        XCTAssertTrue(persistedKeys.contains("memorydevicesyncenabled"))
        XCTAssertTrue(persistedKeys.contains("memoryapprovedcloudbackupenabled"))

        let second = makeSettingsManager(defaults: defaults)
        XCTAssertTrue(second.memoryDeviceSyncOptIn, "the sub-toggle survived the relaunch")
        XCTAssertTrue(second.memoryApprovedCloudBackupOptIn, "the backup opt-in survived the relaunch")
        XCTAssertFalse(second.memoryDeviceSyncEntitlementSatisfied, "entitlement is re-resolved fresh, never restored from disk")
        XCTAssertFalse(second.memoryDeviceSyncEnabled, "an unresolved entitlement must leave the pull gate closed on relaunch")
        XCTAssertFalse(second.memoryDeviceSyncRowEnabled, "a stale, unresolved entitlement snapshot must never read as satisfied")
    }

    func testTurningBackupOptInOffClosesTheEffectiveGateEvenWithTheSubToggleOn() throws {
        let manager = makeSettingsManager(defaults: try makeDefaults())
        manager.memoryApprovedCloudBackupOptIn = true
        manager.memoryDeviceSyncOptIn = true
        manager.memoryDeviceSyncEntitlementSatisfied = true
        XCTAssertTrue(manager.memoryDeviceSyncEnabled)
        XCTAssertTrue(manager.memoryDeviceSyncRowEnabled)
        XCTAssertTrue(manager.memoryDeviceSyncRowUnlocked)

        manager.memoryApprovedCloudBackupOptIn = false
        XCTAssertTrue(manager.memoryDeviceSyncOptIn, "the sub-toggle itself is untouched")
        XCTAssertFalse(manager.memoryDeviceSyncEnabled, "the backup opt-in going off must close the effective gate")
        XCTAssertFalse(manager.memoryDeviceSyncRowEnabled)
        XCTAssertFalse(manager.memoryDeviceSyncRowUnlocked)
    }

    func testMissingEntitlementClosesTheEffectiveGateEvenWithBackupAndSubToggleOn() throws {
        let manager = makeSettingsManager(defaults: try makeDefaults())
        manager.memoryApprovedCloudBackupOptIn = true
        manager.memoryDeviceSyncOptIn = true
        XCTAssertFalse(manager.memoryDeviceSyncEntitlementSatisfied, "still unresolved / not entitled")
        XCTAssertFalse(
            manager.memoryDeviceSyncEnabled,
            "no entitlement ⇒ the pull gate the domain reads is closed, so no memory_facts read is issued"
        )
        XCTAssertFalse(manager.memoryDeviceSyncRowEnabled)
        XCTAssertFalse(manager.memoryDeviceSyncRowUnlocked)

        manager.memoryDeviceSyncEntitlementSatisfied = true
        XCTAssertTrue(manager.memoryDeviceSyncEnabled)
        XCTAssertTrue(manager.memoryDeviceSyncRowEnabled)
        XCTAssertTrue(manager.memoryDeviceSyncRowUnlocked)
    }

    func testRemoteConfigFleetCeilingClosesTheEffectiveGate() throws {
        let manager = makeSettingsManager(defaults: try makeDefaults())
        manager.memoryApprovedCloudBackupOptIn = true
        manager.memoryDeviceSyncOptIn = true
        manager.memoryDeviceSyncEntitlementSatisfied = true
        XCTAssertTrue(manager.memoryDeviceSyncEnabled)
        XCTAssertTrue(manager.memoryDeviceSyncRowEnabled)

        manager.memoryExtractionRemoteConfigEnabled = false
        XCTAssertFalse(manager.memoryDeviceSyncEnabled, "the fleet ceiling clamps the pull gate")
        XCTAssertFalse(manager.memoryDeviceSyncRowEnabled, "the fleet ceiling clamps the row too")
        // The backup gate itself already folds the same ceiling, so it also closes.
        XCTAssertFalse(manager.memoryApprovedCloudBackupEnabled)
        XCTAssertFalse(manager.memoryDeviceSyncRowUnlocked)
    }

    func testRowUnlockedExcludesTheSubToggleItself() throws {
        // A member who has satisfied every OTHER lever must still be free to
        // flip the sub-toggle: rowUnlocked must not itself depend on the raw
        // sub-toggle value.
        let manager = makeSettingsManager(defaults: try makeDefaults())
        manager.memoryApprovedCloudBackupOptIn = true
        manager.memoryDeviceSyncEntitlementSatisfied = true
        XCTAssertFalse(manager.memoryDeviceSyncOptIn, "sub-toggle still off")
        XCTAssertTrue(manager.memoryDeviceSyncRowUnlocked, "unlocked is independent of the sub-toggle")
        XCTAssertFalse(manager.memoryDeviceSyncEnabled, "but the effective gate stays closed until the sub-toggle is on")
        XCTAssertFalse(manager.memoryDeviceSyncRowEnabled, "and the row reads off to match")
    }
}

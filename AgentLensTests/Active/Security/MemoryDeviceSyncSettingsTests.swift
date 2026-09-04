import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// Memory Blind Sync PR-2 — the device-sync ROW's presentation gate: the
/// sub-toggle, the backup opt-in, the Data Vault entitlement, and the Remote
/// Config fleet ceiling, all fail-closed and persisted through the same
/// settings coordinator `MemoryCloudModelsSettingsTests` uses.
///
/// `SettingsManager.memoryDeviceSyncEnabled` (backup gate AND sub-toggle,
/// entitlement-free — what `MemoryCloudSyncDomain` actually consults to run
/// the pull) is covered by `MemoryCloudSyncDomainTests` and is intentionally
/// untouched here: the entitlement is independently enforced server-side by
/// `firestore.rules` on every `memory_facts` read, so this suite covers only
/// the row's own presentation gate, `memoryDeviceSyncRowEnabled` /
/// `MemoryDeviceSyncGate`.
///
/// Run via: `./scripts/test-openburnbar-app.sh -only-testing:OpenBurnBarTests/MemoryDeviceSyncSettingsTests`.
@MainActor
final class MemoryDeviceSyncSettingsTests: XCTestCase {

    private func makeDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "\(Self.self)-\(UUID().uuidString)"))
    }

    // MARK: - Pure gate matrix

    func testRowGateIsFailClosedAcrossTheMatrix() {
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
        // re-resolve it before the row can read on, even with the sub-toggle
        // already true on disk.
        XCTAssertFalse(second.memoryDeviceSyncRowEnabled)
    }

    func testEntitlementIsNotPersisted() throws {
        let defaults = try makeDefaults()
        let first = makeSettingsManager(defaults: defaults)
        first.memoryApprovedCloudBackupOptIn = true
        first.memoryDeviceSyncOptIn = true
        first.memoryDeviceSyncEntitlementSatisfied = true
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
        XCTAssertFalse(second.memoryDeviceSyncRowEnabled, "a stale, unresolved entitlement snapshot must never read as satisfied")
    }

    func testTurningBackupOptInOffClosesTheEffectiveGateEvenWithTheSubToggleOn() throws {
        let manager = makeSettingsManager(defaults: try makeDefaults())
        manager.memoryApprovedCloudBackupOptIn = true
        manager.memoryDeviceSyncOptIn = true
        manager.memoryDeviceSyncEntitlementSatisfied = true
        XCTAssertTrue(manager.memoryDeviceSyncRowEnabled)
        XCTAssertTrue(manager.memoryDeviceSyncRowUnlocked)

        manager.memoryApprovedCloudBackupOptIn = false
        XCTAssertTrue(manager.memoryDeviceSyncOptIn, "the sub-toggle itself is untouched")
        XCTAssertFalse(manager.memoryDeviceSyncRowEnabled, "the backup opt-in going off must close the effective gate")
        XCTAssertFalse(manager.memoryDeviceSyncRowUnlocked)
    }

    func testMissingEntitlementClosesTheRowEvenWithBackupAndSubToggleOn() throws {
        let manager = makeSettingsManager(defaults: try makeDefaults())
        manager.memoryApprovedCloudBackupOptIn = true
        manager.memoryDeviceSyncOptIn = true
        XCTAssertFalse(manager.memoryDeviceSyncEntitlementSatisfied, "still unresolved / not entitled")
        XCTAssertFalse(manager.memoryDeviceSyncRowEnabled)
        XCTAssertFalse(manager.memoryDeviceSyncRowUnlocked)

        manager.memoryDeviceSyncEntitlementSatisfied = true
        XCTAssertTrue(manager.memoryDeviceSyncRowEnabled)
        XCTAssertTrue(manager.memoryDeviceSyncRowUnlocked)
    }

    func testRemoteConfigFleetCeilingClosesTheRow() throws {
        let manager = makeSettingsManager(defaults: try makeDefaults())
        manager.memoryApprovedCloudBackupOptIn = true
        manager.memoryDeviceSyncOptIn = true
        manager.memoryDeviceSyncEntitlementSatisfied = true
        XCTAssertTrue(manager.memoryDeviceSyncRowEnabled)

        manager.memoryExtractionRemoteConfigEnabled = false
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
        XCTAssertFalse(manager.memoryDeviceSyncRowEnabled, "but the full gate still reads off until the sub-toggle is on")
    }
}

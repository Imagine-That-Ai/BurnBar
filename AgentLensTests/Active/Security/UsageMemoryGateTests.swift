import XCTest
@testable import OpenBurnBar

/// U1: usage-memory gate lattice (consent + fleet kill switches + cloud gate).
///
/// Invariants under test:
///  - **Dormancy:** every default is chosen so the feature is FULLY dormant out
///    of the box — no consent, no extraction, no cloud egress, placement local.
///  - **Extraction gate:** usage extraction is enabled only when the user has
///    consented *and* the `memory_usage_extraction_enabled` fleet switch allows
///    it (fail-closed).
///  - **Cloud gate:** cloud curation additionally requires the separate cloud
///    consent *and* a cloud model placement; `.local` placement means zero
///    cloud egress even with both consents granted.
///  - **Registry:** settings changes propagate synchronously into both
///    `UsageMemoryKillSwitchRegistry` lanes (extraction / authority writes).
///
/// Run via: `./scripts/test-openburnbar-app.sh` (normalizes to `OpenBurnBarTests`).
@MainActor
final class UsageMemoryGateTests: XCTestCase {

    private func makeDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "\(Self.self)-\(UUID().uuidString)"))
    }

    // MARK: - Pure extraction gate (full matrix)

    func testExtractionGateEnabledOnlyWhenBothLeversOn() {
        XCTAssertTrue(UsageMemoryExtractionGate.isEnabled(usageConsentGranted: true, remoteConfigEnabled: true))
    }

    func testExtractionGateDisabledWhenConsentMissing() {
        // Consent is the outermost lever: without it the usage loop is dormant
        // even with the fleet switch allowing extraction.
        XCTAssertFalse(UsageMemoryExtractionGate.isEnabled(usageConsentGranted: false, remoteConfigEnabled: true))
    }

    func testExtractionGateDisabledWhenRemoteConfigKills() {
        XCTAssertFalse(UsageMemoryExtractionGate.isEnabled(usageConsentGranted: true, remoteConfigEnabled: false))
    }

    func testExtractionGateDisabledWhenAllOff() {
        XCTAssertFalse(UsageMemoryExtractionGate.isEnabled(usageConsentGranted: false, remoteConfigEnabled: false))
    }

    // MARK: - Pure cloud gate (full matrix)

    func testCloudGateEnabledOnlyWhenAllThreeLeversOn() {
        XCTAssertTrue(
            UsageMemoryCloudGate.isEnabled(extractionEnabled: true, cloudConsentGranted: true, placementIsCloud: true)
        )
    }

    func testCloudGateFullMatrixIsFailClosed() {
        // Every combination except (true, true, true) must be OFF.
        for extraction in [false, true] {
            for cloudConsent in [false, true] {
                for placementIsCloud in [false, true] {
                    let expected = extraction && cloudConsent && placementIsCloud
                    XCTAssertEqual(
                        UsageMemoryCloudGate.isEnabled(
                            extractionEnabled: extraction,
                            cloudConsentGranted: cloudConsent,
                            placementIsCloud: placementIsCloud
                        ),
                        expected,
                        "extraction=\(extraction) cloudConsent=\(cloudConsent) placementIsCloud=\(placementIsCloud)"
                    )
                }
            }
        }
    }

    // MARK: - Model placement

    func testOnlyLocalPlacementIsNotCloud() {
        XCTAssertFalse(UsageMemoryModelPlacement.local.isCloud)
        XCTAssertTrue(UsageMemoryModelPlacement.cloudText.isCloud)
        XCTAssertTrue(UsageMemoryModelPlacement.burnbarCloud.isCloud)
    }

    // MARK: - Dormancy defaults

    func testFreshSettingsAreFullyDormant() throws {
        let settings = SettingsManager(defaults: try makeDefaults())
        XCTAssertFalse(settings.usageMemoryConsentGranted, "Usage consent defaults OFF.")
        XCTAssertFalse(settings.usageMemoryConsentShown, "Consent prompt starts unshown.")
        XCTAssertFalse(settings.usageMemoryCloudCurationConsentGranted, "Cloud-curation consent defaults OFF.")
        XCTAssertEqual(settings.usageMemoryModelPlacement, .local, "Placement defaults to on-device.")
        XCTAssertTrue(settings.usageMemorySourceSafariAsksEnabled, "Safari-asks source defaults ON (inert without consent).")
        XCTAssertTrue(settings.usageMemorySourceAgentSessionsEnabled, "Agent-sessions source defaults ON (inert without consent).")
        XCTAssertTrue(settings.usageMemoryExtractionRemoteConfigEnabled, "RC extraction switch defaults allowed (true).")
        XCTAssertTrue(settings.usageMemoryAuthorityWritesRemoteConfigEnabled, "RC authority-writes switch defaults allowed (true).")
        XCTAssertFalse(settings.usageMemoryExtractionEnabled, "Combined extraction gate is DORMANT until consent.")
        XCTAssertFalse(settings.usageMemoryCloudCurationEnabled, "Combined cloud gate is DORMANT out of the box.")
    }

    // MARK: - SettingsManager levers

    func testGrantingConsentEnablesExtractionAndMarksShown() throws {
        let settings = SettingsManager(defaults: try makeDefaults())
        settings.usageMemoryConsentGranted = true
        XCTAssertTrue(settings.usageMemoryExtractionEnabled, "Granting consent (fleet switch allowing) opens the gate.")
        XCTAssertTrue(settings.usageMemoryConsentShown, "Granting consent implies the prompt was shown.")
    }

    func testRemoteConfigKillSwitchDisablesExtractionDespiteConsent() throws {
        let settings = SettingsManager(defaults: try makeDefaults())
        settings.usageMemoryConsentGranted = true
        settings.usageMemoryExtractionRemoteConfigEnabled = false
        XCTAssertFalse(settings.usageMemoryExtractionEnabled, "A fleet kill must halt usage extraction even with consent.")
    }

    func testCloudGateStaysClosedWithLocalPlacementEvenWithBothConsents() throws {
        let settings = SettingsManager(defaults: try makeDefaults())
        settings.usageMemoryConsentGranted = true
        settings.usageMemoryCloudCurationConsentGranted = true
        XCTAssertEqual(settings.usageMemoryModelPlacement, .local)
        XCTAssertFalse(
            settings.usageMemoryCloudCurationEnabled,
            "Local placement means zero cloud egress even with both consents granted."
        )

        settings.usageMemoryModelPlacement = .cloudText
        XCTAssertTrue(settings.usageMemoryCloudCurationEnabled, "Cloud placement + both consents opens the cloud gate.")

        settings.usageMemoryModelPlacement = .local
        XCTAssertFalse(settings.usageMemoryCloudCurationEnabled, "Returning to local placement closes the cloud gate.")
    }

    func testCloudGateRequiresCloudConsentEvenWithCloudPlacement() throws {
        let settings = SettingsManager(defaults: try makeDefaults())
        settings.usageMemoryConsentGranted = true
        settings.usageMemoryModelPlacement = .burnbarCloud
        XCTAssertFalse(
            settings.usageMemoryCloudCurationEnabled,
            "Extraction consent alone never authorizes cloud curation."
        )
    }

    // MARK: - Registry propagation (two lanes)

    func testConsentPropagatesIntoExtractionLaneImmediately() throws {
        let extractionSwitch = MemoryExtractionKillSwitch()
        UsageMemoryKillSwitchRegistry.registerExtraction(extractionSwitch, initiallyAllowed: false)
        let settings = SettingsManager(defaults: try makeDefaults())
        XCTAssertFalse(extractionSwitch.isAllowed(), "Fresh settings keep the extraction lane CLOSED.")

        settings.usageMemoryConsentGranted = true
        XCTAssertTrue(extractionSwitch.isAllowed(), "Granting consent opens the registered extraction lane.")

        settings.usageMemoryExtractionRemoteConfigEnabled = false
        XCTAssertFalse(extractionSwitch.isAllowed(), "A fleet kill closes the extraction lane immediately.")

        settings.usageMemoryExtractionRemoteConfigEnabled = true
        XCTAssertTrue(extractionSwitch.isAllowed())
        settings.usageMemoryConsentGranted = false
        XCTAssertFalse(extractionSwitch.isAllowed(), "Revoking consent closes the extraction lane.")
    }

    func testAuthorityWritesLaneFollowsItsOwnRemoteConfigSwitch() throws {
        let authoritySwitch = MemoryExtractionKillSwitch()
        UsageMemoryKillSwitchRegistry.registerAuthorityWrites(authoritySwitch, initiallyAllowed: false)
        let settings = SettingsManager(defaults: try makeDefaults())
        XCTAssertTrue(
            authoritySwitch.isAllowed(),
            "Init propagation pushes the RC authority-writes default (true) into the lane."
        )

        settings.usageMemoryAuthorityWritesRemoteConfigEnabled = false
        XCTAssertFalse(authoritySwitch.isAllowed(), "The authority-writes fleet kill closes its lane immediately.")

        // The authority lane is independent of consent/extraction.
        settings.usageMemoryConsentGranted = true
        XCTAssertFalse(authoritySwitch.isAllowed(), "Consent never reopens a killed authority-writes lane.")

        settings.usageMemoryAuthorityWritesRemoteConfigEnabled = true
        XCTAssertTrue(authoritySwitch.isAllowed())
    }

    func testExtractionLaneIndependentOfAuthorityWritesKill() throws {
        let extractionSwitch = MemoryExtractionKillSwitch()
        UsageMemoryKillSwitchRegistry.registerExtraction(extractionSwitch, initiallyAllowed: false)
        let settings = SettingsManager(defaults: try makeDefaults())
        settings.usageMemoryConsentGranted = true
        XCTAssertTrue(extractionSwitch.isAllowed())

        settings.usageMemoryAuthorityWritesRemoteConfigEnabled = false
        XCTAssertTrue(extractionSwitch.isAllowed(), "Killing authority writes must not close the extraction lane.")
    }

    // MARK: - Persistence

    func testUsageSettingsPersistAcrossInstances() throws {
        let defaults = try makeDefaults()
        let settings = SettingsManager(defaults: defaults)
        settings.usageMemoryConsentGranted = true
        settings.usageMemoryCloudCurationConsentGranted = true
        settings.usageMemoryModelPlacement = .burnbarCloud
        settings.usageMemorySourceSafariAsksEnabled = false
        // The coordinator debounces writes (~100 ms); flush synchronously so the
        // reloaded instance observes the persisted values.
        settings.persistence.flush()

        let reloaded = SettingsManager(defaults: defaults)
        XCTAssertTrue(reloaded.usageMemoryConsentGranted)
        XCTAssertTrue(reloaded.usageMemoryConsentShown, "Granted-implies-shown must persist.")
        XCTAssertTrue(reloaded.usageMemoryCloudCurationConsentGranted)
        XCTAssertEqual(reloaded.usageMemoryModelPlacement, .burnbarCloud)
        XCTAssertFalse(reloaded.usageMemorySourceSafariAsksEnabled)
        XCTAssertTrue(reloaded.usageMemorySourceAgentSessionsEnabled, "Untouched source toggle keeps its default.")
    }

    func testRemoteConfigFieldsAreNotPersisted() throws {
        let defaults = try makeDefaults()
        let settings = SettingsManager(defaults: defaults)
        settings.usageMemoryExtractionRemoteConfigEnabled = false
        settings.usageMemoryAuthorityWritesRemoteConfigEnabled = false
        settings.persistence.flush()

        let reloaded = SettingsManager(defaults: defaults)
        XCTAssertTrue(
            reloaded.usageMemoryExtractionRemoteConfigEnabled,
            "The RC extraction switch is session-scoped; a relaunch re-defaults to allowed."
        )
        XCTAssertTrue(
            reloaded.usageMemoryAuthorityWritesRemoteConfigEnabled,
            "The RC authority-writes switch is session-scoped; a relaunch re-defaults to allowed."
        )
    }
}

import XCTest
@testable import OpenBurnBar

/// U1: usage-memory gate lattice (consent + fleet kill switches + cloud gate).
///
/// Invariants under test:
///  - **Dormancy:** every default is chosen so the feature is FULLY dormant out
///    of the box — no consent, no extraction, no cloud egress, placement local.
///  - **Extraction gate:** usage extraction is enabled only when the user has
///    consented *and* the `memory_usage_extraction_enabled` fleet switch allows
///    it *and* that fleet value has been resolved (fail-closed).
///  - **Cached fleet kills win at init:** the session-scoped RC fields default
///    to the optimistic `true`, so both lanes are held CLOSED until a Remote
///    Config value is applied. A cached `false` seeded at init keeps the lane
///    shut even for a returning user who already granted consent.
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

    /// A manager whose usage lanes have been resolved by an allowing fleet config,
    /// i.e. the steady state after a successful Remote Config read. Tests that are
    /// about consent/placement rather than resolution start here.
    ///
    /// The seed is always injected (never left to the Firebase-backed default) so
    /// these assertions do not depend on whether the test host happens to have a
    /// configured `FirebaseApp` with an activated config on disk.
    private func makeResolvedSettings(defaults: UserDefaults) -> SettingsManager {
        SettingsManager(
            defaults: defaults,
            usageMemoryRemoteConfigSeed: {
                UsageMemoryRemoteConfigSnapshot(extractionEnabled: true, authorityWritesEnabled: true)
            }
        )
    }

    /// A manager with no fleet value resolved yet — the launch window before
    /// Remote Config has been read.
    private func makeUnresolvedSettings(defaults: UserDefaults) -> SettingsManager {
        SettingsManager(defaults: defaults, usageMemoryRemoteConfigSeed: { nil })
    }

    // MARK: - Pure extraction gate (full matrix)

    func testExtractionGateFullMatrixIsFailClosed() {
        // Only (consent, fleet-allows, resolved) all true opens the gate.
        for consent in [false, true] {
            for remoteConfigEnabled in [false, true] {
                for resolved in [false, true] {
                    XCTAssertEqual(
                        UsageMemoryExtractionGate.isEnabled(
                            usageConsentGranted: consent,
                            remoteConfigEnabled: remoteConfigEnabled,
                            remoteConfigResolved: resolved
                        ),
                        consent && remoteConfigEnabled && resolved,
                        "consent=\(consent) rc=\(remoteConfigEnabled) resolved=\(resolved)"
                    )
                }
            }
        }
    }

    func testExtractionGateClosedWhileRemoteConfigUnresolvedDespiteConsent() {
        // The startup window: consent granted, RC field still on its optimistic
        // default, nothing resolved yet -> CLOSED.
        XCTAssertFalse(
            UsageMemoryExtractionGate.isEnabled(
                usageConsentGranted: true,
                remoteConfigEnabled: true,
                remoteConfigResolved: false
            ),
            "An unresolved fleet switch must never ride its default into an open gate."
        )
    }

    func testAuthorityWriteGateFullMatrixIsFailClosed() {
        for remoteConfigEnabled in [false, true] {
            for resolved in [false, true] {
                XCTAssertEqual(
                    UsageMemoryAuthorityWriteGate.isEnabled(
                        remoteConfigEnabled: remoteConfigEnabled,
                        remoteConfigResolved: resolved
                    ),
                    remoteConfigEnabled && resolved,
                    "rc=\(remoteConfigEnabled) resolved=\(resolved)"
                )
            }
        }
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
        let settings = makeUnresolvedSettings(defaults: try makeDefaults())
        XCTAssertFalse(settings.usageMemoryConsentGranted, "Usage consent defaults OFF.")
        XCTAssertFalse(settings.usageMemoryConsentShown, "Consent prompt starts unshown.")
        XCTAssertFalse(settings.usageMemoryCloudCurationConsentGranted, "Cloud-curation consent defaults OFF.")
        XCTAssertEqual(settings.usageMemoryModelPlacement, .local, "Placement defaults to on-device.")
        XCTAssertTrue(settings.usageMemorySourceSafariAsksEnabled, "Safari-asks source defaults ON (inert without consent).")
        XCTAssertTrue(settings.usageMemorySourceAgentSessionsEnabled, "Agent-sessions source defaults ON (inert without consent).")
        XCTAssertTrue(settings.usageMemoryExtractionRemoteConfigEnabled, "RC extraction switch defaults allowed (true).")
        XCTAssertTrue(settings.usageMemoryAuthorityWritesRemoteConfigEnabled, "RC authority-writes switch defaults allowed (true).")
        XCTAssertFalse(settings.usageMemoryRemoteConfigResolved, "No fleet value has been read yet.")
        XCTAssertFalse(settings.usageMemoryExtractionEnabled, "Combined extraction gate is DORMANT until consent.")
        XCTAssertFalse(
            settings.usageMemoryAuthorityWritesEnabled,
            "The authority-write lane stays shut until a fleet value resolves it."
        )
        XCTAssertFalse(settings.usageMemoryCloudCurationEnabled, "Combined cloud gate is DORMANT out of the box.")
    }

    // MARK: - Cached fleet kills beat consent at init (review PRRT_kwDORtgQYs6ZgTEJ)

    func testCachedFleetKillIsHonoredAtInitDespitePersistedConsent() throws {
        let defaults = try makeDefaults()
        // A returning user who granted usage consent in a previous launch.
        let granting = makeResolvedSettings(defaults: defaults)
        granting.usageMemoryConsentGranted = true
        granting.persistence.flush()

        let extractionSwitch = MemoryExtractionKillSwitch()
        let authoritySwitch = MemoryExtractionKillSwitch()
        UsageMemoryKillSwitchRegistry.registerExtraction(extractionSwitch, initiallyAllowed: false)
        UsageMemoryKillSwitchRegistry.registerAuthorityWrites(authoritySwitch, initiallyAllowed: false)

        // Relaunch with a CACHED fleet kill sitting in the active Remote Config.
        let reloaded = SettingsManager(
            defaults: defaults,
            usageMemoryRemoteConfigSeed: {
                UsageMemoryRemoteConfigSnapshot(extractionEnabled: false, authorityWritesEnabled: false)
            }
        )
        XCTAssertTrue(reloaded.usageMemoryConsentGranted, "Consent is still persisted.")
        XCTAssertTrue(reloaded.usageMemoryRemoteConfigResolved, "The cached snapshot resolved the lanes.")
        XCTAssertFalse(
            reloaded.usageMemoryExtractionEnabled,
            "A cached fleet kill must beat persisted consent at init — no open-then-close window."
        )
        XCTAssertFalse(
            extractionSwitch.isAllowed(),
            "The worker-facing extraction lane must never observe the pre-RC open state."
        )
        XCTAssertFalse(authoritySwitch.isAllowed(), "The authority-write lane honors its own cached kill at init.")
    }

    func testLanesStayClosedUntilRemoteConfigResolvesEvenWithConsent() throws {
        let extractionSwitch = MemoryExtractionKillSwitch()
        let authoritySwitch = MemoryExtractionKillSwitch()
        UsageMemoryKillSwitchRegistry.registerExtraction(extractionSwitch, initiallyAllowed: false)
        UsageMemoryKillSwitchRegistry.registerAuthorityWrites(authoritySwitch, initiallyAllowed: false)

        // Firebase not configured yet: no snapshot, so nothing is resolved.
        let settings = makeUnresolvedSettings(defaults: try makeDefaults())
        settings.usageMemoryConsentGranted = true
        XCTAssertFalse(
            settings.usageMemoryExtractionEnabled,
            "Consent alone cannot open the gate while the fleet value is unread."
        )
        XCTAssertFalse(extractionSwitch.isAllowed(), "Extraction lane held CLOSED pre-resolution.")
        XCTAssertFalse(authoritySwitch.isAllowed(), "Authority-write lane held CLOSED pre-resolution.")

        // Writing the raw RC field is NOT a resolution — it cannot open a lane.
        settings.usageMemoryExtractionRemoteConfigEnabled = true
        settings.usageMemoryAuthorityWritesRemoteConfigEnabled = true
        XCTAssertFalse(settings.usageMemoryExtractionEnabled, "A raw RC write does not resolve the lanes.")
        XCTAssertFalse(extractionSwitch.isAllowed())
        XCTAssertFalse(authoritySwitch.isAllowed())

        // The refresh applying an allowing config is what opens them.
        settings.applyUsageMemoryRemoteConfig(extractionEnabled: true, authorityWritesEnabled: true)
        XCTAssertTrue(settings.usageMemoryExtractionEnabled, "An applied allowing fleet config opens the gate.")
        XCTAssertTrue(extractionSwitch.isAllowed())
        XCTAssertTrue(authoritySwitch.isAllowed())
    }

    func testRelaunchStartsUnresolvedSoResolutionIsNeverInherited() throws {
        let defaults = try makeDefaults()
        let settings = makeResolvedSettings(defaults: defaults)
        settings.usageMemoryConsentGranted = true
        XCTAssertTrue(settings.usageMemoryRemoteConfigResolved)
        settings.persistence.flush()

        let reloaded = makeUnresolvedSettings(defaults: defaults)
        XCTAssertFalse(
            reloaded.usageMemoryRemoteConfigResolved,
            "Resolution is session-scoped: every launch re-reads the fleet value."
        )
        XCTAssertFalse(reloaded.usageMemoryExtractionEnabled, "…so a relaunch starts closed even with consent.")
    }

    // MARK: - SettingsManager levers

    func testGrantingConsentEnablesExtractionAndMarksShown() throws {
        let settings = makeResolvedSettings(defaults: try makeDefaults())
        settings.usageMemoryConsentGranted = true
        XCTAssertTrue(settings.usageMemoryExtractionEnabled, "Granting consent (fleet switch allowing) opens the gate.")
        XCTAssertTrue(settings.usageMemoryConsentShown, "Granting consent implies the prompt was shown.")
    }

    func testRemoteConfigKillSwitchDisablesExtractionDespiteConsent() throws {
        let settings = makeResolvedSettings(defaults: try makeDefaults())
        settings.usageMemoryConsentGranted = true
        settings.applyUsageMemoryRemoteConfig(extractionEnabled: false, authorityWritesEnabled: true)
        XCTAssertFalse(settings.usageMemoryExtractionEnabled, "A fleet kill must halt usage extraction even with consent.")
    }

    func testCloudGateStaysClosedWithLocalPlacementEvenWithBothConsents() throws {
        let settings = makeResolvedSettings(defaults: try makeDefaults())
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
        let settings = makeResolvedSettings(defaults: try makeDefaults())
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
        let settings = makeResolvedSettings(defaults: try makeDefaults())
        XCTAssertFalse(extractionSwitch.isAllowed(), "Fresh settings keep the extraction lane CLOSED.")

        settings.usageMemoryConsentGranted = true
        XCTAssertTrue(extractionSwitch.isAllowed(), "Granting consent opens the registered extraction lane.")

        settings.applyUsageMemoryRemoteConfig(extractionEnabled: false, authorityWritesEnabled: true)
        XCTAssertFalse(extractionSwitch.isAllowed(), "A fleet kill closes the extraction lane immediately.")

        settings.applyUsageMemoryRemoteConfig(extractionEnabled: true, authorityWritesEnabled: true)
        XCTAssertTrue(extractionSwitch.isAllowed())
        settings.usageMemoryConsentGranted = false
        XCTAssertFalse(extractionSwitch.isAllowed(), "Revoking consent closes the extraction lane.")
    }

    func testAuthorityWritesLaneFollowsItsOwnRemoteConfigSwitch() throws {
        let authoritySwitch = MemoryExtractionKillSwitch()
        UsageMemoryKillSwitchRegistry.registerAuthorityWrites(authoritySwitch, initiallyAllowed: false)
        let settings = makeResolvedSettings(defaults: try makeDefaults())
        XCTAssertTrue(
            authoritySwitch.isAllowed(),
            "Init propagation pushes the RESOLVED authority-writes value into the lane."
        )

        settings.applyUsageMemoryRemoteConfig(extractionEnabled: true, authorityWritesEnabled: false)
        XCTAssertFalse(authoritySwitch.isAllowed(), "The authority-writes fleet kill closes its lane immediately.")

        // The authority lane is independent of consent/extraction.
        settings.usageMemoryConsentGranted = true
        XCTAssertFalse(authoritySwitch.isAllowed(), "Consent never reopens a killed authority-writes lane.")

        settings.applyUsageMemoryRemoteConfig(extractionEnabled: true, authorityWritesEnabled: true)
        XCTAssertTrue(authoritySwitch.isAllowed())
    }

    func testExtractionLaneIndependentOfAuthorityWritesKill() throws {
        let extractionSwitch = MemoryExtractionKillSwitch()
        UsageMemoryKillSwitchRegistry.registerExtraction(extractionSwitch, initiallyAllowed: false)
        let settings = makeResolvedSettings(defaults: try makeDefaults())
        settings.usageMemoryConsentGranted = true
        XCTAssertTrue(extractionSwitch.isAllowed())

        settings.applyUsageMemoryRemoteConfig(extractionEnabled: true, authorityWritesEnabled: false)
        XCTAssertTrue(extractionSwitch.isAllowed(), "Killing authority writes must not close the extraction lane.")
    }

    // MARK: - Persistence

    func testUsageSettingsPersistAcrossInstances() throws {
        let defaults = try makeDefaults()
        let settings = makeResolvedSettings(defaults: defaults)
        settings.usageMemoryConsentGranted = true
        settings.usageMemoryCloudCurationConsentGranted = true
        settings.usageMemoryModelPlacement = .burnbarCloud
        settings.usageMemorySourceSafariAsksEnabled = false
        // The coordinator debounces writes (~100 ms); flush synchronously so the
        // reloaded instance observes the persisted values.
        settings.persistence.flush()

        let reloaded = makeResolvedSettings(defaults: defaults)
        XCTAssertTrue(reloaded.usageMemoryConsentGranted)
        XCTAssertTrue(reloaded.usageMemoryConsentShown, "Granted-implies-shown must persist.")
        XCTAssertTrue(reloaded.usageMemoryCloudCurationConsentGranted)
        XCTAssertEqual(reloaded.usageMemoryModelPlacement, .burnbarCloud)
        XCTAssertFalse(reloaded.usageMemorySourceSafariAsksEnabled)
        XCTAssertTrue(reloaded.usageMemorySourceAgentSessionsEnabled, "Untouched source toggle keeps its default.")
    }

    func testRemoteConfigFieldsAreNotPersisted() throws {
        let defaults = try makeDefaults()
        let settings = makeResolvedSettings(defaults: defaults)
        settings.applyUsageMemoryRemoteConfig(extractionEnabled: false, authorityWritesEnabled: false)
        settings.persistence.flush()

        let reloaded = makeUnresolvedSettings(defaults: defaults)
        XCTAssertTrue(
            reloaded.usageMemoryExtractionRemoteConfigEnabled,
            "The RC extraction switch is session-scoped; a relaunch re-defaults to allowed."
        )
        XCTAssertTrue(
            reloaded.usageMemoryAuthorityWritesRemoteConfigEnabled,
            "The RC authority-writes switch is session-scoped; a relaunch re-defaults to allowed."
        )
        XCTAssertFalse(
            reloaded.usageMemoryRemoteConfigResolved,
            "…and those defaults are inert: nothing is resolved, so no lane is open."
        )
    }

    // MARK: - Granted-implies-shown across init (review PRRT_kwDORtgQYs6ZgTEL)

    func testTornConsentStateIsRepairedOnLoad() throws {
        let defaults = try makeDefaults()
        // Simulate a torn write: granted persisted, shown never made it to disk
        // (a crash between the coordinator's separate debounced flushes).
        // `normalizeConsentShownInvariants()` must repair it regardless of whether
        // `@Observable`'s rewrite happens to run `didSet` for init assignments.
        defaults.set(true, forKey: "usageMemoryConsentGranted")
        defaults.set(false, forKey: "usageMemoryConsentShown")
        defaults.set(true, forKey: "memoryConsentGranted")
        defaults.set(false, forKey: "memoryConsentShown")

        let settings = makeResolvedSettings(defaults: defaults)
        XCTAssertTrue(
            settings.usageMemoryConsentShown,
            "A persisted usage grant implies the prompt was shown — never re-prompt a consenting user."
        )
        XCTAssertTrue(settings.memoryConsentShown, "Same invariant for the chat consent pair.")

        // The repair is durable, not just in-memory.
        settings.persistence.flush()
        XCTAssertTrue(defaults.bool(forKey: "usageMemoryConsentShown"), "The repair is persisted.")
        XCTAssertTrue(defaults.bool(forKey: "memoryConsentShown"), "The repair is persisted.")
    }

    func testMissingShownKeyWithGrantedConsentIsRepairedOnLoad() throws {
        let defaults = try makeDefaults()
        // The other torn shape: the shown key is absent entirely, so the load
        // guard never runs and the property keeps its `false` default.
        defaults.set(true, forKey: "usageMemoryConsentGranted")

        let settings = makeResolvedSettings(defaults: defaults)
        XCTAssertTrue(settings.usageMemoryConsentGranted)
        XCTAssertTrue(settings.usageMemoryConsentShown, "An absent shown key must not re-prompt a consenting user.")
    }

    func testDeclinedConsentStaysShownWithoutGranting() throws {
        let defaults = try makeDefaults()
        // The user saw the prompt and declined: shown true, granted false. The
        // normalization must not invent consent from a shown prompt.
        defaults.set(false, forKey: "usageMemoryConsentGranted")
        defaults.set(true, forKey: "usageMemoryConsentShown")

        let settings = makeResolvedSettings(defaults: defaults)
        XCTAssertFalse(settings.usageMemoryConsentGranted, "Shown never implies granted — the implication is one-way.")
        XCTAssertTrue(settings.usageMemoryConsentShown)
        XCTAssertFalse(settings.usageMemoryExtractionEnabled, "A declined prompt leaves the usage loop dormant.")
    }
}

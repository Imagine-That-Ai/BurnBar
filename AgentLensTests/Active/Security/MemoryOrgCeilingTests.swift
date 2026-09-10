import XCTest
import OpenBurnBarKernel
@testable import OpenBurnBar

/// D17: the organization memory ceiling, in the shipped fleet-ceiling shape.
///
/// What each invariant is guarding, and what breaks if it is reverted:
///
///  * **Closed until resolved.** The ceiling is what says *which* kinds an
///    organization gates, so a device that never resolved one cannot answer the
///    question and must not guess. Reverting
///    `hasResolvedOrgMemoryRemoteConfig` out of the gate opens the org lane on
///    every never-fetched device — the failure `MemorySettings`'
///    `hasResolvedUsageRemoteConfig` already exists to prevent.
///  * **Offline counts as resolved.** Firebase's active *cached* config is a
///    real ceiling. A device with no network must use it rather than sit closed
///    forever, which is why the seed is read synchronously at init.
///  * **Member-local memory is a separate lane.** It is asserted here against
///    the REAL member gate (`MemoryExtractionGate` and the kill-switch registry
///    it drives), not a parallel type invented for the test, so an org lever
///    accidentally ANDed into the member lane fails this file.
///  * **The deny matrix.** Every combination of consent × resolution ×
///    org-enabled × kind, compared against an expectation written
///    independently of the gate's own expression.
///  * **No freshness lever.** KD12 introduces no max-age. The gate taking no
///    `now` is compiler-enforced, so
///    `test_the_org_ceiling_carries_nothing_a_freshness_lever_could_lapse_against`
///    pins the half a test can: the ceiling payload carries no instant and no
///    interval for a reintroduced max-age to measure against.
@MainActor
final class MemoryOrgCeilingTests: XCTestCase {

    /// COUPLING: `MemoryKind` (`OpenBurnBarKernel/Memory/MemoryServing.swift`)
    /// is not `CaseIterable`, so this list is hand-maintained and a seventh
    /// case would silently escape the deny matrix below. Making it
    /// `CaseIterable` is a Core change and belongs to D16, which is the first
    /// consumer that has to enumerate kinds for real; until then, a new
    /// `MemoryKind` case must be added here in the same commit.
    private static let allKinds: [MemoryKind] = [
        .fact, .preference, .event, .profile, .relationship, .other
    ]

    private func makeDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "\(Self.self)-\(UUID().uuidString)"))
    }

    private func openCeiling(
        kinds: Set<String> = Set(MemoryOrgCeilingTests.allKinds.map(\.rawValue))
    ) -> OrgMemoryRemoteConfigSnapshot {
        OrgMemoryRemoteConfigSnapshot(orgMemoryEnabled: true, allowedKinds: kinds)
    }

    // MARK: - Closed until resolved

    func test_an_unresolved_org_ceiling_closes_the_org_lane() throws {
        let manager = makeSettingsManager(
            defaults: try makeDefaults(),
            orgMemoryRemoteConfigSeed: { nil }
        )
        let memory = manager.memory

        XCTAssertFalse(memory.hasResolvedOrgMemoryRemoteConfig)
        XCTAssertNil(memory.orgMemoryCeiling)
        XCTAssertFalse(memory.isOrgMemorySyncAllowed())

        // Consent alone must not open it. This is the whole point: the member
        // said yes, but nobody has told this device what the organization
        // permits, so there is nothing to say yes *to*.
        memory.orgMemoryConsentGranted = true
        XCTAssertTrue(memory.orgMemoryConsentGranted)
        XCTAssertFalse(memory.hasResolvedOrgMemoryRemoteConfig)
        XCTAssertFalse(
            memory.isOrgMemorySyncAllowed(),
            "An unresolved organization ceiling must hold the org lane CLOSED, not default it open"
        )

        for kind in Self.allKinds {
            XCTAssertFalse(
                memory.isOrgMemoryKindAllowed(kind),
                "\(kind.rawValue) must be denied on the org lane while no ceiling has resolved"
            )
        }

        // …and it stays closed even against a ceiling that would have allowed
        // everything, so long as that ceiling was never APPLIED.
        XCTAssertFalse(
            OrgMemoryCeilingGate.isSyncAllowed(
                consentGranted: true,
                remoteConfigResolved: false,
                ceiling: openCeiling()
            )
        )
    }

    func test_applying_a_ceiling_is_the_only_thing_that_resolves_the_org_lane() throws {
        let manager = makeSettingsManager(
            defaults: try makeDefaults(),
            orgMemoryRemoteConfigSeed: { nil }
        )
        let memory = manager.memory
        memory.orgMemoryConsentGranted = true
        XCTAssertFalse(memory.isOrgMemorySyncAllowed())

        memory.applyOrgMemoryRemoteConfig(openCeiling(kinds: ["fact"]))

        XCTAssertTrue(memory.hasResolvedOrgMemoryRemoteConfig)
        XCTAssertTrue(memory.isOrgMemorySyncAllowed())
        XCTAssertTrue(memory.isOrgMemoryKindAllowed(.fact))
        XCTAssertFalse(memory.isOrgMemoryKindAllowed(.preference))
    }

    // MARK: - Offline

    func test_an_offline_cached_ceiling_counts_as_resolved() throws {
        // The seed closure is the "read Firebase's ACTIVE CACHED config,
        // synchronously, before any network call" path. Nothing here awaits a
        // fetch, which is exactly the offline case.
        let cached = OrgMemoryRemoteConfigSnapshot(
            orgMemoryEnabled: true,
            allowedKinds: ["fact", "preference"]
        )
        let manager = makeSettingsManager(
            defaults: try makeDefaults(),
            orgMemoryRemoteConfigSeed: { cached }
        )
        let memory = manager.memory

        XCTAssertTrue(memory.hasResolvedOrgMemoryRemoteConfig)
        XCTAssertEqual(memory.orgMemoryCeiling, cached)

        // Resolved is not consented: the member's own lever is still required.
        XCTAssertFalse(memory.isOrgMemorySyncAllowed())
        memory.orgMemoryConsentGranted = true
        XCTAssertTrue(memory.isOrgMemorySyncAllowed())

        XCTAssertTrue(memory.isOrgMemoryKindAllowed(.fact))
        XCTAssertTrue(memory.isOrgMemoryKindAllowed(.preference))
        XCTAssertFalse(
            memory.isOrgMemoryKindAllowed(.event),
            "A kind outside the organization's allowlist is denied even on a resolved, open ceiling"
        )
    }

    func test_the_org_ceiling_carries_nothing_a_freshness_lever_could_lapse_against() throws {
        // KD12: no client-side max-age. The gate's SIGNATURE taking no `now` is
        // enforced by the compiler and needs no test; what a test can pin is
        // the DATA half, which is where a reintroduced freshness lever would
        // have to start. A max-age gate needs a fetch stamp on the payload to
        // measure against — the exact field this branch cut — so this asserts
        // the ceiling carries no instant and no interval at all. Adding
        // `fetchedAt`/`maxAge` back fails here on a real assertion, not on a
        // compile error, and a `now: Date = Date()` parameter added on top of a
        // stampless ceiling still has nothing to lapse.
        let ceiling = openCeiling()
        for child in Mirror(reflecting: ceiling).children {
            let label = child.label ?? "<unlabelled>"
            XCTAssertFalse(
                child.value is Date,
                "\(label): a ceiling with an instant on it is a ceiling something can age"
            )
            XCTAssertFalse(
                child.value is TimeInterval,
                "\(label): a ceiling with a duration on it is a ceiling something can lapse"
            )
        }
        XCTAssertEqual(
            Set(Mirror(reflecting: ceiling).children.compactMap(\.label)),
            ["orgMemoryEnabled", "allowedKinds"],
            "The ceiling is the organization's policy and nothing else; a new field needs its own doctrine"
        )

        // And the behavioural half: state alone decides. Two ceilings that are
        // `==` but were applied at different moments must answer identically,
        // which is what lets D16 cache the answer instead of re-asking.
        let manager = makeSettingsManager(
            defaults: try makeDefaults(),
            orgMemoryRemoteConfigSeed: { nil }
        )
        let memory = manager.memory
        memory.orgMemoryConsentGranted = true

        memory.applyOrgMemoryRemoteConfig(OrgMemoryRemoteConfigSnapshot(
            orgMemoryEnabled: true,
            allowedKinds: ["fact"]
        ))
        let firstSync = memory.isOrgMemorySyncAllowed()
        let firstKind = memory.isOrgMemoryKindAllowed(.fact)
        XCTAssertTrue(firstSync)
        XCTAssertTrue(firstKind)

        // Re-resolved later with an equal-valued ceiling built independently.
        memory.applyOrgMemoryRemoteConfig(OrgMemoryRemoteConfigSnapshot(
            orgMemoryEnabled: true,
            allowedKinds: ["fact"]
        ))
        XCTAssertEqual(
            memory.isOrgMemorySyncAllowed(),
            firstSync,
            "Equal ceilings must answer equally: when a ceiling was resolved is not a lever"
        )
        XCTAssertEqual(memory.isOrgMemoryKindAllowed(.fact), firstKind)
        XCTAssertFalse(
            memory.isOrgMemoryKindAllowed(.event),
            "The allowlist still decides; re-resolving an equal ceiling widens nothing"
        )
    }

    func test_resolving_to_no_published_ceiling_is_resolved_and_still_closed() throws {
        // The state the old API could not express at all: Remote Config
        // ANSWERED, and this organization publishes no memory ceiling. That
        // resolves the lane — the device is no longer pretending it never
        // asked — and still closes it, because an organization that published
        // nothing permitted nothing. It is also the one state in which
        // `hasResolvedOrgMemoryRemoteConfig` is not `orgMemoryCeiling != nil`
        // restated.
        let manager = makeSettingsManager(
            defaults: try makeDefaults(),
            orgMemoryRemoteConfigSeed: { nil }
        )
        let memory = manager.memory
        memory.orgMemoryConsentGranted = true

        memory.applyOrgMemoryRemoteConfig(nil)

        XCTAssertTrue(memory.hasResolvedOrgMemoryRemoteConfig)
        XCTAssertNil(memory.orgMemoryCeiling)
        XCTAssertFalse(memory.isOrgMemorySyncAllowed())
        for kind in Self.allKinds {
            XCTAssertFalse(
                memory.isOrgMemoryKindAllowed(kind),
                "\(kind.rawValue) must be denied when the organization published no ceiling at all"
            )
        }
    }

    // MARK: - Member-local lane

    func test_member_local_memory_works_with_no_ceiling_at_all() throws {
        let manager = makeSettingsManager(
            defaults: try makeDefaults(),
            orgMemoryRemoteConfigSeed: { nil }
        )
        let memory = manager.memory

        // The REAL member lane, observed through the switch the extraction
        // workers actually read. Held strongly: the registry keeps weak refs.
        let memberSwitch = MemoryExtractionKillSwitch(initiallyAllowed: false)
        MemoryExtractionKillSwitchRegistry.register(memberSwitch, initiallyAllowed: false)

        memory.consentGranted = true
        memory.automaticExtraction = true

        XCTAssertFalse(memory.hasResolvedOrgMemoryRemoteConfig)
        XCTAssertNil(memory.orgMemoryCeiling)
        XCTAssertFalse(memory.isOrgMemorySyncAllowed())
        XCTAssertTrue(
            memberSwitch.isAllowed(),
            "Member-local extraction must run with no organization ceiling in existence"
        )
        XCTAssertTrue(
            MemoryExtractionGate.isEnabled(
                consentGranted: memory.consentGranted,
                automaticExtraction: memory.automaticExtraction,
                remoteConfigEnabled: memory.remoteConfigExtractionEnabled
            )
        )
    }

    func test_a_denying_org_ceiling_does_not_touch_the_member_lane() throws {
        let manager = makeSettingsManager(
            defaults: try makeDefaults(),
            orgMemoryRemoteConfigSeed: { nil }
        )
        let memory = manager.memory

        let memberSwitch = MemoryExtractionKillSwitch(initiallyAllowed: false)
        MemoryExtractionKillSwitchRegistry.register(memberSwitch, initiallyAllowed: false)
        memory.consentGranted = true
        memory.automaticExtraction = true
        XCTAssertTrue(memberSwitch.isAllowed())

        // Every way the org lane can slam shut, one after another. None of them
        // may move the member lane.
        memory.orgMemoryConsentGranted = true
        memory.applyOrgMemoryRemoteConfig(
            OrgMemoryRemoteConfigSnapshot(orgMemoryEnabled: false, allowedKinds: [])
        )
        XCTAssertFalse(memory.isOrgMemorySyncAllowed())
        XCTAssertTrue(memberSwitch.isAllowed(), "An organization DENY must not brick member-local memory")

        memory.applyOrgMemoryRemoteConfig(nil)
        XCTAssertFalse(memory.isOrgMemorySyncAllowed())
        XCTAssertTrue(
            memberSwitch.isAllowed(),
            "An organization that publishes NO ceiling must not brick member-local memory either"
        )

        memory.orgMemoryConsentGranted = false
        XCTAssertFalse(memory.isOrgMemorySyncAllowed())
        XCTAssertTrue(memberSwitch.isAllowed(), "Withdrawing ORG consent must not withdraw member consent")
    }

    // MARK: - Consent bookkeeping

    func test_granting_org_consent_implies_its_prompt_was_shown() throws {
        let defaults = try makeDefaults()
        let manager = makeSettingsManager(defaults: defaults)
        XCTAssertFalse(manager.memory.orgMemoryConsentShown)

        manager.memory.orgMemoryConsentGranted = true
        XCTAssertTrue(manager.memory.orgMemoryConsentShown)

        // And the invariant is repaired on load, not only on write: a store
        // carrying granted-without-shown comes back consistent.
        defaults.set(true, forKey: "orgMemoryConsentGranted")
        defaults.set(false, forKey: "orgMemoryConsentShown")
        manager.persistence.flush()
        let reloaded = makeSettingsManager(defaults: defaults)
        XCTAssertTrue(reloaded.memory.orgMemoryConsentGranted)
        XCTAssertTrue(reloaded.memory.orgMemoryConsentShown)
    }

    func test_the_org_lane_starts_closed_again_after_a_relaunch() throws {
        let defaults = try makeDefaults()
        let first = makeSettingsManager(
            defaults: defaults,
            orgMemoryRemoteConfigSeed: { nil }
        )
        first.memory.orgMemoryConsentGranted = true
        first.memory.applyOrgMemoryRemoteConfig(openCeiling())
        XCTAssertTrue(first.memory.isOrgMemorySyncAllowed())

        // Resolution is deliberately not persisted, so a relaunch that cannot
        // reach Remote Config re-opens nothing. Consent, which is the member's
        // own durable choice, survives.
        first.persistence.flush()
        let relaunched = makeSettingsManager(
            defaults: defaults,
            orgMemoryRemoteConfigSeed: { nil }
        )
        XCTAssertTrue(relaunched.memory.orgMemoryConsentGranted)
        XCTAssertFalse(relaunched.memory.hasResolvedOrgMemoryRemoteConfig)
        XCTAssertFalse(relaunched.memory.isOrgMemorySyncAllowed())
    }

    // MARK: - Deny matrix

    func test_org_gated_kinds_are_denied_per_ceiling() {
        let allowed: Set<String> = ["fact", "event"]

        for consent in [false, true] {
            for resolved in [false, true] {
                for orgEnabled in [false, true] {
                    let ceiling = OrgMemoryRemoteConfigSnapshot(
                        orgMemoryEnabled: orgEnabled,
                        allowedKinds: allowed
                    )
                    let label = "consent=\(consent) resolved=\(resolved) orgEnabled=\(orgEnabled)"

                    // The expectation is written from the invariants, not from
                    // the gate's expression, so this is a comparison and not a
                    // restatement.
                    let expectedLaneOpen = consent && resolved && orgEnabled
                    XCTAssertEqual(
                        OrgMemoryCeilingGate.isSyncAllowed(
                            consentGranted: consent,
                            remoteConfigResolved: resolved,
                            ceiling: ceiling
                        ),
                        expectedLaneOpen,
                        label
                    )

                    for kind in Self.allKinds {
                        XCTAssertEqual(
                            OrgMemoryCeilingGate.isKindAllowed(
                                kind: kind,
                                consentGranted: consent,
                                remoteConfigResolved: resolved,
                                ceiling: ceiling
                            ),
                            expectedLaneOpen && allowed.contains(kind.rawValue),
                            "kind=\(kind.rawValue) \(label)"
                        )
                    }
                }
            }
        }
    }

    func test_a_missing_ceiling_denies_every_kind_however_the_other_levers_stand() {
        for consent in [false, true] {
            for resolved in [false, true] {
                XCTAssertFalse(
                    OrgMemoryCeilingGate.isSyncAllowed(
                        consentGranted: consent,
                        remoteConfigResolved: resolved,
                        ceiling: nil
                    ),
                    "consent=\(consent) resolved=\(resolved) with no ceiling at all"
                )
                for kind in Self.allKinds {
                    XCTAssertFalse(
                        OrgMemoryCeilingGate.isKindAllowed(
                            kind: kind,
                            consentGranted: consent,
                            remoteConfigResolved: resolved,
                            ceiling: nil
                        )
                    )
                }
            }
        }
    }

    func test_an_empty_allowlist_denies_every_kind_on_an_otherwise_open_lane() {
        let ceiling = OrgMemoryRemoteConfigSnapshot(orgMemoryEnabled: true, allowedKinds: [])
        XCTAssertTrue(
            OrgMemoryCeilingGate.isSyncAllowed(
                consentGranted: true,
                remoteConfigResolved: true,
                ceiling: ceiling
            ),
            "The lane itself is open — it is the allowlist that is empty"
        )
        for kind in Self.allKinds {
            XCTAssertFalse(
                OrgMemoryCeilingGate.isKindAllowed(
                    kind: kind,
                    consentGranted: true,
                    remoteConfigResolved: true,
                    ceiling: ceiling
                ),
                "\(kind.rawValue) rides in on nothing: the allowlist is an allowlist"
            )
        }
    }
}

import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// D17 / P23: Organization memory Remote Config ceiling gate.
///
/// Invariants under test:
///  - **Closed until resolved:** the org lane is held CLOSED until an organization
///    Remote Config snapshot is applied (at init from cache, or activated).
///  - **Offline cached ceiling:** an offline-cached snapshot resolves immediately at init
///    without waiting for network.
///  - **Member lane isolation:** member-local memory operates on its own separate lane,
///    never ANDed with the org ceiling. It functions fully with no org ceiling at all.
///  - **Ceiling deny matrix:** kinds permitted by the org ceiling allowlist are respected;
///    unlisted kinds or a disabled org ceiling deny sync fail-closed.
@MainActor
final class MemoryOrgCeilingTests: XCTestCase {

    private func makeDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "\(Self.self)-\(UUID().uuidString)"))
    }

    func test_an_unresolved_org_ceiling_closes_the_org_lane() throws {
        let defaults = try makeDefaults()
        let manager = SettingsManager(
            defaults: defaults,
            orgMemoryRemoteConfigSeed: { nil }
        )

        // Fresh instance: unresolved out of the box
        XCTAssertFalse(manager.memory.orgCeilingResolved)
        XCTAssertNil(manager.memory.orgCeilingSnapshot)
        XCTAssertFalse(manager.memory.isOrgMemorySyncAllowed)

        // Member grants org consent, but ceiling has not resolved yet -> STILL CLOSED
        manager.memory.orgConsentGranted = true
        XCTAssertTrue(manager.memory.orgConsentGranted)
        XCTAssertFalse(manager.memory.orgCeilingResolved)
        XCTAssertFalse(manager.memory.isOrgMemorySyncAllowed, "Unresolved org ceiling must structurally hold org lane CLOSED")

        // Gated kinds are also denied while unresolved
        for kind in [MemoryKind.fact, .preference, .event, .profile, .relationship, .other] {
            XCTAssertFalse(
                manager.memory.isOrgKindAllowed(kind),
                "Kind \(kind.rawValue) must be denied when org ceiling is unresolved"
            )
        }

        // Pure gate check
        XCTAssertFalse(
            OrgMemoryCeilingGate.isOrgSyncAllowed(
                orgConsentGranted: true,
                remoteConfigResolved: false,
                snapshot: OrgMemoryRemoteConfigSnapshot(orgSyncEnabled: true)
            )
        )
    }

    func test_an_offline_cached_ceiling_counts_as_resolved() throws {
        let defaults = try makeDefaults()
        let cachedSnapshot = OrgMemoryRemoteConfigSnapshot(
            orgSyncEnabled: true,
            allowedKinds: ["fact", "preference"]
        )

        let manager = SettingsManager(
            defaults: defaults,
            orgMemoryRemoteConfigSeed: { cachedSnapshot }
        )

        // Immediately resolved from the active cached seed
        XCTAssertTrue(manager.memory.orgCeilingResolved)
        XCTAssertEqual(manager.memory.orgCeilingSnapshot, cachedSnapshot)

        // Org lane opens once user grants affirmative consent
        XCTAssertFalse(manager.memory.isOrgMemorySyncAllowed, "Consent still required")
        manager.memory.orgConsentGranted = true
        XCTAssertTrue(manager.memory.isOrgMemorySyncAllowed)

        // Allowed kinds in the snapshot are permitted
        XCTAssertTrue(manager.memory.isOrgKindAllowed(.fact))
        XCTAssertTrue(manager.memory.isOrgKindAllowed(.preference))
        XCTAssertFalse(manager.memory.isOrgKindAllowed(.event))
    }

    func test_member_local_memory_works_with_no_ceiling_at_all() throws {
        let defaults = try makeDefaults()
        // No org ceiling seed at all
        let manager = SettingsManager(
            defaults: defaults,
            orgMemoryRemoteConfigSeed: { nil }
        )

        XCTAssertFalse(manager.memory.orgCeilingResolved)
        XCTAssertNil(manager.memory.orgCeilingSnapshot)
        XCTAssertFalse(manager.memory.isOrgMemorySyncAllowed)

        // Member grants member-local memory consent
        manager.memoryConsentGranted = true
        manager.memory.automaticExtraction = true

        // Member local memory extraction and recall are allowed on their separate lane
        XCTAssertTrue(
            MemberMemoryLaneGate.isExtractionAllowed(
                memberConsentGranted: manager.memoryConsentGranted,
                automaticExtractionEnabled: manager.memory.automaticExtraction
            )
        )
        XCTAssertTrue(
            MemberMemoryLaneGate.isRecallAllowed(
                memberConsentGranted: manager.memoryConsentGranted
            )
        )
    }

    func test_org_gated_kinds_are_denied_per_ceiling() {
        let allKinds: [MemoryKind] = [.fact, .preference, .event, .profile, .relationship, .other]
        let allowedSet: Set<String> = ["fact", "event"]

        // Matrix across (consent, resolved, orgSyncEnabled)
        for consent in [false, true] {
            for resolved in [false, true] {
                for syncEnabled in [false, true] {
                    let snapshot = OrgMemoryRemoteConfigSnapshot(
                        orgSyncEnabled: syncEnabled,
                        allowedKinds: allowedSet
                    )

                    let syncAllowed = OrgMemoryCeilingGate.isOrgSyncAllowed(
                        orgConsentGranted: consent,
                        remoteConfigResolved: resolved,
                        snapshot: snapshot
                    )

                    XCTAssertEqual(
                        syncAllowed,
                        consent && resolved && syncEnabled,
                        "consent=\(consent) resolved=\(resolved) syncEnabled=\(syncEnabled)"
                    )

                    for kind in allKinds {
                        let kindAllowed = OrgMemoryCeilingGate.isKindAllowed(
                            kind: kind,
                            orgConsentGranted: consent,
                            remoteConfigResolved: resolved,
                            snapshot: snapshot
                        )

                        let expectedKindAllowed = consent && resolved && syncEnabled && allowedSet.contains(kind.rawValue)
                        XCTAssertEqual(
                            kindAllowed,
                            expectedKindAllowed,
                            "kind=\(kind.rawValue) consent=\(consent) resolved=\(resolved) syncEnabled=\(syncEnabled)"
                        )
                    }
                }
            }
        }
    }
}

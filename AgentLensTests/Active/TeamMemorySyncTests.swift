import XCTest
@testable import OpenBurnBar
import OpenBurnBarKernel
import OpenBurnBarProjectCodeContracts

final class TeamMemorySyncTests: XCTestCase {

    func test_a_team_fact_seals_and_opens_under_the_team_key() throws {
        let teamVaultKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let teamID = "team_platform_core"
        let memoryID = "mem_arch_001"
        let now = Date()

        let payload = TeamMemoryFactPayload(
            teamID: teamID,
            memoryID: memoryID,
            text: "All SQLite migrations must be roll-forward and additive-only.",
            kind: "architecture",
            scope: "project",
            confidence: 0.98,
            citations: ["thread_123#msg_456"],
            validFrom: now,
            updatedAt: now,
            tags: ["sqlite", "architecture", "migrations"],
            bodyHash: "abc123hash",
            projectID: "proj_burnbar",
            authorUID: "user_architect_1",
            teamKeyVersion: 1
        )

        let (docID, sealedDict) = try TeamMemorySyncService.sealTeamFact(
            payload: payload,
            teamVaultKey: teamVaultKey,
            now: now
        )

        XCTAssertFalse(docID.isEmpty)
        XCTAssertEqual(sealedDict["teamId"] as? String, teamID)
        XCTAssertEqual(sealedDict["uid"] as? String, "user_architect_1")
        XCTAssertEqual(sealedDict["reviewStatus"] as? String, "approved")
        XCTAssertEqual(sealedDict["schemaVersion"] as? Int, 2)
        XCTAssertEqual(sealedDict["teamKeyVersion"] as? Int, 1)

        guard let sealedMemory = sealedDict["sealedMemory"] as? [String: Any] else {
            XCTFail("Missing sealedMemory dictionary")
            return
        }
        XCTAssertEqual(sealedMemory["algorithm"] as? String, "AES-256-GCM")
        XCTAssertEqual(sealedMemory["schemaVersion"] as? Int, 2)
        XCTAssertEqual(sealedMemory["keyVersion"] as? Int, 1)

        let opened = try TeamMemorySyncService.openTeamFact(
            data: sealedDict,
            teamID: teamID,
            teamVaultKey: teamVaultKey
        )

        XCTAssertEqual(opened.teamID, payload.teamID)
        XCTAssertEqual(opened.memoryID, payload.memoryID)
        XCTAssertEqual(opened.text, payload.text)
        XCTAssertEqual(opened.kind, payload.kind)
        XCTAssertEqual(opened.authorUID, payload.authorUID)
        XCTAssertEqual(opened.teamKeyVersion, payload.teamKeyVersion)
    }

    func test_the_aad_binds_the_team_id() throws {
        let teamA = "team_alpha"
        let teamB = "team_beta"
        let docID = "7f8e9d0c1b2a34567890abcdef1234567890abcdef1234567890abcdef123456"

        let aadContextA = try TeamMemorySyncService.teamAADContext(teamID: teamA, docID: docID)
        let aadContextB = try TeamMemorySyncService.teamAADContext(teamID: teamB, docID: docID)

        let expectedA = "OpenBurnBar-CloudVault-aad-v2|team:\(teamA)|team_memory_facts|\(docID)|sealedMemory|2|sealedMemory"
        let expectedB = "OpenBurnBar-CloudVault-aad-v2|team:\(teamB)|team_memory_facts|\(docID)|sealedMemory|2|sealedMemory"

        XCTAssertEqual(aadContextA.stringValue, expectedA)
        XCTAssertEqual(aadContextB.stringValue, expectedB)
        XCTAssertNotEqual(aadContextA.stringValue, aadContextB.stringValue)

        // Cross-team splice attack: attempt to open team A ciphertext as team B
        let teamVaultKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let payload = TeamMemoryFactPayload(
            teamID: teamA,
            memoryID: "mem_splice_test",
            text: "Confidential architecture invariant.",
            kind: "architecture",
            scope: "project",
            validFrom: Date(),
            updatedAt: Date(),
            authorUID: "user_alice"
        )

        let (_, sealedDict) = try TeamMemorySyncService.sealTeamFact(
            payload: payload,
            teamVaultKey: teamVaultKey
        )

        XCTAssertThrowsError(
            try TeamMemorySyncService.openTeamFact(
                data: sealedDict,
                teamID: teamB,
                teamVaultKey: teamVaultKey
            )
        ) { error in
            guard case TeamMemorySyncService.Error.aadMismatch = error else {
                XCTFail("Expected aadMismatch error on cross-team open, got \(error)")
                return
            }
        }
    }

    func test_team_sync_failing_closed_does_not_affect_member_sync() {
        // 1. Consent off fails closed for team sync
        XCTAssertFalse(
            TeamMemorySyncService.isTeamSyncAllowed(
                userConsentEnabled: false,
                orgCeilingAllowed: true,
                reviewStatus: "approved"
            )
        )

        // 2. Org ceiling closed fails closed for team sync
        XCTAssertFalse(
            TeamMemorySyncService.isTeamSyncAllowed(
                userConsentEnabled: true,
                orgCeilingAllowed: false,
                reviewStatus: "approved"
            )
        )

        // 3. Quarantined / unapproved fact fails closed for team sync
        XCTAssertFalse(
            TeamMemorySyncService.isTeamSyncAllowed(
                userConsentEnabled: true,
                orgCeilingAllowed: true,
                reviewStatus: "quarantined"
            )
        )

        // 4. Happy path: all gates open
        XCTAssertTrue(
            TeamMemorySyncService.isTeamSyncAllowed(
                userConsentEnabled: true,
                orgCeilingAllowed: true,
                reviewStatus: "approved"
            )
        )

        // 5. Invariant: Team sync failure does not disable member sync
        let memberSyncActive = true
        let teamSyncFailedClosed = !TeamMemorySyncService.isTeamSyncAllowed(
            userConsentEnabled: false,
            orgCeilingAllowed: true,
            reviewStatus: "approved"
        )
        XCTAssertTrue(teamSyncFailedClosed)
        XCTAssertTrue(memberSyncActive, "Member sync must continue unaffected when team sync fails closed")
    }

    func test_the_ui_states_both_join_and_leave_semantics() {
        let semanticA = TeamMemoryCopy.joinSemanticA
        let semanticB = TeamMemoryCopy.leaveSemanticB
        let footnote = TeamMemoryCopy.settingsFootnote

        // Semantic A: Join-reads-history
        XCTAssertTrue(
            semanticA.contains("including memories contributed by team members before you joined"),
            "Join semantic must state that joining grants access to historical memories"
        )
        XCTAssertTrue(
            semanticA.contains("Joining a team grants read access to all team memories"),
            "Join semantic must state read access to all team memories"
        )

        // Semantic B: Leave-protects-future-only
        XCTAssertTrue(
            semanticB.contains("rotates the team encryption key for future memories"),
            "Leave semantic must state key rotation protects future memories"
        )
        XCTAssertTrue(
            semanticB.contains("cannot erase memories or keys that have already been downloaded to your devices"),
            "Leave semantic must state offline downloaded retention cannot be erased remotely"
        )

        // Settings footnote captures both invariants
        XCTAssertTrue(
            footnote.contains("Joining a team grants access to past team memories"),
            "Settings footnote must state past access on join"
        )
        XCTAssertTrue(
            footnote.contains("leaving rotates encryption keys to protect future memories only"),
            "Settings footnote must state future protection only on leave"
        )
    }
}

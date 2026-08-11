import XCTest

@testable import OpenBurnBarCore

/// `withAccountMetadata` stamps a base snapshot with one account's identity.
///
/// It used to carry the base snapshot's `id` straight through, which meant
/// every account of a provider came out with the *same* `Identifiable` id —
/// `claude-code_default` for all of them. Any `ForEach` over account snapshots
/// without an explicit key collapsed them to a single row, so a user with three
/// Claude accounts saw one. The id is now re-derived from the account's own
/// `sourceId`, matching what the convenience initializer builds.
///
/// These assertions are about *identity*, not formatting: the property that
/// matters is that two accounts of the same provider are distinguishable, and
/// that stamping identity does not disturb the measurement it carries.
final class ProviderQuotaAccountIdentityTests: XCTestCase {

    private func baseSnapshot(
        id: String = "claude-code_default",
        provider: String = "claude-code"
    ) -> ProviderQuotaSnapshot {
        ProviderQuotaSnapshot(
            id: id,
            provider: provider,
            sourceKind: .localSession,
            sourceId: "default",
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: "local",
            confidence: .high,
            buckets: [
                ProviderQuotaBucket(
                    name: "5-hour window",
                    used: 40,
                    limit: 100,
                    remaining: 60,
                    window: "rollingHours",
                    meta: ["unit": "percent", "usedPercent": "40"],
                    resetsAt: nil
                )
            ],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    /// The regression itself: two accounts, one provider, distinct ids.
    func testTwoAccountsOfOneProviderGetDistinctIdentifiableIDs() {
        let base = baseSnapshot()

        let work = base.withAccountMetadata(
            providerID: .claudeCode,
            accountID: "acct-work",
            accountLabel: "Work",
            accountStorageScope: .deviceKeychain,
            sourceId: "work"
        )
        let personal = base.withAccountMetadata(
            providerID: .claudeCode,
            accountID: "acct-personal",
            accountLabel: "Personal",
            accountStorageScope: .deviceKeychain,
            sourceId: "personal"
        )

        XCTAssertNotEqual(
            work.id, personal.id,
            """
            Both accounts share an Identifiable id, so a ForEach over account \
            snapshots collapses them to one row. This is the bug the id \
            re-derivation exists to fix.
            """
        )
    }

    /// The id is derived from the account's own source, not inherited.
    func testIdentifiableIDIsDerivedFromProviderAndSourceID() {
        let stamped = baseSnapshot().withAccountMetadata(
            providerID: .claudeCode,
            accountID: "acct-work",
            accountLabel: "Work",
            accountStorageScope: .deviceKeychain,
            sourceId: "work"
        )

        XCTAssertEqual(stamped.id, "\(ProviderID.claudeCode.rawValue)_work")
        XCTAssertNotEqual(
            stamped.id, "claude-code_default",
            "the base snapshot's id leaked through instead of being re-derived"
        )
    }

    /// Two accounts that genuinely share a source id are the same row. Without
    /// this, "make ids unique" could be satisfied by a counter or a UUID, which
    /// would break identity across refreshes and make SwiftUI rebuild every row.
    func testSameSourceIDYieldsTheSameIdentifiableID() {
        let first = baseSnapshot().withAccountMetadata(
            providerID: .claudeCode, accountID: "acct-a", accountLabel: "A",
            accountStorageScope: .deviceKeychain, sourceId: "shared"
        )
        let second = baseSnapshot(id: "something-else").withAccountMetadata(
            providerID: .claudeCode, accountID: "acct-b", accountLabel: "B",
            accountStorageScope: .deviceKeychain, sourceId: "shared"
        )

        XCTAssertEqual(
            first.id, second.id,
            "id must be a function of (providerID, sourceId) so it is stable across refreshes"
        )
    }

    /// Different providers with the same source id stay distinct.
    func testDifferentProvidersWithTheSameSourceIDStayDistinct() {
        let claude = baseSnapshot().withAccountMetadata(
            providerID: .claudeCode, accountID: "a", accountLabel: nil,
            accountStorageScope: .deviceKeychain, sourceId: "default"
        )
        let codex = baseSnapshot().withAccountMetadata(
            providerID: .codex, accountID: "a", accountLabel: nil,
            accountStorageScope: .deviceKeychain, sourceId: "default"
        )

        XCTAssertNotEqual(claude.id, codex.id)
    }

    /// Stamping identity must not disturb the measurement it carries.
    func testAccountMetadataIsStampedWithoutTouchingTheMeasurement() {
        let base = baseSnapshot()
        let stamped = base.withAccountMetadata(
            providerID: .claudeCode,
            accountID: "acct-work",
            accountLabel: "Work",
            accountStorageScope: .deviceKeychain,
            sourceId: "work"
        )

        XCTAssertEqual(stamped.accountID, "acct-work")
        XCTAssertEqual(stamped.accountLabel, "Work")
        XCTAssertEqual(stamped.accountStorageScope, .deviceKeychain)
        XCTAssertEqual(stamped.sourceId, "work")

        // Carried through untouched.
        XCTAssertEqual(stamped.provider, base.provider)
        XCTAssertEqual(stamped.fetchedAt, base.fetchedAt)
        XCTAssertEqual(stamped.confidence, base.confidence)
        XCTAssertEqual(stamped.buckets.count, base.buckets.count)
        XCTAssertEqual(stamped.buckets.first?.used, base.buckets.first?.used)
        XCTAssertEqual(stamped.buckets.first?.remaining, base.buckets.first?.remaining)
    }
}

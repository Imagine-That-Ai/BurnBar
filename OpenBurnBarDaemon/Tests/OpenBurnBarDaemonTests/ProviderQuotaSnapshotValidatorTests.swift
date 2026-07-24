import XCTest
import OpenBurnBarEngine

final class ProviderQuotaSnapshotValidatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func snapshot(
        provider: String = "Codex",
        providerID: ProviderID = .codex,
        sourceKind: ProviderQuotaSourceKind = .officialAPI,
        confidence: ProviderQuotaConfidence = .high,
        fetchedAt: Date? = nil,
        updatedAt: Date? = nil,
        buckets: [ProviderQuotaBucket] = [
            ProviderQuotaBucket(
                name: "requests",
                used: 10,
                limit: 100,
                remaining: 90
            )
        ]
    ) -> ProviderQuotaSnapshot {
        ProviderQuotaSnapshot(
            id: "validator-test",
            provider: provider,
            providerID: providerID,
            sourceKind: sourceKind,
            sourceId: "validator-test",
            fetchedAt: fetchedAt ?? now,
            source: sourceKind.rawValue,
            confidence: confidence,
            buckets: buckets,
            updatedAt: updatedAt ?? now
        )
    }

    func testAcceptsCanonicalProviderIdentityAndNormalizedDisplayName() {
        let result = ProviderQuotaSnapshotValidator.validate(
            snapshot(provider: "Codex"),
            expectedProvider: .codex,
            now: now
        )

        XCTAssertNil(result)
    }

    func testRejectsProviderIdentityMismatchBeforeRendering() {
        let result = ProviderQuotaSnapshotValidator.validate(
            snapshot(provider: "Codex", providerID: .openAI),
            expectedProvider: .codex,
            now: now
        )

        XCTAssertEqual(result, .providerIdentityMismatch)
    }

    func testUnavailableSnapshotCannotCarryQuotaBucketsOrFreshConfidence() {
        let withBuckets = ProviderQuotaSnapshotValidator.validate(
            snapshot(sourceKind: .unavailable, confidence: .stale),
            now: now
        )
        let freshUnavailable = ProviderQuotaSnapshotValidator.validate(
            snapshot(sourceKind: .unavailable, confidence: .high, buckets: []),
            now: now
        )

        XCTAssertEqual(withBuckets, .unavailableSnapshotHasBuckets)
        XCTAssertEqual(freshUnavailable, .unavailableSnapshotHasFreshConfidence)
    }

    func testRejectsNonFiniteBucketValuesAndFutureTimestamps() {
        let malformedBucket = ProviderQuotaBucket(
            name: "requests",
            used: .nan,
            limit: 100,
            remaining: 100
        )
        let nonFinite = ProviderQuotaSnapshotValidator.validate(
            snapshot(buckets: [malformedBucket]),
            now: now
        )
        let future = ProviderQuotaSnapshotValidator.validate(
            snapshot(fetchedAt: now.addingTimeInterval(ProviderQuotaSnapshotValidator.allowedFutureClockSkew + 1)),
            now: now
        )

        XCTAssertEqual(nonFinite, .nonFiniteBucketValue)
        XCTAssertEqual(future, .futureFetchedAt)
    }

    func testAcceptedReturnsOriginalSnapshotOnlyWhenValid() throws {
        let valid = snapshot()
        XCTAssertEqual(
            ProviderQuotaSnapshotValidator.accepted(valid, expectedProvider: .codex, now: now),
            valid
        )

        let invalid = snapshot(providerID: .openAI)
        XCTAssertNil(ProviderQuotaSnapshotValidator.accepted(invalid, expectedProvider: .codex, now: now))
        _ = try XCTUnwrap(valid.quotaProvider)
    }
}

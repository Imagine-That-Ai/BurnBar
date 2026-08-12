import XCTest

@testable import OpenBurnBarCore

/// `mergedAccountCount` is how a synthetic cross-account merge tells the rest
/// of the app how many accounts it stands for.
///
/// The merge collapses N per-account snapshots into one record, so every
/// surface downstream of the collapse sees a single entry. Anything that
/// answered "how many accounts?" by counting entries reported `1` — the
/// constellation orb's multi-account badge and its accessibility text vanished
/// for exactly the multi-account setups they exist to describe. The count is
/// therefore carried as data on the record itself rather than re-derived by a
/// view that can disagree with the model.
final class ProviderQuotaMergedAccountCountTests: XCTestCase {

    private func bucket(used: Double = 40, limit: Double = 100) -> ProviderQuotaBucket {
        ProviderQuotaBucket(
            name: "5-hour window",
            used: used,
            limit: limit,
            remaining: limit - used,
            window: "rollingHours",
            meta: ["unit": "percent", "usedPercent": "\((used / limit) * 100)"],
            resetsAt: nil
        )
    }

    private func snapshot(
        mergedAccountCount: Int? = nil,
        sourceId: String = "default"
    ) -> ProviderQuotaSnapshot {
        ProviderQuotaSnapshot(
            id: "claude-code_\(sourceId)",
            provider: "claude-code",
            providerID: .claudeCode,
            sourceKind: .officialAPI,
            sourceId: sourceId,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: "officialAPI",
            confidence: .high,
            buckets: [bucket()],
            mergedAccountCount: mergedAccountCount,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    /// A real per-account snapshot stands for itself, and says so by carrying
    /// no count. Callers read `mergedAccountCount ?? 1`, so a default of `0`
    /// or a non-nil `1` would both blur the distinction the field exists for.
    func testPerAccountSnapshotCarriesNoMergedCount() {
        XCTAssertNil(snapshot().mergedAccountCount)
    }

    func testMergedSnapshotCarriesTheAccountCount() {
        XCTAssertEqual(snapshot(mergedAccountCount: 3, sourceId: "cumulative:claude-code").mergedAccountCount, 3)
    }

    /// The count has to survive persistence and cloud sync, otherwise a
    /// restored merge reports a footprint of one.
    func testMergedCountSurvivesACodableRoundTrip() throws {
        let encoded = try JSONEncoder().encode(
            snapshot(mergedAccountCount: 4, sourceId: "cumulative:claude-code")
        )
        let decoded = try JSONDecoder().decode(ProviderQuotaSnapshot.self, from: encoded)

        XCTAssertEqual(decoded.mergedAccountCount, 4)
    }

    /// Records written before the field existed decode as "not a merge"
    /// instead of failing the whole snapshot store.
    func testDecodingARecordWithoutTheFieldYieldsNil() throws {
        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(snapshot())
            ) as? [String: Any]
        )
        payload.removeValue(forKey: "mergedAccountCount")

        let decoded = try JSONDecoder().decode(
            ProviderQuotaSnapshot.self,
            from: try JSONSerialization.data(withJSONObject: payload)
        )

        XCTAssertNil(decoded.mergedAccountCount)
    }

    /// Filtering to the displayable buckets narrows the measurement; it does
    /// not change which accounts the record describes.
    func testFilteringToDisplayableSignalKeepsTheMergedCount() throws {
        let filtered = try XCTUnwrap(
            snapshot(mergedAccountCount: 2, sourceId: "cumulative:claude-code")
                .filteringToDisplayableQuotaSignal()
        )

        XCTAssertEqual(filtered.mergedAccountCount, 2)
    }

    /// Stamping one account's identity onto a record makes it that account's
    /// snapshot, so any cross-account count it carried no longer describes it.
    func testStampingAccountMetadataDropsTheMergedCount() {
        let stamped = snapshot(mergedAccountCount: 3, sourceId: "cumulative:claude-code")
            .withAccountMetadata(
                providerID: .claudeCode,
                accountID: "acct-work",
                accountLabel: "Work",
                accountStorageScope: .deviceKeychain,
                sourceId: "daemon-slot:claude-code:work"
            )

        XCTAssertNil(stamped.mergedAccountCount)
    }
}

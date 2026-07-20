import XCTest
import OpenBurnBarEngine
@testable import OpenBurnBarDaemon

final class BurnBarQuotaSignalSnapshotTests: XCTestCase {
    func testProviderSnapshotsUseRealBoundedHeaderValuesAndFreshProvenance() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let signal = BurnBarQuotaSignalRecord(
            id: "signal-1",
            observedAt: now.addingTimeInterval(-60),
            providerID: "anthropic",
            providerName: "Anthropic",
            accountID: "team",
            accountLabel: "Team",
            headers: [
                BurnBarQuotaSignalHeader(name: "x-ratelimit-limit-requests", value: "100"),
                BurnBarQuotaSignalHeader(name: "x-ratelimit-remaining-requests", value: "70"),
                BurnBarQuotaSignalHeader(name: "x-ratelimit-reset-requests", value: "3600")
            ],
            remaining: 70,
            limit: 100,
            resetsAt: now.addingTimeInterval(3_600)
        )

        let snapshot = try XCTUnwrap(BurnBarQuotaSignalStore.providerSnapshots(from: [signal], now: now).first)
        XCTAssertEqual(snapshot.providerID.rawValue, "anthropic")
        XCTAssertEqual(snapshot.sourceKind, .provider)
        XCTAssertEqual(snapshot.sourceId, "daemon.quota.signals:signal-1")
        XCTAssertEqual(snapshot.confidence, .high)
        XCTAssertEqual(snapshot.buckets.first?.usedValue, 30)
        XCTAssertEqual(snapshot.buckets.first?.remainingValue, 70)
        XCTAssertEqual(snapshot.buckets.first?.limitValue, 100)
        XCTAssertEqual(snapshot.buckets.first?.usedPercent, 30)
        XCTAssertEqual(snapshot.buckets.first?.resetsAt, signal.observedAt.addingTimeInterval(3_600))
        XCTAssertEqual(snapshot.buckets.first?.unit, .requests)
    }

    func testProviderSnapshotsBecomeStaleAndSurviveFileBackedStoreRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("quota-signals.jsonl")
        let observed = Date(timeIntervalSince1970: 5_000)
        let signal = BurnBarQuotaSignalRecord(
            id: "persisted",
            observedAt: observed,
            providerID: "openai",
            headers: [],
            remaining: 25,
            limit: 50,
            resetsAt: nil
        )
        await BurnBarQuotaSignalStore(fileURL: file).append(signal)
        let reloaded = try await BurnBarQuotaSignalStore(fileURL: file).recent(limit: 10)
        let snapshot = try XCTUnwrap(BurnBarQuotaSignalStore.providerSnapshots(from: reloaded, now: observed.addingTimeInterval(901)).first)
        XCTAssertEqual(snapshot.confidence, .stale)
        XCTAssertEqual(snapshot.sourceId, "daemon.quota.signals:persisted")
        XCTAssertEqual(snapshot.buckets.first?.usedPercent, 50)
    }

    func testProviderSnapshotsRejectMissingUnknownAndOutOfRangeValues() {
        let rows = [
            BurnBarQuotaSignalRecord(observedAt: .now, providerID: "", headers: [], remaining: 1, limit: 2),
            BurnBarQuotaSignalRecord(observedAt: .now, providerID: "openai", headers: [], remaining: nil, limit: 2),
            BurnBarQuotaSignalRecord(observedAt: .now, providerID: "openai", headers: [], remaining: 3, limit: 2),
            BurnBarQuotaSignalRecord(observedAt: .now, providerID: "openai", headers: [], remaining: 1, limit: 0)
        ]
        XCTAssertTrue(BurnBarQuotaSignalStore.providerSnapshots(from: rows).isEmpty)
    }

    func testProviderSnapshotsPairRequestAndTokenFamiliesWithoutHeaderOrderCoupling() throws {
        let observed = Date(timeIntervalSince1970: 2_000)
        let signal = BurnBarQuotaSignalRecord(
            id: "multi",
            observedAt: observed,
            providerID: "anthropic",
            headers: [
                .init(name: "x-ratelimit-remaining-tokens", value: "900"),
                .init(name: "x-ratelimit-limit-requests", value: "20"),
                .init(name: "x-ratelimit-limit-tokens", value: "1000"),
                .init(name: "x-ratelimit-remaining-requests", value: "5")
            ],
            remaining: 900,
            limit: 20,
            resetsAt: nil
        )
        let snapshot = try XCTUnwrap(BurnBarQuotaSignalStore.providerSnapshots(from: [signal], now: observed).first)
        XCTAssertEqual(snapshot.buckets.map(\.key), ["traffic-requests-rate-limit", "traffic-tokens-rate-limit"])
        XCTAssertEqual(snapshot.buckets.map(\.unit), [.requests, .tokens])
        XCTAssertEqual(snapshot.buckets.map(\.usedPercent), [75, 10])
    }

    func testScalarFallbackNeverClaimsRequestUnits() throws {
        let signal = BurnBarQuotaSignalRecord(
            observedAt: .now,
            providerID: "custom",
            headers: [],
            remaining: 1,
            limit: 4
        )
        let snapshot = try XCTUnwrap(BurnBarQuotaSignalStore.providerSnapshots(from: [signal]).first)
        XCTAssertEqual(snapshot.buckets.first?.key, "traffic-unknown-rate-limit")
        XCTAssertEqual(snapshot.buckets.first?.unit, .unknown)
    }

    func testQuotaSignalsResponseDecodesLegacyPayloadWithoutSnapshots() throws {
        let response = try JSONDecoder().decode(
            BurnBarQuotaSignalsRecentResponse.self,
            from: Data(#"{"signals":[]}"#.utf8)
        )
        XCTAssertTrue(response.signals.isEmpty)
        XCTAssertNil(response.snapshots)
    }
}

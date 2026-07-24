import XCTest
import OpenBurnBarEngine
@testable import OpenBurnBarDaemon

final class BurnBarLinuxQuotaCoverageTests: XCTestCase {
    func testSignalTiersHaveExplicitLinuxCoverage() {
        XCTAssertEqual(QuotaSignalTier.trafficHeaders.linuxQuotaCoverage, .apiBacked)
        XCTAssertEqual(QuotaSignalTier.statusEndpoint.linuxQuotaCoverage, .apiBacked)
        XCTAssertEqual(QuotaSignalTier.serverSweep.linuxQuotaCoverage, .apiBacked)
        XCTAssertEqual(QuotaSignalTier.spendProbe.linuxQuotaCoverage, .apiBacked)
        XCTAssertEqual(QuotaSignalTier.localArtifact.linuxQuotaCoverage, .localArtifact)
        XCTAssertEqual(QuotaSignalTier.cachedSnapshot.linuxQuotaCoverage, .cachedSnapshot)
    }

    func testCoverageCannotMasqueradeAsLocalParserOrUnknownSource() {
        XCTAssertEqual(BurnBarLinuxQuotaCoverage.apiBacked.sourceKind, .provider)
        XCTAssertEqual(BurnBarLinuxQuotaCoverage.localArtifact.sourceKind, .localSession)
        XCTAssertEqual(BurnBarLinuxQuotaCoverage.cachedSnapshot.sourceKind, .provider)
        XCTAssertEqual(BurnBarLinuxQuotaCoverage.unavailable.sourceKind, .unavailable)
        XCTAssertNotEqual(
            BurnBarLinuxQuotaCoverage.apiBacked.sourceLabel,
            "Local quota artifact"
        )
    }

    func testProviderSnapshotsPreserveLocalArtifactProvenance() throws {
        let signal = BurnBarQuotaSignalRecord(
            id: "local-artifact",
            observedAt: Date(timeIntervalSince1970: 10_000),
            signalTier: .localArtifact,
            providerID: "codex",
            headers: [],
            remaining: 25,
            limit: 100
        )

        let snapshot = try XCTUnwrap(
            BurnBarQuotaSignalStore.providerSnapshots(from: [signal]).first
        )
        XCTAssertEqual(snapshot.sourceKind, .localSession)
        XCTAssertEqual(snapshot.source, "Local quota artifact")
    }

    func testProviderSnapshotsMarkStatusAndHeaderSignalsAsAPIBacked() throws {
        for tier in [QuotaSignalTier.trafficHeaders, .statusEndpoint, .serverSweep, .spendProbe] {
            let signal = BurnBarQuotaSignalRecord(
                id: tier.contractName,
                observedAt: Date(timeIntervalSince1970: 10_000),
                signalTier: tier,
                providerID: "codex",
                headers: [],
                remaining: 25,
                limit: 100
            )

            let snapshot = try XCTUnwrap(
                BurnBarQuotaSignalStore.providerSnapshots(from: [signal]).first
            )
            XCTAssertEqual(snapshot.sourceKind, .provider, tier.contractName)
            XCTAssertEqual(snapshot.source, "Provider/API quota signal", tier.contractName)
        }
    }
}

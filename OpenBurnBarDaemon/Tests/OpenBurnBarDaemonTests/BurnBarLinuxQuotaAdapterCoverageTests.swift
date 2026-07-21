import XCTest
import OpenBurnBarEngine
@testable import OpenBurnBarDaemon

final class BurnBarLinuxQuotaAdapterCoverageTests: XCTestCase {
    func testCoverageMirrorsCanonicalQuotaRegistry() {
        let entries = BurnBarLinuxQuotaAdapterCoverageCatalog.entries()

        XCTAssertTrue(BurnBarLinuxQuotaAdapterCoverageCatalog.isAuthoritative())
        XCTAssertEqual(entries.count, AgentProvider.quotaSignalProviders.count)
        XCTAssertEqual(Set(entries.map(\.provider)), Set(AgentProvider.quotaSignalProviders))
        XCTAssertEqual(entries.filter { $0.state == .liveAdapter }.count, 17)
        XCTAssertEqual(entries.filter { $0.state == .unavailable }.count, 2)
        XCTAssertEqual(entries.first?.provider, .antigravity)
        XCTAssertEqual(entries.last?.provider, .xAI)
    }

    func testUnavailableProvidersRemainExplicit() throws {
        let entries = BurnBarLinuxQuotaAdapterCoverageCatalog.entries()
        let cursorAgent = try XCTUnwrap(entries.first { $0.provider == .cursorAgent })
        let openBurnBar = try XCTUnwrap(entries.first { $0.provider == .openBurnBar })

        XCTAssertEqual(cursorAgent.state, .unavailable)
        XCTAssertEqual(cursorAgent.reason?.contains("stable quota API"), true)
        XCTAssertEqual(openBurnBar.state, .unavailable)
        XCTAssertEqual(openBurnBar.reason?.contains("cloud account service"), true)
    }

    func testMissingRegistryEntryFailsClosedInsteadOfMasqueradingAsLive() {
        let registry = ProviderQuotaAdapterRegistry(entries: [
            ProviderQuotaAdapterRegistry.Entry(
                provider: .codex,
                adapter: UnavailableQuotaAdapter(provider: .codex, message: "test unavailable"),
                coverage: .unavailable
            )
        ])

        let entries = BurnBarLinuxQuotaAdapterCoverageCatalog.entries(registry: registry)
        let codex = entries.first { $0.provider == .codex }
        let openAI = entries.first { $0.provider == .openAI }

        XCTAssertFalse(BurnBarLinuxQuotaAdapterCoverageCatalog.isAuthoritative(registry: registry))
        XCTAssertEqual(codex?.state, .unavailable)
        XCTAssertEqual(codex?.reason, "test unavailable")
        XCTAssertEqual(openAI?.state, .unavailable)
        XCTAssertEqual(openAI?.reason, "No Linux quota adapter is registered.")
    }

    func testRecentResponseKeepsCoverageOptionalForOlderPeers() throws {
        let response = BurnBarQuotaSignalsRecentResponse(signals: [])
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(BurnBarQuotaSignalsRecentResponse.self, from: data)

        XCTAssertNil(decoded.adapterCoverage)
    }
}

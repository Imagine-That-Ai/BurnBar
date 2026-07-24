import XCTest
@testable import OpenBurnBarCore
@testable import OpenBurnBarQuota

final class ProviderQuotaAdapterRegistryTests: XCTestCase {
    func testStandardRegistryCoversEveryQuotaSignalProvider() {
        let registry = ProviderQuotaAdapterRegistry.standard
        XCTAssertEqual(
            registry.providers,
            Set(AgentProvider.quotaSignalProviders),
            "Every declared quota provider must have an explicit live or unavailable entry."
        )
    }

    func testStandardRegistryKeepsLiveAndUnavailableCoverageExplicit() {
        let registry = ProviderQuotaAdapterRegistry.standard

        XCTAssertEqual(registry.entry(for: .codex)?.coverage, .live)
        XCTAssertEqual(registry.entry(for: .cursor)?.coverage, .live)
        XCTAssertEqual(registry.entry(for: .cursorAgent)?.coverage, .unavailable)
        XCTAssertEqual(registry.entry(for: .openBurnBar)?.coverage, .unavailable)
    }

    func testRegistryDoesNotResolveUsageOnlyProviders() {
        let registry = ProviderQuotaAdapterRegistry.standard

        XCTAssertNil(registry.entry(for: .aider))
        XCTAssertNil(registry.entry(for: .hermes))
        XCTAssertNil(registry.entry(for: .piAgent))
    }
}

import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// Unit tests for the `DrainTargetSwitcher.grouped` helper that powers the
/// per-provider sections in popover, dashboard, and settings. Browser profiles
/// must be excluded; CLI profiles must be bucketed by provider and sorted
/// deterministically so the UI stays stable across reloads.
final class DrainTargetSwitcherGroupedTests: XCTestCase {

    private func cli(_ id: String, _ type: SwitcherCLIProfileType, sortKey: Int, label: String? = nil) -> SwitcherProfileRecord {
        SwitcherProfileRecord(
            id: id,
            targetKind: .cli,
            cliType: type,
            cliMetadata: SwitcherCLIProfileMetadata(displayLabel: label ?? id),
            sortKey: sortKey
        )
    }

    private func browser(_ id: String, sortKey: Int) -> SwitcherProfileRecord {
        SwitcherProfileRecord(
            id: id,
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: id),
            sortKey: sortKey
        )
    }

    func test_grouped_emptyInput_returnsEmpty() {
        XCTAssertTrue(DrainTargetSwitcher.grouped([]).isEmpty)
    }

    func test_grouped_filtersOutBrowserProfiles() {
        let profiles = [
            browser("chrome", sortKey: 1),
            cli("claude-A", .claude, sortKey: 2),
            browser("safari", sortKey: 3)
        ]

        let groups = DrainTargetSwitcher.grouped(profiles)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.provider, .claudeCode)
        XCTAssertEqual(groups.first?.accounts.map(\.id), ["claude-A"])
    }

    func test_grouped_bucketsByProviderAndSortsAccountsBySortKey() {
        let profiles = [
            cli("claude-late", .claude, sortKey: 9),
            cli("claude-early", .claude, sortKey: 1),
            cli("codex-mid", .codex, sortKey: 5)
        ]

        let groups = DrainTargetSwitcher.grouped(profiles)

        let byProvider = Dictionary(uniqueKeysWithValues: groups.map { ($0.provider, $0.accounts.map(\.id)) })
        XCTAssertEqual(byProvider[.claudeCode], ["claude-early", "claude-late"], "Accounts within a provider must order by sortKey ASC")
        XCTAssertEqual(byProvider[.codex], ["codex-mid"])
    }

    func test_grouped_providersSortAlphabeticallyByDisplayName() {
        let profiles = [
            cli("codex-X", .codex, sortKey: 1),
            cli("antigravity-X", .antigravity, sortKey: 1),
            cli("claude-X", .claude, sortKey: 1)
        ]

        let groups = DrainTargetSwitcher.grouped(profiles)
        let providerOrder = groups.map { $0.provider.displayName }

        // Alphabetical: Antigravity, Claude Code, Codex.
        XCTAssertEqual(providerOrder, providerOrder.sorted(), "Provider rows must render in stable alphabetical order")
    }

    func test_grouped_coversAllSixCLITypes() {
        let profiles = [
            cli("a", .codex, sortKey: 1),
            cli("b", .claude, sortKey: 1),
            cli("c", .opencode, sortKey: 1),
            cli("d", .droid, sortKey: 1),
            cli("e", .forge, sortKey: 1),
            cli("f", .antigravity, sortKey: 1)
        ]

        // Direct sanity on the canonical mapping before grouping.
        XCTAssertEqual(SwitcherCLIProfileType.opencode.canonicalAgentProvider, .openCode)

        let expectedProviders: [AgentProvider] = [
            .codex, .claudeCode, .openCode, .factory, .forgeDev, .antigravity
        ]
        for (profile, expected) in zip(profiles, expectedProviders) {
            XCTAssertEqual(
                profile.cliType?.canonicalAgentProvider,
                expected,
                "Profile \(profile.id) must map to \(expected)"
            )
        }

        let groups = DrainTargetSwitcher.grouped(profiles)

        let providerOfProfile: [String: AgentProvider] = Dictionary(
            uniqueKeysWithValues: groups.flatMap { group in group.accounts.map { ($0.id, group.provider) } }
        )
        XCTAssertEqual(providerOfProfile["c"], .openCode, "opencode profile must land in the openCode bucket")
        XCTAssertEqual(groups.count, 6, "Each CLI profile type must map to a distinct provider bucket")
        XCTAssertEqual(
            Set(groups.map(\.provider)),
            Set([AgentProvider.codex, .claudeCode, .openCode, .factory, .forgeDev, .antigravity])
        )
    }
}

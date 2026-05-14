import XCTest
@testable import OpenBurnBar

/// Behavioral tests for the Settings search ranking engine.
///
/// The engine is the single shared piece of search logic on macOS — the
/// manifest is just data. By pinning these invariants we guarantee the
/// in-product search bar always feels consistent (ordering, AND semantics,
/// diacritic folding, tie-breaking).
final class SettingsSearchEngineTests: XCTestCase {

    // MARK: - Fixtures

    /// A compact, deterministic fixture exercising every weighted field.
    private let fixture: [SettingsItem] = [
        SettingsItem(
            id: "appearance",
            tab: .general,
            pageRoute: .appearance,
            anchorID: "appearance",
            title: "Theme",
            subtitle: "System, Light, or Dark",
            keywords: ["dark", "appearance"],
            helpText: "Choose how OpenBurnBar styles itself."
        ),
        SettingsItem(
            id: "hermes-token",
            tab: .hermes,
            pageRoute: .hermesRoot,
            anchorID: "hermes-token",
            title: "Gateway Auth Token",
            subtitle: "Bearer token",
            keywords: ["secret", "auth"],
            helpText: "Used for non-loopback bindings."
        ),
        SettingsItem(
            id: "alerts-digest",
            tab: .alerts,
            pageRoute: .alertsRoot,
            anchorID: "alerts-digest",
            title: "Daily Digest",
            subtitle: "Summary of spend",
            keywords: ["morning", "summary"]
        ),
        SettingsItem(
            id: "cafe",
            tab: .general,
            pageRoute: .generalRoot,
            anchorID: "cafe",
            title: "Café Defaults",
            subtitle: "Diacritic test",
            keywords: ["coffee"]
        ),
    ]

    // MARK: - Tests

    func test_emptyQuery_returnsEmpty() {
        XCTAssertTrue(SettingsSearchEngine.search("", in: fixture).isEmpty)
        XCTAssertTrue(SettingsSearchEngine.search("   ", in: fixture).isEmpty)
    }

    func test_titleHit_outranksKeywordHit() {
        // "dark" appears in the Appearance title via subtitle/keywords but not
        // in Hermes — Appearance must be first.
        let results = SettingsSearchEngine.search("dark", in: fixture)
        XCTAssertEqual(results.first?.id, "appearance")
    }

    func test_keywordHit_pulls_match() {
        let results = SettingsSearchEngine.search("coffee", in: fixture)
        XCTAssertEqual(results.first?.id, "cafe")
    }

    func test_diacriticFolding_findsAccentedTitle() {
        let withAccent = SettingsSearchEngine.search("café", in: fixture)
        let withoutAccent = SettingsSearchEngine.search("cafe", in: fixture)
        XCTAssertEqual(withAccent.first?.id, "cafe")
        XCTAssertEqual(withoutAccent.first?.id, "cafe")
    }

    func test_andSemantics_dropsRowsMissingAnyToken() {
        // "daily" matches alerts-digest only (via title). "Theme" does not
        // appear with "daily" so it must drop out.
        let results = SettingsSearchEngine.search("daily digest", in: fixture)
        XCTAssertEqual(results.map(\.id), ["alerts-digest"])
    }

    func test_andSemantics_returnsEmptyWhenAnyTokenMissing() {
        // "dark" matches Appearance, "spend" matches Alerts. They never
        // co-occur in any row → AND must return nothing.
        let results = SettingsSearchEngine.search("dark spend", in: fixture)
        XCTAssertTrue(results.isEmpty)
    }

    func test_caseInsensitive_findsRegardlessOfCase() {
        let lower = SettingsSearchEngine.search("theme", in: fixture)
        let upper = SettingsSearchEngine.search("THEME", in: fixture)
        let mixed = SettingsSearchEngine.search("ThEmE", in: fixture)
        XCTAssertEqual(lower.first?.id, "appearance")
        XCTAssertEqual(upper.first?.id, "appearance")
        XCTAssertEqual(mixed.first?.id, "appearance")
    }

    func test_tieBreaker_sortsByTitle() {
        // Two items with the same title/keyword weight should sort by title.
        let items = [
            SettingsItem(
                id: "b",
                tab: .general,
                pageRoute: .generalRoot,
                anchorID: "b",
                title: "Beta",
                keywords: ["match"]
            ),
            SettingsItem(
                id: "a",
                tab: .general,
                pageRoute: .generalRoot,
                anchorID: "a",
                title: "Alpha",
                keywords: ["match"]
            ),
        ]
        let results = SettingsSearchEngine.search("match", in: items)
        XCTAssertEqual(results.map(\.id), ["a", "b"])
    }

    func test_resultsAreCappedByLimit() {
        let many = (0..<60).map { i in
            SettingsItem(
                id: "i\(i)",
                tab: .general,
                pageRoute: .generalRoot,
                anchorID: "i\(i)",
                title: "Item \(i)",
                keywords: ["foo"]
            )
        }
        let results = SettingsSearchEngine.search("foo", in: many, limit: 25)
        XCTAssertEqual(results.count, 25)
    }

    func test_scoringRespectsWeights() {
        // Title hit (weight 3) should rank above a row that only has the
        // token in helpText (weight 1).
        let items = [
            SettingsItem(
                id: "help-only",
                tab: .general,
                pageRoute: .generalRoot,
                anchorID: "help-only",
                title: "Operator Model",
                helpText: "Run the wizard to detect agents."
            ),
            SettingsItem(
                id: "title-hit",
                tab: .general,
                pageRoute: .generalRoot,
                anchorID: "title-hit",
                title: "Setup Wizard"
            ),
        ]
        let results = SettingsSearchEngine.search("wizard", in: items)
        XCTAssertEqual(results.first?.id, "title-hit")
    }

    func test_manifestFindsOpenCodeProviderEntries() {
        let ids = SettingsSearchEngine.search("opencode", in: SettingsManifest.all).map(\.id)
        XCTAssertEqual(ids.first, "providers.openCode")
        XCTAssertTrue(ids.contains("providers.openCode"))
        XCTAssertTrue(ids.contains("providers.add"))
        XCTAssertTrue(ids.contains("providers.cli"))
        XCTAssertTrue(ids.contains("routingPools.overview"))
        XCTAssertEqual(SettingsManifest.anchorIndex[SettingsAnchor.providersOpenCode], .providersRoot)
    }

    func test_manifestFindsEveryProviderWithExactProviderAnchor() {
        for provider in AgentProvider.allCases {
            let expectedID = provider == .openCode ? "providers.openCode" : "providers.\(provider.persistedToken)"
            let item = SettingsManifest.all.first { $0.id == expectedID }
            XCTAssertNotNil(item, "Missing settings search entry for \(provider.displayName)")
            XCTAssertEqual(item?.pageRoute, .providersRoot)
            XCTAssertEqual(SettingsManifest.anchorIndex[item?.anchorID ?? ""], .providersRoot)

            let result = SettingsSearchEngine.search(provider.displayName, in: SettingsManifest.all).first
            XCTAssertEqual(result?.id, expectedID, "\(provider.displayName) should route to its own provider row")
        }
    }
}

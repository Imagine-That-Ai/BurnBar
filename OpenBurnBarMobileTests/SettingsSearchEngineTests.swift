import XCTest
@testable import OpenBurnBarMobile

/// Behavioral parity test for the iOS Settings search ranking engine.
/// Mirrors the macOS suite — the engines share semantics across platforms.
final class SettingsSearchEngineTests: XCTestCase {

    // MARK: - Fixtures

    private let fixture: [SettingsItem] = [
        SettingsItem(
            id: "theme",
            section: .appearance,
            pageRoute: .hubRoot,
            anchorID: "theme",
            title: "Theme",
            subtitle: "System, Light, or Dark",
            keywords: ["dark", "appearance"],
            helpText: "Choose how OpenBurnBar styles itself."
        ),
        SettingsItem(
            id: "hermes-token",
            section: .hermesAI,
            pageRoute: .hermes,
            anchorID: "hermes-token",
            title: "Gateway Auth Token",
            subtitle: "Bearer token",
            keywords: ["secret", "auth"],
            helpText: "Used for non-loopback bindings."
        ),
        SettingsItem(
            id: "alerts-digest",
            section: .notifications,
            pageRoute: .hubRoot,
            anchorID: "alerts-digest",
            title: "Daily Digest",
            subtitle: "Summary of spend",
            keywords: ["morning", "summary"]
        ),
        SettingsItem(
            id: "cafe",
            section: .appearance,
            pageRoute: .hubRoot,
            anchorID: "cafe",
            title: "Café Defaults",
            subtitle: "Diacritic test",
            keywords: ["coffee"]
        ),
    ]

    func test_emptyQuery_returnsEmpty() {
        XCTAssertTrue(SettingsSearchEngine.search("", in: fixture).isEmpty)
        XCTAssertTrue(SettingsSearchEngine.search("   ", in: fixture).isEmpty)
    }

    func test_titleHit_outranksHelpTextHit() {
        let results = SettingsSearchEngine.search("dark", in: fixture)
        XCTAssertEqual(results.first?.id, "theme")
    }

    func test_keywordHit_findsMatch() {
        let results = SettingsSearchEngine.search("coffee", in: fixture)
        XCTAssertEqual(results.first?.id, "cafe")
    }

    func test_diacriticFolding() {
        let withAccent = SettingsSearchEngine.search("café", in: fixture)
        let withoutAccent = SettingsSearchEngine.search("cafe", in: fixture)
        XCTAssertEqual(withAccent.first?.id, "cafe")
        XCTAssertEqual(withoutAccent.first?.id, "cafe")
    }

    func test_andSemantics_dropsRowsMissingAnyToken() {
        let results = SettingsSearchEngine.search("daily digest", in: fixture)
        XCTAssertEqual(results.map(\.id), ["alerts-digest"])
    }

    func test_andSemantics_returnsEmptyWhenAnyTokenMissing() {
        let results = SettingsSearchEngine.search("dark spend", in: fixture)
        XCTAssertTrue(results.isEmpty)
    }

    func test_caseInsensitive() {
        XCTAssertEqual(SettingsSearchEngine.search("theme", in: fixture).first?.id, "theme")
        XCTAssertEqual(SettingsSearchEngine.search("THEME", in: fixture).first?.id, "theme")
        XCTAssertEqual(SettingsSearchEngine.search("ThEmE", in: fixture).first?.id, "theme")
    }

    func test_tieBreakerByTitleAscending() {
        let items = [
            SettingsItem(id: "b", section: .appearance, pageRoute: .hubRoot, anchorID: "b", title: "Beta", keywords: ["match"]),
            SettingsItem(id: "a", section: .appearance, pageRoute: .hubRoot, anchorID: "a", title: "Alpha", keywords: ["match"]),
        ]
        XCTAssertEqual(SettingsSearchEngine.search("match", in: items).map(\.id), ["a", "b"])
    }

    func test_resultLimit() {
        let many = (0..<60).map { i in
            SettingsItem(id: "i\(i)", section: .appearance, pageRoute: .hubRoot, anchorID: "i\(i)", title: "Item \(i)", keywords: ["foo"])
        }
        XCTAssertEqual(SettingsSearchEngine.search("foo", in: many, limit: 25).count, 25)
    }

    // MARK: - Manifest guards

    func test_manifest_isNotEmpty() {
        XCTAssertFalse(SettingsManifest.all.isEmpty)
    }

    func test_manifest_anchorsUnique() {
        let anchors = SettingsManifest.all.map(\.anchorID)
        XCTAssertEqual(anchors.count, Set(anchors).count)
    }

    func test_manifest_idsUnique() {
        let ids = SettingsManifest.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func test_manifest_eachSectionRepresented() {
        let sections = Set(SettingsManifest.all.map(\.section))
        for section in SettingsSection.allCases {
            XCTAssertTrue(sections.contains(section),
                          "Section \(section.rawValue) is not represented in the manifest")
        }
    }

    func test_manifest_findsOpenCodeProviderEntries() {
        let ids = SettingsSearchEngine.search("opencode", in: SettingsManifest.all).map(\.id)
        XCTAssertEqual(ids.first, "providers.openCode")
        XCTAssertTrue(ids.contains("providers.openCode"))
        XCTAssertTrue(ids.contains("hub.providers"))
        XCTAssertTrue(ids.contains("providers.add"))
        XCTAssertTrue(ids.contains("providers.cliAuth"))
        XCTAssertEqual(SettingsManifest.anchorIndex[SettingsAnchor.providerOpenCode], .providerConnections)
    }

    // MARK: - Router guards

    @MainActor
    func test_routerRepeatedDestinationNavigationCollapsesToSingleRoute() {
        let router = SettingsRouter()
        let item = SettingsItem(
            id: "settings-hermes",
            section: .hermesAI,
            pageRoute: .hermes,
            anchorID: SettingsAnchor.hermesRow,
            title: "Hermes"
        )

        router.query = "hermes"
        router.navigate(to: item)
        router.navigate(to: item)

        XCTAssertEqual(router.path, [.hermes])
        XCTAssertEqual(router.pendingAnchor, SettingsAnchor.hermesRow)
        XCTAssertEqual(router.highlightedAnchor, SettingsAnchor.hermesRow)
        XCTAssertEqual(router.query, "")
    }

    @MainActor
    func test_routerRootNavigationClearsSubpageInsteadOfStacking() {
        let router = SettingsRouter()
        let subpage = SettingsItem(
            id: "settings-pi",
            section: .hermesAI,
            pageRoute: .pi,
            anchorID: SettingsAnchor.piRow,
            title: "Pi"
        )
        let rootItem = SettingsItem(
            id: "settings-theme",
            section: .appearance,
            pageRoute: .hubRoot,
            anchorID: SettingsAnchor.theme,
            title: "Theme"
        )

        router.navigate(to: subpage)
        router.navigate(to: rootItem)

        XCTAssertTrue(router.path.isEmpty)
        XCTAssertEqual(router.pendingAnchor, SettingsAnchor.theme)
    }
}

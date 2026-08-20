import GRDB
import OpenBurnBarCore
import SwiftUI
import ViewInspector
import XCTest
@testable import OpenBurnBar

// MARK: - DashboardLayoutMatrixTests
//
// Composes every dashboard layout across the appearance matrix that broke:
// light and dark appearance, crossed with the Aurora and Editorial skins,
// crossed with a live kernel backdrop on and off. Eight layouts times eight
// configurations.
//
// What this covers, and what it deliberately does not:
//
//   * Covered — every layout builds and inspects in every configuration, with a
//     populated usage window and with an empty one. The layouts derive halves,
//     midpoints, deltas, shares, and top-N slices from the window summary, and
//     an empty window is the case that divides by zero or indexes past the end.
//     `.atlas` splitting a window at its midpoint and `.stream` grouping by day
//     are the two most exposed.
//   * Covered — the resolved ink and readability profile for each cell, so a
//     configuration cannot silently resolve the white-on-white pairing that
//     started this. `BackdropLegiblePlateTests` proves the contrast numbers
//     themselves; this proves each cell of the matrix selects the right family.
//   * Not covered — pixels. An earlier version of this file rendered each cell
//     through `ImageRenderer` and measured ink coverage. It does not work: the
//     test host cannot compile the Metal shaders behind `liquidGlassEffect` and
//     the material plates ("Compiler failed to build request"), so every frame
//     came back uniform and the measurement was of the renderer, not the
//     layout. Appearance is verified by running the app.

@MainActor
final class DashboardLayoutMatrixTests: XCTestCase {

    private struct Configuration {
        let appearance: AppearanceMode
        let skin: AppSkin
        let liveBackdrop: Bool

        var name: String {
            [appearance.rawValue, skin.rawValue, liveBackdrop ? "kernel" : "flat"]
                .joined(separator: "/")
        }
    }

    private var configurations: [Configuration] {
        var result: [Configuration] = []
        for appearance in [AppearanceMode.light, .dark] {
            for skin in [AppSkin.aurora, .editorial] {
                for liveBackdrop in [true, false] {
                    result.append(
                        Configuration(
                            appearance: appearance,
                            skin: skin,
                            liveBackdrop: liveBackdrop
                        )
                    )
                }
            }
        }
        return result
    }

    private var savedKernelPreference: Any?

    override func setUp() {
        super.setUp()
        savedKernelPreference = UserDefaults.standard
            .object(forKey: KernelBackdropPreferences.enabledKey)
    }

    override func tearDown() {
        if let savedKernelPreference {
            UserDefaults.standard.set(
                savedKernelPreference,
                forKey: KernelBackdropPreferences.enabledKey
            )
        } else {
            UserDefaults.standard.removeObject(forKey: KernelBackdropPreferences.enabledKey)
        }
        super.tearDown()
    }

    // MARK: Composition

    func test_everyLayoutComposesWithAPopulatedWindow() throws {
        for configuration in configurations {
            let view = try makeView(configuration, usages: ViewTestFixtures.makeWeekOfUsages())
            for layout in DashboardLayout.allCases {
                XCTAssertNoThrow(
                    try content(of: view, for: layout).inspect(),
                    "\(layout.rawValue) @ \(configuration.name) failed to compose"
                )
            }
        }
    }

    /// The empty window, which is not a cosmetic case.
    ///
    /// Atlas splits the window at its midpoint and divides one half by the other;
    /// Stream groups sessions into days and reads the first of each; Ledger,
    /// Bento, and Cockpit all take top-N slices and compute shares against a
    /// total. With no usage at all, every one of those is a division by zero or
    /// an index into an empty collection.
    func test_everyLayoutComposesWithAnEmptyWindow() throws {
        for configuration in configurations {
            let view = try makeView(configuration, usages: [])
            for layout in DashboardLayout.allCases {
                XCTAssertNoThrow(
                    try content(of: view, for: layout).inspect(),
                    "\(layout.rawValue) @ \(configuration.name) failed on an empty window"
                )
            }
        }
    }

    /// A single session is the other boundary: enough data to render every
    /// ranked list and share bar, not enough to have a second row to compare
    /// against. Atlas's in-window delta has no second half here.
    func test_everyLayoutComposesWithASingleSession() throws {
        let single = [ViewTestFixtures.makeUsage(provider: .codex, sessionId: "only-one")]
        for configuration in configurations {
            let view = try makeView(configuration, usages: single)
            for layout in DashboardLayout.allCases {
                XCTAssertNoThrow(
                    try content(of: view, for: layout).inspect(),
                    "\(layout.rawValue) @ \(configuration.name) failed on a single session"
                )
            }
        }
    }

    // MARK: Ink selection per cell

    /// Each cell of the matrix has to select the ink family that suits the canvas
    /// it will actually be drawn on.
    ///
    /// `tone` names the *foreground*, not the canvas: `.light` is white ink,
    /// which belongs over a dark field. So a light appearance must resolve
    /// `.dark` ink and a dark appearance `.light` ink.
    ///
    /// This is the assertion the original bug would have failed. Before the fix,
    /// `nativeFallback` returned `darkCanvasFallback` — the white ink family —
    /// for any live backdrop regardless of appearance, so light + Aurora +
    /// kernel resolved white ink over a bright field.
    func test_everyConfigurationResolvesTheInkFamilyItsCanvasNeeds() throws {
        for configuration in configurations {
            let view = try makeView(configuration, usages: ViewTestFixtures.makeWeekOfUsages())
            let profile = view.dashboardActiveReadabilityProfile
            // Editorial is light-locked — paper in both appearances — so it
            // always wants dark ink.
            let expected: BackdropForegroundTone = configuration.skin == .editorial
                ? .dark
                : (configuration.appearance == .dark ? .light : .dark)
            XCTAssertEqual(
                profile.tone, expected,
                """
                \(configuration.name) resolved \(profile.tone) ink. A light canvas needs \
                dark ink and a dark canvas needs light ink; getting this backwards is the \
                invisible-text bug.
                """
            )
        }
    }

    /// An Aurora live backdrop has to carry at least as much scrim as the darkest
    /// static canvas does, in *both* appearances — that is what `reinforcingScrim`
    /// is for. An animated field arriving at the ink unattenuated is the other
    /// half of the legibility failure, and it is independent of which ink family
    /// was chosen: respecting `colorScheme` fixed the polarity but on its own
    /// would have left the light-mode veil thinner than the dark-mode one.
    ///
    /// Editorial is excluded, and that exclusion is the correct behaviour rather
    /// than a gap. `nativeFallback` answers Editorial before it consults either
    /// the appearance or the backdrop flag, because Editorial's "live" backdrop
    /// is not a WebGL kernel — it is `DesignSystem.Colors.background` paper with
    /// a slow transparent swarm drawn on top, and the kernel branch is never
    /// reached under that skin. Reinforcing a scrim over paper would grey out the
    /// paper to defend against motion that is not there.
    func test_auroraLiveBackdropCarriesAtLeastTheStaticScrim() throws {
        let floor = BackdropReadabilityProfile.darkCanvasFallback.scrimOpacity
        let live = configurations.filter { $0.liveBackdrop && $0.skin == .aurora }
        XCTAssertEqual(live.count, 2, "both appearances must be covered")

        for configuration in live {
            let view = try makeView(configuration, usages: [])
            let profile = view.dashboardActiveReadabilityProfile
            XCTAssertGreaterThanOrEqual(
                profile.scrimOpacity, floor,
                "\(configuration.name) exposes a live field at only \(profile.scrimOpacity) scrim"
            )
        }
    }

    // MARK: Harness

    private func makeView(
        _ configuration: Configuration,
        usages: [TokenUsage]
    ) throws -> DashboardView {
        UserDefaults.standard.set(
            configuration.liveBackdrop,
            forKey: KernelBackdropPreferences.enabledKey
        )

        let store = try XCTUnwrap(
            try? DataStoreCoordinator(databaseQueue: DatabaseQueue(), runMigrations: false)
        )
        store.usageViewModel.replaceUsages(usages)

        let settings = makeSettingsManager()
        settings.appearanceMode = configuration.appearance
        settings.appearanceSkin = configuration.skin
        settings.useWebsiteBackground = configuration.liveBackdrop

        let controller = ChatSessionController(dataStore: store, settingsManager: settings)
        let layer = OpenBurnBarOperatingLayer(dataStore: store, settingsManager: settings)
        return DashboardView(
            context: DashboardContext(
                dataStore: store,
                settingsManager: settings,
                accountManager: .shared,
                operatingLayer: layer,
                chatController: controller,
                navigationCoordinator: NavigationCoordinator()
            )
        )
    }

    private func content(of view: DashboardView, for layout: DashboardLayout) -> AnyView {
        switch layout {
        case .classic: return AnyView(view.ledgerContent)
        case .aurora: return AnyView(view.auroraLayout)
        case .nebula: return AnyView(view.nebulaLayout)
        case .constellation: return AnyView(view.constellationLayout)
        case .cockpit: return AnyView(view.cockpitLayout)
        case .atelier: return AnyView(view.atelierLayout)
        case .stream: return AnyView(view.streamLayout)
        case .atlas: return AnyView(view.atlasLayout)
        }
    }
}

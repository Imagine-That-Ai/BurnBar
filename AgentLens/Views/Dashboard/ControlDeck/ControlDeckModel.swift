import AppKit
import SwiftUI

// MARK: - Control Deck Model
//
// The small amount of state a tile cannot read synchronously at render time,
// cached once and refreshed by the notification the owning subsystem already
// posts. Everything else on the deck is a direct scalar read of a live store —
// no snapshots, no polling, no listeners.
//
// The model lives on `DashboardView`, not inside `ControlDeckView`: route views
// carry `.id(mainRoute)`, so anything held by the route view is thrown away and
// re-derived on every navigation.
//
// Notification wiring is `.onReceive` on the view (`ControlDeckView`) rather
// than `NotificationCenter.addObserver` here — the shipped pattern in
// `TextExpansionSettingsView` and `DashboardQuickSwitchView`, and the one that
// needs no observer bookkeeping and no `deinit`.
//
// Cost discipline, stated once because it is the thing that goes wrong:
//   * the only I/O here is one local SQLite read (`fetchTextExpansionSnippets`)
//     and one bundle-resource read (the active pet definition);
//   * nothing here opens a Firestore listener, touches StoreKit, or starts a
//     subsystem. In particular `PetCompanionFeature.runtime` is never touched:
//     it is a `static let` whose first access builds the controller, the Carbon
//     global hotkey, and `PetSystemObservers`. Rendering a chip must not boot a
//     subsystem, so the hotkey chip decodes the persisted combo instead.

@MainActor
@Observable
final class ControlDeckModel {

    // MARK: Text Expansion

    /// Total non-deleted snippets, or nil before the first read. Nil renders as
    /// "—" rather than a misleading zero.
    private(set) var snippetCount: Int?
    private(set) var enabledSnippetCount: Int?
    /// A few real triggers, for the tile's status ladder.
    private(set) var sampleTriggers: [String] = []

    /// `AXIsProcessTrusted()`, re-polled on `didBecomeActive` because System
    /// Settings never notifies the app when the user flips the switch there.
    private(set) var accessibilityTrusted: Bool = AXIsProcessTrusted()

    // MARK: Pets

    /// The active pet's display name, resolved from the bundled definition.
    /// Falls back to the persisted id when the resource is missing.
    private(set) var activePetName: String = ""
    /// Human glyphs for the summon hotkey, decoded straight from
    /// `pet.hotkey.combo` — never from `PetCompanionFeature.runtime`.
    private(set) var petHotkeyLabel: String = ""

    // MARK: Charts

    /// Charts currently shown on the Charts page, read from the same
    /// `chartsPageLayout.v1` payload the Charts page persists.
    private(set) var visibleChartCount: Int = ChartKind.allCases.count

    @ObservationIgnored private weak var dataStore: DataStore?

    /// One deck model per app, deliberately.
    ///
    /// The counts must outlive the route view: every dashboard route view
    /// carries `.id(mainRoute)`, so a `@State` model inside `ControlDeckView`
    /// would be destroyed and re-read on every visit, and the tiles would flash
    /// "—" each time you came back. A shared, `@MainActor` `@Observable`
    /// singleton is the same shape `ProviderQuotaService.shared` and
    /// `DirectDownloadUpdateChecker.shared` already use.
    static let shared = ControlDeckModel()

    init() {}

    /// Attach to the live store and take the first reading. Idempotent — the
    /// deck calls it from `.task`, which re-runs on every route entry.
    func start(dataStore: DataStore) {
        self.dataStore = dataStore
        refreshSynchronousFacts()
        refreshSnippetCountsSoon()
    }

    /// Everything readable without awaiting anything.
    func refreshSynchronousFacts() {
        accessibilityTrusted = AXIsProcessTrusted()
        visibleChartCount = Self.readVisibleChartCount()
        petHotkeyLabel = Self.readPetHotkeyLabel()
        activePetName = Self.readActivePetName()
    }

    /// Fire-and-forget wrapper so `.onReceive` handlers stay synchronous.
    func refreshSnippetCountsSoon() {
        Task { await refreshSnippetCounts() }
    }

    /// One local SQLite read. Cheap, and re-run only when the snippet store
    /// says it changed.
    func refreshSnippetCounts() async {
        guard let dataStore else { return }
        // try?-ok(deck tile keeps its last known count; a failed local read
        // must never take the page down)
        guard let snippets = try? await dataStore.fetchTextExpansionSnippets() else { return }
        snippetCount = snippets.count
        enabledSnippetCount = snippets.filter(\.isEnabled).count
        sampleTriggers = snippets
            .filter(\.isEnabled)
            .prefix(5)
            .map { ";" + $0.trigger }
    }

    // MARK: Readers

    private static func readVisibleChartCount() -> Int {
        guard let data = UserDefaults.standard.data(forKey: ChartsPageLayout.storageKey) else {
            return ChartsPageLayout.default.visibleConfigs.count
        }
        return ChartsPageLayout.decode(from: data).visibleConfigs.count
    }

    private static func readPetHotkeyLabel() -> String {
        guard let data = UserDefaults.standard.data(forKey: "pet.hotkey.combo"),
              let combo = try? JSONDecoder().decode(PetHotkey.Combo.self, from: data) else {
            return PetHotkey.Combo.defaultCombo.displayString
        }
        return combo.displayString
    }

    private static func readActivePetName() -> String {
        let id = PetCompanionFeature.activePetID
        guard let definition = PetCompanionFeature.loadActiveDefinition() else {
            return id.capitalized
        }
        return definition.displayName ?? definition.name
    }
}

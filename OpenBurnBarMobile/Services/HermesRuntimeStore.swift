import Foundation
import OpenBurnBarCore

// MARK: - Hermes Runtime Store
//
// Shared Hermes runtime CATALOG, split out of `HermesService` so every
// surface (Hermes tab, Pulse quick-ask, mission console, settings) reads
// one consistent copy of the connections / reachability / model options /
// session-profile-job lists and the persisted connection + model
// selection, while each surface keeps its OWN conversation state
// (`messages`, `selectedSessionID`, `isStreaming`, token burn — those are
// deliberately per-view, see the `HermesService` class doc).
//
// The split is also what makes `refreshRuntime`'s in-flight coalescing
// global: the coalescing task used to live per `HermesService` instance,
// so each per-view instance fanned out its own 6-op runtime refresh
// (connections, reachability probe, models, sessions, profiles, jobs) at
// launch and on every foreground pass. With the task and generation
// counters here, concurrent refreshes from any surface collapse to one.
//
// Production surfaces inject `HermesRuntimeStore.shared`; tests and
// previews get an isolated store per `HermesService` by default, which
// preserves the historical per-instance behavior and test isolation.

@Observable
@MainActor
final class HermesRuntimeStore {
    static let shared = HermesRuntimeStore()

    static let selectedConnectionDefaultsKey = "hermes.selectedConnectionID"
    static let selectedModelDefaultsKey = "hermes.selectedModelID"
    static let favoriteModelsDefaultsKey = "hermes.favoriteModelIDs"

    // ── Shared catalog state ──
    var connections: [HermesConnectionRecord] = [HermesConnectionRecord.localDefault]
    var selectedConnection: HermesConnectionRecord = .localDefault
    var sessions: [HermesSessionSummary] = []
    var profiles: [HermesRuntimeProfile] = []
    var modelOptions: [HermesRuntimeModelOption] = []
    var jobs: [HermesRuntimeJob] = []
    var selectedModelID: String?
    var favoriteModelIDs: [String] = []
    var isReachable = false
    var isLoadingRuntime = false
    var runtimeErrorText: String?
    /// Endpoint the direct (non-relay) transport talks to. Derived from
    /// `selectedConnection`, so it must live with the shared selection —
    /// otherwise one surface could switch endpoints while another keeps
    /// sending to the old host.
    var baseURL: URL
    /// True when the user explicitly picked `selectedModelID` (vs. an
    /// automatic route-eligible default).
    var selectedModelWasExplicit = false

    // ── Cross-surface refresh coalescing (was per-HermesService) ──
    var runtimeGeneration = 0
    var runtimeRefreshTask: Task<Void, Never>?
    var runtimeRefreshGeneration: Int?
    /// Completion stamp of the last full runtime refresh, paired with the
    /// generation it refreshed. `refreshRuntimeIfStale` skips the 6-op
    /// fan-out while this is fresh AND the generation hasn't moved (a
    /// connection switch bumps the generation, invalidating freshness).
    var lastRefreshCompletedAt: Date?
    var lastRefreshCompletedGeneration: Int?

    init(
        defaults: UserDefaults = .standard,
        baseURL: URL = URL(string: "http://127.0.0.1:8642")!
    ) {
        self.baseURL = baseURL
        self.selectedModelID = HermesService.restoredModelID(
            defaults.string(forKey: Self.selectedModelDefaultsKey),
            defaults: defaults,
            key: Self.selectedModelDefaultsKey
        )
        self.selectedModelWasExplicit =
            self.selectedModelID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        self.favoriteModelIDs = HermesService.decodeStringArray(
            defaults.string(forKey: Self.favoriteModelsDefaultsKey)
        )
    }
}

import AppKit
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import OpenBurnBarKernel
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
// Cost discipline, stated once because it is the thing that goes wrong. On a
// cold deck visit this model performs exactly three classes of read:
//
//   * **local disk** — one SQLite query for the snippet counts, one for the
//     inbox unread count, one bundle-resource read for the active pet;
//   * **local IPC** — two Unix-socket RPCs to the daemon for the AI Inbox
//     config and its tick telemetry, both hopped off the main actor;
//   * **loopback HTTP** — one `GET /v1/models` against the model-router
//     gateway, and *only* when the gateway is configured on. An off gateway is
//     never probed: it has nothing to answer with, and probing it would
//     manufacture a frightening error string for a switch the user turned off
//     on purpose.
//
// And exactly zero of these:
//
//   * **no Firestore listener, ever.** The Memory MCP roster is a one-shot
//     `getDocuments()` behind an explicit button, stamped with when it was
//     read. `MacRemoteMCPClientStore.startListening()` opens a live snapshot
//     listener; a deck that opened one per visit would put a permanent cloud
//     subscription behind a page you glance at.
//   * **no StoreKit call and no `MacCloudEntitlementStore.start()`.** The tier
//     is read from the already-started shared store; starting it would spin up
//     five Firestore listeners and a StoreKit transaction task.
//   * **no subsystem boot.** In particular `PetCompanionFeature.runtime` is
//     never touched: it is a `static let` whose first access builds the
//     controller, the Carbon global hotkey, and `PetSystemObservers`. Rendering
//     a chip must not boot a subsystem, so the hotkey chip decodes the
//     persisted combo instead.

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

    // MARK: AI Inbox
    //
    // The daemon is the single writer of the inbox config: it owns the loop,
    // the credentials, and the egress policy. The deck therefore renders the
    // config the daemon *stored* — every value is re-clamped on write, so the
    // stored config can legitimately differ from the one we sent.

    private(set) var inboxConfig: BurnBarInboxConfig?
    private(set) var inboxRuns: [BurnBarInboxRunTelemetry] = []
    private(set) var inboxTodaySpendUSD: Double?
    /// Unread rows, counted locally. Survives a dead daemon on purpose.
    private(set) var inboxUnreadCount: Int?
    /// The daemon's own words for why it cannot answer, already translated into
    /// something a human can act on.
    private(set) var inboxUnavailableReason: String?
    private(set) var inboxIsLoading = false
    private(set) var inboxIsSaving = false
    private(set) var inboxIsRunningNow = false
    private(set) var inboxActionError: String?

    // MARK: Model Router

    private(set) var routerProbe: RouterDeckFacts.Probe?
    private(set) var routerProbedAt: Date?
    private(set) var routerIsProbing = false

    // MARK: Memory MCP

    private(set) var mcpReading: MCPDeckFacts.Reading?
    private(set) var mcpErrorMessage: String?
    private(set) var mcpIsChecking = false

    @ObservationIgnored private weak var dataStore: DataStore?
    /// Guards the cold-visit reads so re-entering the route (which re-runs
    /// `.task`) does not re-issue a socket round trip on every navigation.
    @ObservationIgnored private var didLoadInbox = false
    @ObservationIgnored private var didProbeRouter = false

    /// One deck model per dashboard window, deliberately — and owned by
    /// `DashboardView`, not by a global.
    ///
    /// The counts must outlive the route view: every dashboard route view
    /// carries `.id(mainRoute)`, so a `@State` model inside `ControlDeckView`
    /// would be destroyed and re-read on every visit, and the tiles would flash
    /// "—" each time you came back. `DashboardView` is *not* re-identified on
    /// navigation, so its `@State` copy survives every route change; see
    /// `DashboardView.controlDeckModel`.
    init() {}

    /// Attach to the live store and take the first reading. Idempotent — the
    /// deck calls it from `.task`, which re-runs on every route entry, so the
    /// off-machine reads are guarded and the free ones are not.
    ///
    /// `gatewayEnabled` is passed in rather than read here so the model keeps no
    /// reference to `SettingsManager`: the deck's rule is that a value has one
    /// owner, and the gateway's owner is `GatewaySettings`.
    func start(dataStore: DataStore, gateway: RouterGatewayEndpoint?) {
        self.dataStore = dataStore
        refreshSynchronousFacts()
        refreshSnippetCountsSoon()
        refreshInboxUnreadCountSoon()

        if !didLoadInbox {
            didLoadInbox = true
            Task { await loadInbox() }
        }
        // An off gateway is never probed. See the cost-discipline note above.
        if let gateway, gateway.enabled, !didProbeRouter {
            didProbeRouter = true
            Task { await probeRouter(gateway) }
        }
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

    // MARK: - AI Inbox
    //
    // Reads are split deliberately. The unread count is a local `COUNT` against
    // the shared control-plane database, so it renders even while the daemon is
    // restarting. Config and telemetry are daemon-owned and go over the socket.

    /// Fire-and-forget wrapper so `.onReceive` handlers stay synchronous.
    func refreshInboxUnreadCountSoon() {
        Task { await refreshInboxUnreadCount() }
    }

    /// A `COUNT`, not a fetch: an idle inbox must stay free. A failure clears
    /// nothing — the tile keeps its last known number rather than flashing a
    /// zero that would read as "all caught up".
    func refreshInboxUnreadCount() async {
        guard let dataStore else { return }
        // try?-ok(a badge is not the place to report a fault; the tile's
        // unavailable state carries the daemon's own reason instead)
        guard let count = try? await dataStore.aiInboxUnreadCount() else { return }
        inboxUnreadCount = count
    }

    /// Config + telemetry in one pass. `forceTokenRefresh` drops the cached
    /// daemon socket auth token first, which is what makes Retry able to
    /// recover from a token the daemon rotated under us.
    func loadInbox(forceTokenRefresh: Bool = false) async {
        guard !inboxIsLoading else { return }
        inboxIsLoading = true
        defer { inboxIsLoading = false }
        do {
            if forceTokenRefresh {
                OpenBurnBarDaemonSocketClient.cacheDaemonSocketAuthToken(nil)
            }
            let socketURL = Self.daemonSocketURL()
            inboxConfig = try await Self.daemonRPC {
                try OpenBurnBarDaemonSocketClient.inboxConfiguration(at: socketURL)
            }
            inboxUnavailableReason = nil
            await loadInboxTelemetry()
        } catch {
            inboxUnavailableReason = AIInboxSettingsModel.friendlyUnavailable(error)
        }
        await refreshInboxUnreadCount()
    }

    func loadInboxTelemetry() async {
        let socketURL = Self.daemonSocketURL()
        // try?-ok(telemetry is the tile's *supporting* evidence; losing it must
        // not blank the config the tile already rendered)
        guard let response = try? await Self.daemonRPC({
            try OpenBurnBarDaemonSocketClient.inboxRuns(at: socketURL)
        }) else { return }
        inboxRuns = response.runs
        inboxTodaySpendUSD = response.todaySpendUSD
    }

    /// The one write the AI Inbox tile performs. It renders the config the
    /// daemon stored, never the optimistic one, because the daemon re-clamps
    /// every value on write — and a surface that shows its own request back to
    /// itself is how two surfaces start disagreeing.
    ///
    /// Deliberately narrow: this flips `enabled` and nothing else. Egress
    /// escalation is a confirmed action and lives in Settings, because moving
    /// *to* cloud models changes what leaves the Mac.
    func setInboxEnabled(_ enabled: Bool) async {
        guard let current = inboxConfig, !inboxIsSaving else { return }
        inboxIsSaving = true
        defer { inboxIsSaving = false }
        let next = Self.inboxConfig(current, enabled: enabled)
        do {
            let socketURL = Self.daemonSocketURL()
            inboxConfig = try await Self.daemonRPC {
                try OpenBurnBarDaemonSocketClient.updateInboxConfiguration(next, at: socketURL)
            }
            inboxActionError = nil
        } catch {
            inboxActionError = "Could not save: \(error.localizedDescription)"
        }
    }

    /// Forces one tick now. Fail-safe in direction: the daemon still applies
    /// its own budget, egress, and approval gates, and answers with a refusal
    /// reason rather than silently doing nothing.
    func runInboxNow() async {
        guard !inboxIsRunningNow else { return }
        inboxIsRunningNow = true
        defer { inboxIsRunningNow = false }
        do {
            let socketURL = Self.daemonSocketURL()
            let response = try await Self.daemonRPC {
                try OpenBurnBarDaemonSocketClient.runInboxNow(force: true, at: socketURL)
            }
            inboxActionError = response.accepted ? nil : response.reason
        } catch {
            inboxActionError = "Could not start a check: \(error.localizedDescription)"
        }
        await loadInboxTelemetry()
        await refreshInboxUnreadCount()
    }

    /// `BurnBarInboxConfig` is all-`let`, so "change one field" is a full
    /// rebuild. Written once here so a future edit cannot silently drop a field
    /// and reset a user's budget.
    private static func inboxConfig(
        _ config: BurnBarInboxConfig,
        enabled: Bool
    ) -> BurnBarInboxConfig {
        BurnBarInboxConfig(
            enabled: enabled,
            egressMode: config.egressMode,
            tickSeconds: config.tickSeconds,
            remotePhaseEveryNTicks: config.remotePhaseEveryNTicks,
            dailyBudgetUSD: config.dailyBudgetUSD,
            maxVerifierCallsPerTick: config.maxVerifierCallsPerTick,
            perTickPromptTokenCap: config.perTickPromptTokenCap,
            analystProviderID: config.analystProviderID,
            analystModel: config.analystModel,
            verifierProviderID: config.verifierProviderID,
            verifierModel: config.verifierModel,
            githubEnabled: config.githubEnabled,
            notifyOnP1: config.notifyOnP1,
            lookbackMinutes: config.lookbackMinutes,
            founderLensEnabled: config.founderLensEnabled,
            perReplyBudgetUSD: config.perReplyBudgetUSD,
            maxThreadTurns: config.maxThreadTurns,
            budgetCountsSubscriptionSpend: config.budgetCountsSubscriptionSpend
        )
    }

    private static func daemonSocketURL() -> URL {
        OpenBurnBarDaemonRuntimePaths.live().socketURL
    }

    /// Blocking POSIX socket I/O never runs on the main actor — a 30s socket
    /// timeout on the main thread is a beachball on the dashboard.
    private static func daemonRPC<T: Sendable>(
        _ work: @Sendable @escaping () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }

    // MARK: - Model Router

    /// Host, port, and credential for one gateway probe. A value type so the
    /// model never holds `SettingsManager`, and so the token can be handed over
    /// without ever being stored on an observable property that a view could
    /// accidentally render.
    struct RouterGatewayEndpoint: Sendable, Equatable {
        let enabled: Bool
        let host: String
        let port: Int
        let authToken: String

        var baseURL: String {
            let resolvedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "127.0.0.1"
                : host
            return "http://\(resolvedHost):\(port > 0 ? port : 8317)"
        }
    }

    /// One loopback `GET`. Asks the catalog endpoint first (it reports the
    /// advertise/route flags per row) and falls back to the public `/v1/models`
    /// list the way `ConnectionsViewModel.fetchProxyModels` does, so an older
    /// daemon still answers.
    func probeRouter(_ gateway: ControlDeckModel.RouterGatewayEndpoint) async {
        guard !routerIsProbing else { return }
        routerIsProbing = true
        defer { routerIsProbing = false }
        routerProbe = await Self.probe(gateway)
        routerProbedAt = Date()
    }

    /// Explicit re-probe, and the repair action on the unavailable state. Unlike
    /// the cold-visit read this one runs even for a gateway that was off a
    /// moment ago — the user just asked.
    func refreshRouter(_ gateway: ControlDeckModel.RouterGatewayEndpoint) async {
        didProbeRouter = true
        guard gateway.enabled else {
            routerProbe = nil
            routerProbedAt = Date()
            return
        }
        await probeRouter(gateway)
    }

    private static func probe(
        _ gateway: RouterGatewayEndpoint
    ) async -> RouterDeckFacts.Probe {
        guard let catalogURL = URL(string: gateway.baseURL + "/v1/models/catalog"),
              let publicURL = URL(string: gateway.baseURL + "/v1/models") else {
            return .failed("The gateway host and port do not form a URL.")
        }
        do {
            return try await probe(url: catalogURL, gateway: gateway)
        } catch ProbeError.http(let status) where status == 404 {
            do {
                return try await probe(url: publicURL, gateway: gateway)
            } catch {
                return .failed(describe(error))
            }
        } catch {
            return .failed(describe(error))
        }
    }

    private enum ProbeError: Error {
        case http(status: Int)
        case notHTTP
        case undecodable
    }

    private struct ProbeRow: Decodable {
        let advertised: Bool?
        let routeEligible: Bool?

        enum CodingKeys: String, CodingKey {
            case advertised
            case routeEligible = "route_eligible"
        }
    }

    private struct ProbeEnvelope: Decodable {
        let data: [ProbeRow]
    }

    private static func probe(
        url: URL,
        gateway: RouterGatewayEndpoint
    ) async throws -> RouterDeckFacts.Probe {
        var request = URLRequest(url: url)
        // Short: this is a loopback call on a page the user is looking at.
        request.timeoutInterval = 5
        if !gateway.authToken.isEmpty {
            // The token is used, never rendered, never copied, never logged.
            request.setValue("Bearer \(gateway.authToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProbeError.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw ProbeError.http(status: http.statusCode)
        }
        guard let envelope = try? JSONDecoder().decode(ProbeEnvelope.self, from: data) else {
            throw ProbeError.undecodable
        }
        // The public `/v1/models` list carries neither flag, and everything on
        // it is by definition advertised — so a missing flag means `true`.
        let advertised = envelope.data.filter {
            ($0.advertised ?? true) && ($0.routeEligible ?? true)
        }.count
        return .served(advertised: advertised, total: envelope.data.count)
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case ProbeError.http(let status) where status == 401 || status == 403:
            return "The gateway refused this app's token. Repair it in Settings → Daemon."
        case ProbeError.http(let status):
            return "The gateway answered HTTP \(status)."
        case ProbeError.notHTTP, ProbeError.undecodable:
            return "Something answered on that port, but it was not the gateway."
        default:
            let code = (error as NSError).code
            if code == NSURLErrorCannotConnectToHost || code == NSURLErrorNetworkConnectionLost {
                return "Nothing is listening on that port. Start the daemon."
            }
            if code == NSURLErrorTimedOut {
                return "The gateway did not answer in time."
            }
            return error.localizedDescription
        }
    }

    // MARK: - Memory MCP
    //
    // A one-shot read, never a listener, and never on appear.
    //
    // `MacRemoteMCPClientStore.startListening()` opens a live Firestore
    // snapshot listener on `users/{uid}/remote_mcp_clients`. That is correct for
    // a Settings pane you opened on purpose and wrong for a deck tile you
    // scrolled past: the deck would leave a cloud subscription running behind
    // every glance. So the tile reads the roster once, when asked, and stamps
    // the reading with the time so the number never pretends to be live.

    func checkMCPClients() async {
        guard !mcpIsChecking else { return }
        mcpIsChecking = true
        defer { mcpIsChecking = false }

        guard FirebaseApp.app() != nil else {
            mcpErrorMessage = nil
            mcpReading = nil
            return
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            mcpErrorMessage = nil
            mcpReading = nil
            return
        }

        do {
            // Through the sanctioned gateway, never a raw `Firestore.firestore()`
            // handle (R-GH6): offline persistence and handle configuration stay
            // owned by the CloudSync gateway layer, and this stays a one-shot
            // read rather than a subscription.
            let snapshot = try await CloudSyncFirestoreLiveGateway()
                .collection("users").document(uid)
                .collection("remote_mcp_clients")
                .getDocuments()
            var active = 0
            var revoked = 0
            var lastUsedAt: Date?
            for document in snapshot.documents {
                let data = document.data()
                if Self.date(from: data["revokedAt"]) != nil {
                    revoked += 1
                    continue
                }
                active += 1
                if let used = Self.date(from: data["lastUsedAt"]),
                   used > (lastUsedAt ?? .distantPast) {
                    lastUsedAt = used
                }
            }
            mcpReading = MCPDeckFacts.Reading(
                activeCount: active,
                revokedCount: revoked,
                lastUsedAt: lastUsedAt,
                checkedAt: Date()
            )
            mcpErrorMessage = nil
        } catch {
            mcpErrorMessage = error.localizedDescription
        }
    }

    private static func date(from value: Any?) -> Date? {
        if let timestamp = value as? Timestamp { return timestamp.dateValue() }
        if let date = value as? Date { return date }
        if let seconds = value as? TimeInterval { return Date(timeIntervalSince1970: seconds) }
        if let string = value as? String { return ISO8601DateFormatter().date(from: string) }
        return nil
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

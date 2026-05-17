import AppKit
import Foundation
import OpenBurnBarCore
import SwiftUI

// MARK: - Connection State

/// Per-app state for the smart Connect button.
///
/// The state machine collapses every legacy concept (wired, unwired, probing,
/// probe-ok, probe-failed) into one short list the UI can render. The
/// `.degraded` state means "config file is written but the local gateway is
/// not answering," which is the single repair-affordance moment.
enum AppConnectState: Equatable {
    case unknown
    case notConnected
    case connecting
    case syncingModels
    case connected
    case probing
    case degraded(message: String)
    case error(message: String)

    var isBusy: Bool {
        switch self {
        case .connecting, .syncingModels, .probing: return true
        default: return false
        }
    }
}

// MARK: - Proxy Model Catalog

struct ProxyAdvertisedModel: Identifiable, Equatable, Sendable {
    var id: String { "\(modelID)|\(providerID)|\(sourceID)" }

    let modelID: String
    let displayName: String
    let providerID: String
    let providerName: String
    let accountID: String
    let accountLabel: String
    let sourceID: String
    let sourceKind: String
    let quotaState: String
    let advertisementEnabled: Bool
    let advertised: Bool
    let routeEligible: Bool
    let capabilities: [String]
    let lastError: String?

    init(
        modelID: String,
        displayName: String,
        providerID: String,
        providerName: String,
        accountID: String,
        accountLabel: String,
        sourceID: String,
        sourceKind: String,
        quotaState: String,
        advertisementEnabled: Bool = true,
        advertised: Bool = true,
        routeEligible: Bool,
        capabilities: [String],
        lastError: String?
    ) {
        self.modelID = modelID
        self.displayName = displayName
        self.providerID = providerID
        self.providerName = providerName
        self.accountID = accountID
        self.accountLabel = accountLabel
        self.sourceID = sourceID
        self.sourceKind = sourceKind
        self.quotaState = quotaState
        self.advertisementEnabled = advertisementEnabled
        self.advertised = advertised
        self.routeEligible = routeEligible
        self.capabilities = capabilities
        self.lastError = lastError
    }
}

enum ProxyModelCatalogState: Equatable {
    case idle
    case loading
    case loaded(lastRefresh: Date)
    case error(message: String, lastAttempt: Date)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

// MARK: - View Model

/// Drives the unified Connections settings page. Owns the per-app state
/// machine and runs the "auto-enable gateway → wire → probe" sequence so
/// pressing Connect on any CLI is one click, not three.
///
/// Multiple accounts per provider — the whole point of OpenBurnBar's routing
/// layer — are managed by the underlying `ProviderQuotaService` and the
/// provider plan wizard. This view model is concerned only with the CLI side:
/// wiring each app to the local gateway so the daemon can fail over silently
/// across the accounts you've added.
@MainActor
@Observable
final class ConnectionsViewModel {

    /// Per-target state for the smart Connect button. Defaults to `.unknown`
    /// until `refreshWiringState` runs.
    var appStates: [RoutingClientWiringTarget: AppConnectState] = [:]

    /// Sheet target for the shell-snippet sheet, surfaced from the `⋯` menu
    /// on connected rows.
    var snippetTarget: RoutingClientWiringTarget?

    /// Most recent target whose snippet copy succeeded. Cleared after a short
    /// delay so the UI can show a one-shot confirmation.
    var copiedSnippetTarget: RoutingClientWiringTarget?

    /// The exact model rows currently advertised by the local BurnBar
    /// OpenAI-compatible gateway. This backs the forward-facing catalog panel
    /// on Settings -> Agents -> CLIs.
    var proxyModels: [ProxyAdvertisedModel] = []
    var proxyModelCatalogState: ProxyModelCatalogState = .idle

    private let wiringFactory: () -> RoutingClientWiring
    private let proxyCatalogFetcher: (RoutingClientGateway) async throws -> [ProxyAdvertisedModel]

    init(
        wiringFactory: @escaping () -> RoutingClientWiring = { RoutingClientWiring() },
        proxyCatalogFetcher: @escaping (RoutingClientGateway) async throws -> [ProxyAdvertisedModel] = ConnectionsViewModel.fetchProxyModels
    ) {
        self.wiringFactory = wiringFactory
        self.proxyCatalogFetcher = proxyCatalogFetcher
    }

    // MARK: - Wiring state

    /// Read the current "wired or not" status straight from disk so the row
    /// always matches the truth on the user's Mac.
    func refreshWiringState() {
        for target in RoutingClientWiringTarget.allCases {
            let wired = wiringFactory().isWired(target: target)
            // Preserve transient states (connecting/probing) — only flip
            // between connected and notConnected when we know.
            switch appStates[target] {
            case .connecting, .syncingModels, .probing:
                continue
            default:
                appStates[target] = wired ? .connected : .notConnected
            }
        }
    }

    /// Read disk truth plus live model-catalog drift. This keeps Droid honest:
    /// a stale Factory custom-model row is not "synced" just because an older
    /// OpenBurnBar entry still exists on disk.
    func refreshWiringState(settings: SettingsManager) async {
        refreshWiringState()
        await refreshDroidModelSyncState(settings: settings)
    }

    func state(for target: RoutingClientWiringTarget) -> AppConnectState {
        appStates[target] ?? .unknown
    }

    // MARK: - Smart Connect

    /// Press Connect on a CLI row: turn the gateway on with loopback defaults
    /// if needed, write the config, probe once, and land in `.connected`. On
    /// probe failure, land in `.degraded` so the row shows a single Repair
    /// affordance instead of a stack of error pills.
    func connect(
        target: RoutingClientWiringTarget,
        settings: SettingsManager,
        restartGateway: (() async -> Void)? = nil
    ) async {
        await wireAndProbe(
            target: target,
            settings: settings,
            restartGateway: restartGateway,
            busyState: .connecting
        )
    }

    /// Refresh the target's model entries from the live BurnBar catalog and
    /// rewrite its local config. For Droid this is the main "add my BurnBar
    /// models to Droid" action: it replaces stale OpenBurnBar custom models
    /// in Factory's known config files with the route-eligible `/v1/models`
    /// list currently advertised by the local gateway.
    func syncModels(
        target: RoutingClientWiringTarget,
        settings: SettingsManager,
        restartGateway: (() async -> Void)? = nil
    ) async {
        await wireAndProbe(
            target: target,
            settings: settings,
            restartGateway: restartGateway,
            busyState: .syncingModels
        )
    }

    private func wireAndProbe(
        target: RoutingClientWiringTarget,
        settings: SettingsManager,
        restartGateway: (() async -> Void)?,
        busyState: AppConnectState
    ) async {
        guard appStates[target]?.isBusy != true else { return }
        appStates[target] = busyState
        ensureLocalGateway(settings: settings)
        if let restartGateway {
            await restartGateway()
        }
        let gateway = makeGateway(from: settings)
        let wiring = wiringFactory()
        let advertisedModels = await wiring.advertisedModels(gateway: gateway)

        do {
            _ = try wiring.wire(
                target: target,
                gateway: gateway,
                advertisedModels: advertisedModels
            )
        } catch {
            appStates[target] = .error(message: error.localizedDescription)
            return
        }

        let probe = await wiring.probe(
            target: target,
            gateway: gateway,
            advertisedModels: advertisedModels
        )
        switch probe {
        case .ok, .skipped:
            appStates[target] = .connected
        case .failed(let status, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = trimmed.isEmpty
                ? "Local gateway test failed with HTTP \(status)."
                : "Local gateway returned HTTP \(status). \(trimmed)"
            appStates[target] = .degraded(message: detail)
        }
    }

    /// Re-probe a connected row. Used by the `Test` action.
    func test(
        target: RoutingClientWiringTarget,
        settings: SettingsManager
    ) async {
        appStates[target] = .probing
        let gateway = makeGateway(from: settings)
        let wiring = wiringFactory()
        let advertisedModels = await wiring.advertisedModels(gateway: gateway)
        let probe = await wiring.probe(
            target: target,
            gateway: gateway,
            advertisedModels: advertisedModels
        )
        switch probe {
        case .ok, .skipped:
            appStates[target] = .connected
        case .failed(let status, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = trimmed.isEmpty
                ? "Local gateway test failed with HTTP \(status)."
                : "Local gateway returned HTTP \(status). \(trimmed)"
            appStates[target] = .degraded(message: detail)
        }
    }

    /// Remove the OpenBurnBar wiring from a CLI's config file. Intentionally
    /// does **not** disable the gateway — other apps may still be wired.
    func disconnect(target: RoutingClientWiringTarget) async {
        do {
            try wiringFactory().unwire(target: target)
            appStates[target] = .notConnected
        } catch {
            appStates[target] = .error(message: error.localizedDescription)
        }
    }

    // MARK: - Snippet sheet

    func snippet(
        for target: RoutingClientWiringTarget,
        settings: SettingsManager
    ) -> String {
        wiringFactory().shellSnippet(target: target, gateway: makeGateway(from: settings))
    }

    func copySnippet(
        for target: RoutingClientWiringTarget,
        settings: SettingsManager
    ) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(snippet(for: target, settings: settings), forType: .string)
        copiedSnippetTarget = target
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard let self else { return }
            if self.copiedSnippetTarget == target { self.copiedSnippetTarget = nil }
        }
    }

    func revealConfigFile(target: RoutingClientWiringTarget) {
        let url = wiringFactory().configURL(for: target)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func configPath(for target: RoutingClientWiringTarget) -> String {
        wiringFactory().configURL(for: target).path
    }

    // MARK: - Proxy catalog

    func refreshProxyModelCatalog(settings: SettingsManager) async {
        guard !proxyModelCatalogState.isLoading else { return }
        proxyModelCatalogState = .loading
        let gateway = makeGateway(from: settings)
        do {
            let models = try await proxyCatalogFetcher(gateway)
            proxyModels = models.sorted {
                if $0.providerName.localizedCaseInsensitiveCompare($1.providerName) != .orderedSame {
                    return $0.providerName.localizedCaseInsensitiveCompare($1.providerName) == .orderedAscending
                }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            proxyModelCatalogState = .loaded(lastRefresh: Date())
        } catch {
            proxyModels = []
            proxyModelCatalogState = .error(message: Self.catalogErrorDescription(error), lastAttempt: Date())
        }
    }

    func enableLocalGateway(settings: SettingsManager) {
        ensureLocalGateway(settings: settings)
    }

    private func refreshDroidModelSyncState(settings: SettingsManager) async {
        guard appStates[.droid]?.isBusy != true else { return }
        let gateway = makeGateway(from: settings)
        let wiring = wiringFactory()
        guard wiring.isWired(target: .droid) else { return }
        let advertisedModels = proxyModels.isEmpty
            ? await wiring.advertisedModels(gateway: gateway)
            : proxyModels
                .filter { $0.advertised && $0.routeEligible }
                .map(RoutingClientAdvertisedModel.init(proxyModel:))
        guard !advertisedModels.isEmpty else { return }

        switch wiring.modelSyncStatus(
            target: .droid,
            gateway: gateway,
            advertisedModels: advertisedModels
        ) {
        case .current:
            if case .degraded(let message) = appStates[.droid],
               message.contains("Droid's BurnBar model list is stale") {
                appStates[.droid] = .connected
            }
        case .stale:
            appStates[.droid] = .degraded(message: "Droid's BurnBar model list is stale. Press Sync models to rewrite Droid from BurnBar's live /v1/models catalog.")
        case .notWired:
            appStates[.droid] = .notConnected
        }
    }

    private static func fetchProxyModels(gateway: RoutingClientGateway) async throws -> [ProxyAdvertisedModel] {
        guard let catalogURL = URL(string: gateway.baseURL)?.appending(path: "v1/models/catalog"),
              let publicURL = URL(string: gateway.baseURL)?.appending(path: "v1/models") else {
            throw ProxyModelCatalogError.invalidGatewayURL
        }

        do {
            return try await fetchProxyModels(url: catalogURL, gateway: gateway)
        } catch ProxyModelCatalogError.http(let status, _) where status == 404 {
            return try await fetchProxyModels(url: publicURL, gateway: gateway)
        }
    }

    private static func fetchProxyModels(
        url: URL,
        gateway: RoutingClientGateway
    ) async throws -> [ProxyAdvertisedModel] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        if !gateway.authToken.isEmpty {
            request.setValue("Bearer \(gateway.authToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProxyModelCatalogError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = Self.gatewayErrorMessage(from: data)
            throw ProxyModelCatalogError.http(status: http.statusCode, message: message)
        }
        let envelope: ProxyModelEnvelope
        do {
            envelope = try JSONDecoder().decode(ProxyModelEnvelope.self, from: data)
        } catch {
            throw ProxyModelCatalogError.decoding
        }
        return envelope.data.compactMap(ProxyAdvertisedModel.init(row:))
    }

    private static func gatewayErrorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["error"] as? String
    }

    private static func catalogErrorDescription(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return description
        }
        return error.localizedDescription
    }

    // MARK: - Helpers

    private func makeGateway(from settings: SettingsManager) -> RoutingClientGateway {
        RoutingClientGateway(
            host: settings.gatewayHost,
            port: settings.gatewayPort,
            authToken: settings.gatewayAuthToken
        )
    }

    /// Flip the gateway on with safe loopback defaults so the user never has
    /// to think about Daemon → HTTP Gateway just to wire their first CLI.
    private func ensureLocalGateway(settings: SettingsManager) {
        if settings.gatewayEnabled,
           !settings.gatewayHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           settings.gatewayPort > 0 {
            return
        }
        settings.gatewayHost = "127.0.0.1"
        settings.gatewayPort = 8317
        settings.gatewayEnabled = true
    }
}

private enum ProxyModelCatalogError: LocalizedError {
    case invalidGatewayURL
    case invalidResponse
    case decoding
    case http(status: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidGatewayURL:
            return "The local gateway URL is not valid."
        case .invalidResponse:
            return "The local gateway did not return a valid HTTP response."
        case .decoding:
            return "The local gateway returned a malformed /v1/models catalog."
        case .http(let status, let message):
            if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "The local gateway returned HTTP \(status). \(message)"
            }
            return "The local gateway returned HTTP \(status)."
        }
    }
}

private struct ProxyModelEnvelope: Decodable {
    let data: [ProxyModelRow]
}

private struct ProxyModelRow: Decodable {
    let id: String
    let ownedBy: String?
    let providerID: String?
    let providerName: String?
    let accountID: String?
    let accountLabel: String?
    let sourceID: String?
    let sourceKind: String?
    let displayName: String?
    let capabilities: [String]?
    let quotaState: String?
    let enabled: Bool?
    let advertisementEnabled: Bool?
    let advertised: Bool?
    let routeEligible: Bool?
    let lastError: String?

    enum CodingKeys: String, CodingKey {
        case id
        case ownedBy = "owned_by"
        case providerID = "provider_id"
        case providerName = "provider_name"
        case accountID = "account_id"
        case accountLabel = "account_label"
        case sourceID = "source_id"
        case sourceKind = "source_kind"
        case displayName = "display_name"
        case capabilities
        case quotaState = "quota_state"
        case enabled
        case advertisementEnabled = "advertisement_enabled"
        case advertised
        case routeEligible = "route_eligible"
        case lastError = "last_error"
    }
}

private extension ProxyAdvertisedModel {
    init?(row: ProxyModelRow) {
        let modelID = row.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else { return nil }
        let providerID = (row.providerID ?? row.ownedBy ?? "openburnbar")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelID = modelID
        self.displayName = (row.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? modelID
        self.providerID = providerID.isEmpty ? "openburnbar" : providerID
        self.providerName = (row.providerName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? self.providerID
        self.accountID = (row.accountID?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        self.accountLabel = (row.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? self.accountID
        self.sourceID = (row.sourceID?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "\(self.providerID)#\(self.accountID)"
        self.sourceKind = (row.sourceKind?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "gateway"
        self.quotaState = (row.quotaState?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        self.advertisementEnabled = row.advertisementEnabled ?? true
        self.advertised = row.advertised ?? (self.advertisementEnabled && (row.routeEligible ?? (row.enabled == true)))
        self.routeEligible = row.routeEligible ?? (row.enabled == true)
        self.capabilities = row.capabilities ?? []
        self.lastError = row.lastError
    }
}

private extension RoutingClientAdvertisedModel {
    init(proxyModel: ProxyAdvertisedModel) {
        self.init(
            id: proxyModel.modelID,
            displayName: proxyModel.displayName,
            providerID: proxyModel.providerID,
            providerName: proxyModel.providerName,
            routeEligible: proxyModel.routeEligible
        )
    }
}

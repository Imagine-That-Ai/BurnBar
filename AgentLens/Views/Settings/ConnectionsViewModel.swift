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
    case connected
    case probing
    case degraded(message: String)
    case error(message: String)

    var isBusy: Bool {
        switch self {
        case .connecting, .probing: return true
        default: return false
        }
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

    private let wiringFactory: () -> RoutingClientWiring

    init(wiringFactory: @escaping () -> RoutingClientWiring = { RoutingClientWiring() }) {
        self.wiringFactory = wiringFactory
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
            case .connecting, .probing:
                continue
            default:
                appStates[target] = wired ? .connected : .notConnected
            }
        }
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
        settings: SettingsManager
    ) async {
        appStates[target] = .connecting
        ensureLocalGateway(settings: settings)
        let gateway = makeGateway(from: settings)

        do {
            _ = try wiringFactory().wire(target: target, gateway: gateway)
        } catch {
            appStates[target] = .error(message: error.localizedDescription)
            return
        }

        let probe = await wiringFactory().probe(target: target, gateway: gateway)
        switch probe {
        case .ok, .skipped:
            appStates[target] = .connected
        case .failed(let status, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = trimmed.isEmpty
                ? "Local gateway didn't answer (HTTP \(status))."
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
        let probe = await wiringFactory().probe(target: target, gateway: gateway)
        switch probe {
        case .ok, .skipped:
            appStates[target] = .connected
        case .failed(let status, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = trimmed.isEmpty
                ? "Local gateway didn't answer (HTTP \(status))."
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

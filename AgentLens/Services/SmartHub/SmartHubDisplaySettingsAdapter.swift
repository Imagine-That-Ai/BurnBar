import Foundation
import OpenBurnBarCore
import AppKit

// MARK: - macOS Smart Hub Display Adapter
//
// Bridges the cross-platform `SmartHubDisplayOperations` protocol used
// by `SmartHubDisplaySettingsModel` to the Mac's actual bridge surface:
// `SettingsManager` (persistence), `SmartHubBridgeServer` (HTTP listener),
// and `SmartHubBridgeController` (refresh/snapshot pump).
//
// Test, Identify, Refresh, Stop, and Open all funnel through here so
// the UI can stay platform-agnostic.

@MainActor
final class MacSmartHubDisplayOperationsAdapter: SmartHubDisplayOperations {

    private let settingsManager: SettingsManager
    private weak var controller: SmartHubBridgeController?
    private weak var repairCoordinator: SmartDisplayRepairCoordinator?

    init(
        settingsManager: SettingsManager,
        controller: SmartHubBridgeController?,
        repairCoordinator: SmartDisplayRepairCoordinator? = nil
    ) {
        self.settingsManager = settingsManager
        self.controller = controller
        self.repairCoordinator = repairCoordinator
    }

    func updateDisplayConfig(_ config: SmartHubDisplayConfig) async {
        var next = config
        next.updatedAt = Date()
        if settingsManager.smartHubDisplayConfig != next {
            settingsManager.smartHubDisplayConfig = next
        }
        // Bridge server picks up the new config on the next 2s polling
        // sweep of the controller, but we forward it directly so the
        // very next /state.json reflects the user's edit.
        SmartHubBridgeServer.shared.updateDisplayConfig(next)
    }

    func testBridge() async -> SmartHubBridgeProbeStatus {
        guard let controller else { return .unknown }
        return controller.bridgeProbeStatus()
    }

    func refreshNow() async {
        guard let controller else {
            SmartHubBridgeServer.shared.bumpRefresh()
            return
        }
        _ = await controller.performForcedRefresh()
    }

    func repairDisplay() async -> SmartDisplayDeviceRepairStatus {
        if let repairCoordinator {
            return await repairCoordinator.repairNestHub()
        }
        if let controller {
            return await controller.repairNestHubDisplay()
        }
        return SmartDisplayDeviceRepairStatus(
            kind: .nestHub,
            phase: .failed,
            message: "Mac smart display controller is not running.",
            proof: "missing_controller"
        )
    }

    func identify() async {
        let url = URL(string: settingsManager.smartHubQuotaVoiceRefreshURL)
        guard let url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 5
        _ = try? await URLSession.shared.data(for: request)
    }

    func stopBridge() async {
        settingsManager.smartHubQuotaDisplayEnabled = false
        SmartHubBridgeServer.shared.stop()
    }

    func openInBrowser() async {
        let url = controller?.resolvedDashboardURL()
            ?? URL(string: settingsManager.smartHubQuotaDashboardURL)
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    func copyVoiceRoutineURL() async {
        let raw = settingsManager.smartHubQuotaVoiceRefreshURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(raw, forType: .string)
    }
}

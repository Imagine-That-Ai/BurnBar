import Foundation
import OpenBurnBarCore

// MARK: - Cast Wizard Model
//
// State machine that drives the macOS Setup Cast Wizard. Owns the
// discovery scanner, the channel client (during testing), and the
// final "save selection" step which writes back into SettingsManager.
//
// The view layer reads `state`, `devices`, and `selectedDevice` and
// dispatches into `start()`, `pickDevice(_:)`, `confirmTestPattern()`,
// `tryAnother()`, `cancel()`. Everything else is internal.

@MainActor
@Observable
final class CastWizardModel {

    enum Step: Equatable {
        case welcome
        case discover
        case noDevices
        case pick
        case testing(CastDevice)
        case recover(CastDevice, attempt: Int, lastError: String)
        case confirm(CastDevice)
        case failed(String)
        case done(CastDevice)
    }

    private(set) var step: Step = .welcome
    private(set) var devices: [CastDevice] = []

    private var discovery: CastDiscovery?
    private let settingsManager: SettingsManager?
    private let bridgeURLProvider: () -> URL?
    private var homeAssistantRecoveryWebhookURL: URL? {
        guard let raw = settingsManager?.smartHubHomeAssistantRecoveryWebhookURL
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private var noDevicesTimeoutTask: Task<Void, Never>?

    init(
        settingsManager: SettingsManager? = nil,
        bridgeURLProvider: @escaping () -> URL? = { CastWizardModel.defaultBridgeURL() }
    ) {
        self.settingsManager = settingsManager
        self.bridgeURLProvider = bridgeURLProvider
    }

    // MARK: - User intents

    func start() {
        step = .discover
        devices = []
        let scanner = CastDiscovery(onUpdate: { [weak self] updated in
            self?.handleDiscoveredDevices(updated)
        })
        scanner.start()
        discovery = scanner

        noDevicesTimeoutTask?.cancel()
        noDevicesTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self else { return }
            if case .discover = self.step, self.devices.isEmpty {
                self.step = .noDevices
            }
        }
    }

    func retryDiscovery() {
        cancelDiscovery()
        start()
    }

    func pickDevice(_ device: CastDevice) {
        guard let url = bridgeURLProvider() else {
            step = .failed("Smart Display bridge URL is not configured.")
            return
        }
        step = .testing(device)
        Task { [weak self] in
            guard let self else { return }
            let strategy = CastReconnectStrategy(
                device: device,
                homeAssistantWebhookURL: self.homeAssistantRecoveryWebhookURL
            )
            let result = await strategy.castWithRecovery(url: url)
            switch result {
            case .success, .recoveredViaHomeAssistant:
                self.step = .confirm(device)
            case .failure(let reason, let attempts):
                self.step = .recover(device, attempt: attempts, lastError: reason)
            }
        }
    }

    func retryDevice() {
        guard case let .recover(device, _, _) = step else { return }
        pickDevice(device)
    }

    func tryAnother() {
        step = .pick
    }

    func confirmTestPattern() {
        guard case let .confirm(device) = step else { return }
        if let settings = settingsManager {
            settings.castSelectedDeviceServiceName = device.serviceName
            settings.castSelectedDeviceFriendlyName = device.friendlyName
            settings.castSelectedDeviceModel = device.model
            settings.castSelectedDeviceHost = device.host
            settings.castSelectedDevicePort = device.port
            settings.castSelectedDeviceIdentifier = device.identifier
            settings.castSelectedDeviceSupportsDisplay = device.supportsDisplay
            // Auto-fill the four legacy URL fields so existing pipelines
            // (Firestore publisher, refresh button, etc.) just work.
            if let url = bridgeURLProvider() {
                settings.smartHubQuotaDashboardURL = url.absoluteString
                let base = url.deletingLastPathComponent()
                settings.smartHubQuotaRefreshURL = base.appendingPathComponent("refresh").absoluteString
                settings.smartHubQuotaVoiceRefreshURL = base.appendingPathComponent("voice-refresh").absoluteString
            }
            settings.smartHubQuotaDisplayEnabled = true
        }
        step = .done(device)
    }

    func cancel() {
        cancelDiscovery()
        step = .welcome
    }

    // MARK: - Internal

    private func handleDiscoveredDevices(_ list: [CastDevice]) {
        devices = list
        if !list.isEmpty {
            switch step {
            case .discover, .noDevices:
                step = .pick
            default:
                break
            }
        }
    }

    private func cancelDiscovery() {
        discovery?.stop()
        discovery = nil
        noDevicesTimeoutTask?.cancel()
        noDevicesTimeoutTask = nil
    }

    // MARK: - Defaults

    /// Resolve the LAN URL the bridge is reachable at. Cast devices tend
    /// to resolve raw LAN IPs more reliably than Mac hostnames, so prefer
    /// a non-loopback IPv4 and keep `.local` as a fallback candidate.
    static func defaultBridgeURL() -> URL? {
        LocalNetworkDiscovery.dashboardURLCandidates().first
    }
}

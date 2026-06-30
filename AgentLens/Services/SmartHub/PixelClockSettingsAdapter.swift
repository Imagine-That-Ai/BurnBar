import Foundation
import AppKit
import OpenBurnBarCore

// MARK: - macOS Pixel Clock Operations Adapter
//
// Bridges the cross-platform `PixelClockOperations` protocol used by the
// SwiftUI settings card to the existing `PixelClockController` on macOS.
//
// The adapter persists config changes back to `SettingsManager` so the
// running controller picks them up on its next pump and the
// `SmartDisplayConfigPublisher` mirrors them to Firestore for the
// companion iOS app.

@MainActor
final class MacPixelClockOperationsAdapter: PixelClockOperations {
    private let settingsManager: SettingsManager
    private weak var controller: PixelClockController?
    private var fallbackController: PixelClockController?
    private let allowsFallbackController: Bool

    init(
        settingsManager: SettingsManager,
        controller: PixelClockController?,
        allowsFallbackController: Bool = true
    ) {
        self.settingsManager = settingsManager
        self.controller = controller
        self.allowsFallbackController = allowsFallbackController
    }

    func probePixelClock(config: PixelClockConfig) async -> PixelClockProbeStatus {
        persist(config)
        guard let controller = resolvedController() else {
            return settingsManager.pixelClockConfig.lastProbeStatus
        }
        let result = await controller.probePixelClock()
        return result.status
    }

    func preparePixelClock(config: PixelClockConfig) async throws -> PixelClockSetupResult {
        persist(config)
        guard let controller = resolvedController() else {
            return PixelClockSetupResult(
                mode: .unreachable,
                probeStatus: settingsManager.pixelClockConfig.lastProbeStatus,
                message: "Pixel Clock controller is unavailable.",
                clockHost: settingsManager.pixelClockConfig.host
            )
        }
        return try await controller.preparePixelClock()
    }

    func flashPixelClockFirmware(config: PixelClockConfig, wifiCredentials: PixelClockWiFiCredentials?) async throws -> PixelClockSetupResult {
        persist(config)
        guard let controller = resolvedController() else {
            throw NSError(domain: "PixelClock", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Pixel Clock controller is unavailable."
            ])
        }
        let hasUSBSetupPort = await PixelClockFirmwareFlasher.hasSetupCandidateSerialDevice()
        guard hasUSBSetupPort else {
            let visibleSetupSSID = await PixelClockNetworkProvisioner.visibleSetupSSID()
            let setupNetworkGuidance = visibleSetupSSID.map {
                " OpenBurnBar can see setup Wi-Fi \($0), but it will not send Wi-Fi credentials to a setup network unless it was just bound to this Mac by USB flashing."
            } ?? ""
            throw NSError(domain: "PixelClock", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "No Pixel Clock setup path found. The TC001 can be powered by its battery or a charge-only cable without exposing USB data to the Mac. " +
                    "Put the clock on Wi-Fi or connect it directly with a data-capable USB cable.\(setupNetworkGuidance)"
            ])
        }
        let credentials = try wifiCredentials ?? Self.promptForWiFiCredentials()
        return try await controller.flashPixelClockFirmware(wifiCredentials: credentials)
    }

    func testPixelClock(config: PixelClockConfig) async throws {
        persist(config)
        guard let controller = resolvedController() else {
            throw NSError(domain: "PixelClock", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Pixel Clock controller is unavailable."
            ])
        }
        try await controller.testPixelClock()
    }

    func pushPixelClockNow(config: PixelClockConfig) async throws {
        persist(config)
        guard let controller = resolvedController() else {
            throw NSError(domain: "PixelClock", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Pixel Clock controller is unavailable."
            ])
        }
        try await controller.pushPixelClockNow()
    }

    func removePixelClockApp(config: PixelClockConfig) async throws {
        persist(config)
        guard let controller = resolvedController() else {
            throw NSError(domain: "PixelClock", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Pixel Clock controller is unavailable."
            ])
        }
        try await controller.removePixelClockApp()
    }

    func updatePixelClockConfig(_ config: PixelClockConfig) async {
        persist(config)
    }

    private func persist(_ config: PixelClockConfig) {
        var next = config
        next.updatedAt = Date()
        if settingsManager.pixelClockConfig != next {
            settingsManager.pixelClockConfig = next
        }
    }

    private func resolvedController() -> PixelClockController? {
        if let controller { return controller }
        if let fallbackController { return fallbackController }
        guard allowsFallbackController else { return nil }
        let fallback = PixelClockController(
            settingsManager: settingsManager,
            quotaService: nil
        )
        fallback.start()
        fallbackController = fallback
        return fallback
    }

    private static func promptForWiFiCredentials() throws -> PixelClockWiFiCredentials {
        let alert = NSAlert()
        alert.messageText = "Finish Pixel Clock setup"
        alert.informativeText = "Enter your 2.4 GHz Wi-Fi name and password once. OpenBurnBar will flash the USB-connected Pixel Clock, join only that verified setup Wi-Fi, send Wi-Fi, reconnect, and push the display."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Finish Setup")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 72)

        let ssid = NSTextField(string: PixelClockNetworkProvisioner.currentWiFiSSID() ?? "")
        ssid.placeholderString = "Wi-Fi name"
        let password = NSSecureTextField(string: "")
        password.placeholderString = "Wi-Fi password"
        stack.addArrangedSubview(ssid)
        stack.addArrangedSubview(password)
        alert.accessoryView = stack

        guard alert.runModal() == .alertFirstButtonReturn else {
            throw NSError(domain: "PixelClock", code: 3, userInfo: [NSLocalizedDescriptionKey: "Pixel Clock setup was cancelled."])
        }
        let trimmedSSID = ssid.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSSID.isEmpty, !password.stringValue.isEmpty else {
            throw NSError(domain: "PixelClock", code: 4, userInfo: [NSLocalizedDescriptionKey: "Wi-Fi name and password are required to finish Pixel Clock setup."])
        }
        return PixelClockWiFiCredentials(ssid: trimmedSSID, password: password.stringValue)
    }
}

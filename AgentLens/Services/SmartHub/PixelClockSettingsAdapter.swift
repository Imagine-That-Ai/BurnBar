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

    init(settingsManager: SettingsManager, controller: PixelClockController?) {
        self.settingsManager = settingsManager
        self.controller = controller
    }

    func probePixelClock(config: PixelClockConfig) async -> PixelClockProbeStatus {
        persist(config)
        let controller = resolvedController()
        let result = await controller.probePixelClock()
        return result.status
    }

    func preparePixelClock(config: PixelClockConfig) async throws -> PixelClockSetupResult {
        persist(config)
        let controller = resolvedController()
        return try await controller.preparePixelClock()
    }

    func flashPixelClockFirmware(config: PixelClockConfig, wifiCredentials: PixelClockWiFiCredentials?) async throws -> PixelClockSetupResult {
        persist(config)
        let controller = resolvedController()
        let hasUSBSetupPort = await PixelClockFirmwareFlasher.hasSetupCandidateSerialDevice()
        let visibleSetupSSID = await PixelClockNetworkProvisioner.visibleSetupSSID()
        guard hasUSBSetupPort || visibleSetupSSID != nil else {
            throw NSError(domain: "PixelClock", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "No Pixel Clock setup path found. The TC001 can be powered by its battery or a charge-only cable without exposing USB data to the Mac. Put the clock on Wi-Fi, connect it directly with a data-capable USB cable, or reboot it until the AWTRIX setup Wi-Fi appears."
            ])
        }
        let credentials = try wifiCredentials ?? Self.promptForWiFiCredentials()
        return try await controller.flashPixelClockFirmware(wifiCredentials: credentials)
    }

    func testPixelClock(config: PixelClockConfig) async throws {
        persist(config)
        let controller = resolvedController()
        try await controller.testPixelClock()
    }

    func pushPixelClockNow(config: PixelClockConfig) async throws {
        persist(config)
        let controller = resolvedController()
        try await controller.pushPixelClockNow()
    }

    func removePixelClockApp(config: PixelClockConfig) async throws {
        persist(config)
        let controller = resolvedController()
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

    private func resolvedController() -> PixelClockController {
        if let controller { return controller }
        if let fallbackController { return fallbackController }
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
        alert.informativeText = "Enter your 2.4 GHz Wi-Fi name and password once. OpenBurnBar will use USB or the AWTRIX setup Wi-Fi, send Wi-Fi, reconnect, and push the display."
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

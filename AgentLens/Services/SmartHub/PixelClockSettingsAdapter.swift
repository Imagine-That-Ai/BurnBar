import Foundation
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
}

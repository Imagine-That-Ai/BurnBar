import Foundation
import OpenBurnBarCore

// MARK: - iOS Pixel Clock Operations Adapter
//
// Bridges the cross-platform `PixelClockOperations` protocol used by the
// SwiftUI settings card to the Firestore-backed `SmartHubStore` on iOS.
// All commands are forwarded as `smart_display_actions/{uuid}` documents
// the Mac listens for; the Mac performs the AWTRIX HTTP work and writes
// status back.

@MainActor
final class MobilePixelClockOperationsAdapter: PixelClockOperations {
    private let store: SmartHubStore

    init(store: SmartHubStore) {
        self.store = store
    }

    func probePixelClock(config: PixelClockConfig) async -> PixelClockProbeStatus {
        let outcome = (try? await store.probePixelClock()) ?? .failed("Mac unavailable")
        return Self.probeStatus(
            for: outcome,
            actionData: store.lastPublishedActionData,
            currentConfig: store.config?.pixelClock ?? config
        )
    }

    func preparePixelClock(config: PixelClockConfig) async throws -> PixelClockSetupResult {
        let outcome = try await store.preparePixelClock()
        try Self.throwIfFailed(outcome)
        let latest = store.config?.pixelClock ?? config
        let actionData = store.lastPublishedActionData
        let probeStatus = Self.probeStatusValue(
            from: actionData["probeStatus"],
            fallback: latest.lastProbeStatus
        )
        let mode = Self.setupMode(
            from: actionData["setupMode"],
            fallback: probeStatus == .awtrixReady ? .awtrixLightReady : .needsAwtrixLightFlash
        )
        return PixelClockSetupResult(
            mode: mode,
            probeStatus: probeStatus,
            message: actionData["message"] as? String ?? "Mac accepted the Pixel Clock setup request.",
            clockHost: latest.host,
            suggestedServerHost: actionData["suggestedServerHost"] as? String,
            suggestedServerPort: Self.intValue(from: actionData["suggestedServerPort"]),
            flasherURL: actionData["flasherURL"] as? String
        )
    }

    func testPixelClock(config: PixelClockConfig) async throws {
        let outcome = try await store.testPixelClock()
        try Self.throwIfFailed(outcome)
    }

    func pushPixelClockNow(config: PixelClockConfig) async throws {
        let outcome = try await store.pushPixelClockNow()
        try Self.throwIfFailed(outcome)
    }

    func removePixelClockApp(config: PixelClockConfig) async throws {
        let outcome = try await store.removePixelClockApp()
        try Self.throwIfFailed(outcome)
    }

    func updatePixelClockConfig(_ config: PixelClockConfig) async {
        await store.updatePixelClockConfig(config)
    }

    // MARK: - Helpers

    private static func probeStatus(
        for outcome: SmartHubStore.WizardActionStatus,
        actionData: [String: Any],
        currentConfig: PixelClockConfig
    ) -> PixelClockProbeStatus {
        switch outcome {
        case .completed:
            return probeStatusValue(
                from: actionData["probeStatus"],
                fallback: currentConfig.lastProbeStatus == .unknown ? .awtrixReady : currentConfig.lastProbeStatus
            )
        case .pending:
            return .unknown
        case .failed(let message):
            return message.localizedCaseInsensitiveContains("stock")
                ? .stockUlanziFirmware
                : .unreachable
        }
    }

    private static func throwIfFailed(_ outcome: SmartHubStore.WizardActionStatus) throws {
        if case .failed(let message) = outcome {
            throw NSError(domain: "PixelClock", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private static func setupMode(from value: Any?, fallback: PixelClockSetupMode) -> PixelClockSetupMode {
        guard let raw = value as? String else { return fallback }
        return PixelClockSetupMode(rawValue: raw) ?? fallback
    }

    private static func probeStatusValue(from value: Any?, fallback: PixelClockProbeStatus?) -> PixelClockProbeStatus {
        guard let raw = value as? String else { return fallback ?? .unknown }
        return PixelClockProbeStatus(rawValue: raw) ?? fallback ?? .unknown
    }

    private static func intValue(from value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }
}

import Foundation
import SwiftUI
@testable import OpenBurnBar

// MARK: - FakeAccountManager

@MainActor
final class FakeAccountManager: AccountManaging {
    var isSignedIn = false
    var isCloudSyncEnabled = true
    var isFirebaseAvailable = true
    var deviceId = "test-device-1"
    var currentUser: User? = nil

    static func makeSignedIn(uid: String = "test-uid-1") -> FakeAccountManager {
        let manager = FakeAccountManager()
        manager.isSignedIn = true
        manager.isFirebaseAvailable = true
        manager.isCloudSyncEnabled = true
        return manager
    }
}

// MARK: - FakeSettingsManager

@MainActor
final class FakeSettingsManager: SettingsManagerProtocol {
    var appearanceMode: AppearanceMode = .system
    var preferredSwiftUIColorScheme: ColorScheme? = nil
    var refreshInterval: TimeInterval = 60
    var showInMenuBar = true
    var launchAtLogin = false
    var defaultTimeRange: TimeRange = .day
    var costAlertThreshold: Double? = nil
    var dailyDigestEnabled = false
    var dailyDigestHour = 9
    var conversationIndexingEnabled = true
    var conversationIndexingConsentShown = false
    var indexEmbeddingProvider: IndexEmbeddingProviderID = .deterministic
    var indexOpenAIModel = "text-embedding-3-small"
    var conversationCloudBackupEnabled = true
    var iCloudSessionMirrorEnabled = false
    var sessionLogCloudBackupEnabled = true
    var sessionLogCloudBackupConsentShown = true
    var showSourceArtifactDotFiles = false
    var showSourceArtifactNestedPaths = false
    var dailyDigestCostThreshold: Double? = nil
    var themeName: String? = nil
    var customAccentColorHex: String? = nil
    var codeFontName: String? = nil
    var codeFontSize: CGFloat = 12
    var analyticsConsentShown = false
    var analyticsEnabled = false
    var openAIFavorites: [String] = []
    var claudeFavorites: [String] = []
    var geminiFavorites: [String] = []
    var grokFavorites: [String] = []
    var localFavorites: [String] = []

    func resetToDefaults() {}
}

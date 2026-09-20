import Foundation
import OpenBurnBarCore

/// Domain slices of `SettingsManagerProtocol` matching the Settings/Stores types.
/// Callers that only need one store can depend on the narrow protocol.

@MainActor
protocol AppearanceSettingsManaging: AnyObject, Sendable {
    var appearanceMode: AppearanceMode { get set }
    var desktopWallpaperProviderGlyphs: [AgentProvider] { get set }
    var excludeBrandShapesFromSwarm: Bool { get set }
}

@MainActor
protocol BehaviorSettingsManaging: AnyObject, Sendable {
    var refreshInterval: TimeInterval { get set }
    var showInMenuBar: Bool { get set }
    var colorfulMenuBarIcon: Bool { get set }
    var launchAtLogin: Bool { get set }
    var defaultTimeRange: TimeRange { get set }
    var refreshIntervalMinutes: Double { get set }
}

@MainActor
protocol IndexSettingsManaging: AnyObject, Sendable {
    var conversationIndexingEnabled: Bool { get set }
    var conversationIndexingConsentShown: Bool { get set }
    var indexEmbeddingProvider: IndexEmbeddingProviderID { get set }
    var indexOpenAIModel: String { get set }
    var preferredIndexEmbeddingVersionIDValue: String? { get }
}

@MainActor
protocol CloudSyncSettingsManaging: AnyObject, Sendable {
    var conversationCloudBackupEnabled: Bool { get set }
    var iCloudSessionMirrorEnabled: Bool { get set }
    var sessionLogCloudBackupEnabled: Bool { get set }
    var conversationBackupEnabled: Bool { get set }
    var conversationFacetBackfillVersion: Int { get set }
    var sessionLogCloudBackupConsentShown: Bool { get set }
    var chatThreadContentCloudBackupEnabled: Bool { get set }
    var chatThreadContentCloudBackupConsentShown: Bool { get set }
    var textExpansionCloudSyncEnabled: Bool { get }
    var memoryApprovedCloudBackupOptIn: Bool { get set }
    var memoryApprovedCloudBackupEnabled: Bool { get }
}

@MainActor
protocol ChatBackendSettingsManaging: AnyObject, Sendable {
    var chatBackendOnboardingCompleted: Bool { get set }
    var hermesSetupWizardCompleted: Bool { get set }
    var enabledChatBackendIDsCSV: String { get set }
    var openClawGatewayBaseURL: String { get set }
    var openClawBearerToken: String { get set }
    var hermesBearerToken: String { get set }
    var hermesChatModelOverride: String { get set }
    var hermesGatewayBaseURL: String { get set }
    var hermesRemoteRelayEnabled: Bool { get set }
    var hermesRealtimeRelayURL: String { get set }
    var hermesIrohTransportEnabled: Bool { get set }
    var launchHermesWithOpenBurnBar: Bool { get set }
    var piAgentGatewayBaseURL: String { get set }
    var piAgentBearerToken: String { get set }
    var piAgentRedisURL: String { get set }
    var piAgentSelectedInstanceID: String { get set }
    var piAgentChatModelOverride: String { get set }
    var launchPiAgentsWithOpenBurnBar: Bool { get set }
    var piRemoteRelayEnabled: Bool { get set }
    var piRealtimeRelayURL: String { get set }
    var enabledChatBackends: [ChatBackendID] { get }
    var enabledHermesModels: [HermesModelID] { get }
    var selectedHermesModel: HermesModelID? { get set }
    func setEnabledChatBackends(_ backends: [ChatBackendID])
    func setChatBackendEnabled(_ id: ChatBackendID, enabled: Bool)
    func setEnabledHermesModels(_ models: [HermesModelID])
    func setHermesModelEnabled(_ id: HermesModelID, enabled: Bool)
    func applyHermesModelSelection(_ model: HermesModelID?)
    func resolvedHermesChatModel(gatewayAdvertisedModel: String?) -> String
    func resolvedPiChatModel(gatewayAdvertisedModel: String?) -> String
}

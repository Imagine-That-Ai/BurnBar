import Foundation
import OpenBurnBarCore

// MARK: - Chat Backend Settings

@Observable
@MainActor
final class ChatBackendSettings {
    private let persistence: SettingsPersistenceCoordinator
    private let secretPersistence: SettingsSecretPersistence

    var openClawGatewayBaseURL: String = "http://127.0.0.1:18789" {
        didSet { persistence.set(openClawGatewayBaseURL, forKey: "openClawGatewayBaseURL") }
    }

    var openClawBearerToken: String = "" {
        didSet {
            secretPersistence.persist(
                openClawBearerToken,
                account: OpenBurnBarIdentity.openClawBearerTokenAccount,
                legacyDefaultsKey: SettingsSecretDefaultsKey.openClawBearerToken
            )
        }
    }

    var hermesBearerToken: String = "" {
        didSet {
            secretPersistence.persist(
                hermesBearerToken,
                account: OpenBurnBarIdentity.hermesBearerTokenAccount,
                legacyDefaultsKey: SettingsSecretDefaultsKey.hermesBearerToken
            )
        }
    }

    var hermesChatModelOverride: String = "" {
        didSet { persistence.set(hermesChatModelOverride, forKey: "hermesChatModelOverride") }
    }

    var hermesGatewayBaseURL: String = "http://127.0.0.1:8642" {
        didSet { persistence.set(hermesGatewayBaseURL, forKey: "hermesGatewayBaseURL") }
    }

    var hermesRemoteRelayEnabled: Bool = false {
        didSet { persistence.set(hermesRemoteRelayEnabled, forKey: "hermesRemoteRelayEnabled") }
    }

    var hermesRealtimeRelayURL: String = HermesRealtimeRelayProtocol.defaultHostedRelayURLString {
        didSet { persistence.set(hermesRealtimeRelayURL, forKey: "hermesRealtimeRelayURL") }
    }

    var launchHermesWithOpenBurnBar: Bool = false {
        didSet { persistence.set(launchHermesWithOpenBurnBar, forKey: "launchHermesWithOpenBurnBar") }
    }

    var chatBackendOnboardingCompleted: Bool = false {
        didSet { persistence.set(chatBackendOnboardingCompleted, forKey: "chatBackendOnboardingCompleted") }
    }

    var hermesSetupWizardCompleted: Bool = false {
        didSet { persistence.set(hermesSetupWizardCompleted, forKey: "hermesSetupWizardCompleted") }
    }

    var switcherOnboardingCompleted: Bool = false {
        didSet { persistence.set(switcherOnboardingCompleted, forKey: "switcherOnboardingCompleted") }
    }

    var selectedOnboardingProvidersCSV: String = "" {
        didSet { persistence.set(selectedOnboardingProvidersCSV, forKey: "selectedOnboardingProvidersCSV") }
    }

    var enabledChatBackendIDsCSV: String = "" {
        didSet { persistence.set(enabledChatBackendIDsCSV, forKey: "enabledChatBackendIDsCSV") }
    }

    var enabledChatBackends: [ChatBackendID] {
        ChatBackendID.decodeEnabledList(fromCSV: enabledChatBackendIDsCSV)
    }

    var selectedOnboardingProviders: Set<AgentProvider> {
        get {
            let csv = selectedOnboardingProvidersCSV
            guard !csv.isEmpty else { return [] }
            return Set(csv.split(separator: ",").compactMap { token in
                AgentProvider.fromPersistedToken(String(token))
            })
        }
        set {
            // Persist a stable, lowercased, space-stripped canonical form so
            // future `rawValue` (display-name) renames don't invalidate
            // existing user data. Reads go through `fromPersistedToken`
            // which is case- and space-insensitive.
            selectedOnboardingProvidersCSV = newValue
                .map(\.persistedToken)
                .sorted()
                .joined(separator: ",")
        }
    }

    init(persistence: SettingsPersistenceCoordinator, secretPersistence: SettingsSecretPersistence) {
        self.persistence = persistence
        self.secretPersistence = secretPersistence
        self.openClawGatewayBaseURL = persistence.string(forKey: "openClawGatewayBaseURL", defaultValue: "http://127.0.0.1:18789")
        self.openClawBearerToken = secretPersistence.load(
            account: OpenBurnBarIdentity.openClawBearerTokenAccount,
            legacyDefaultsKey: SettingsSecretDefaultsKey.openClawBearerToken
        )
        self.hermesBearerToken = secretPersistence.load(
            account: OpenBurnBarIdentity.hermesBearerTokenAccount,
            legacyDefaultsKey: SettingsSecretDefaultsKey.hermesBearerToken
        )
        self.hermesChatModelOverride = persistence.string(forKey: "hermesChatModelOverride")
        self.hermesGatewayBaseURL = persistence.string(forKey: "hermesGatewayBaseURL", defaultValue: "http://127.0.0.1:8642")
        self.hermesRemoteRelayEnabled = persistence.bool(forKey: "hermesRemoteRelayEnabled")
        self.hermesRealtimeRelayURL = persistence.string(
            forKey: "hermesRealtimeRelayURL",
            defaultValue: HermesRealtimeRelayProtocol.defaultHostedRelayURLString
        )
        self.launchHermesWithOpenBurnBar = persistence.bool(forKey: "launchHermesWithOpenBurnBar")
        self.chatBackendOnboardingCompleted = persistence.bool(forKey: "chatBackendOnboardingCompleted")
        self.hermesSetupWizardCompleted = persistence.bool(forKey: "hermesSetupWizardCompleted")
        self.switcherOnboardingCompleted = persistence.bool(forKey: "switcherOnboardingCompleted")
        self.selectedOnboardingProvidersCSV = persistence.string(forKey: "selectedOnboardingProvidersCSV")
        if persistence.objectExists(forKey: "enabledChatBackendIDsCSV") {
            self.enabledChatBackendIDsCSV = persistence.string(forKey: "enabledChatBackendIDsCSV")
        } else {
            if let raw = persistence.optionalString(forKey: "chatBackendID"), let only = ChatBackendID(rawValue: raw) {
                self.enabledChatBackendIDsCSV = ChatBackendID.encodeEnabledList([only])
            } else {
                self.enabledChatBackendIDsCSV = ""
            }
        }
    }

    func setEnabledChatBackends(_ backends: [ChatBackendID]) {
        enabledChatBackendIDsCSV = ChatBackendID.encodeEnabledList(backends)
    }

    func setChatBackendEnabled(_ id: ChatBackendID, enabled: Bool) {
        var list = enabledChatBackends
        if enabled {
            if !list.contains(id) { list.append(id) }
        } else {
            list.removeAll { $0 == id }
        }
        setEnabledChatBackends(list)
    }

    static func resolvedHermesChatModel(override: String, gatewayAdvertisedModel: String?) -> String {
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        guard let advertised = gatewayAdvertisedModel?.trimmingCharacters(in: .whitespacesAndNewlines), !advertised.isEmpty else {
            return "hermes"
        }
        if advertised.range(of: "minimax", options: .caseInsensitive) != nil {
            return CLIBridge.normalizedCodexModel("gpt-5.5")
        }
        return "hermes"
    }

    func resolvedHermesChatModel(gatewayAdvertisedModel: String?) -> String {
        Self.resolvedHermesChatModel(override: hermesChatModelOverride, gatewayAdvertisedModel: gatewayAdvertisedModel)
    }
}

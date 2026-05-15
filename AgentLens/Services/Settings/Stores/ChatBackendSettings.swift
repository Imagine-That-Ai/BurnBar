import Foundation
import OpenBurnBarCore

struct HermesAdvertisedModel: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let displayName: String
    let family: HermesModelID
}

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

    /// Feature flag for the iroh peer-to-peer transport. Off by default so
    /// existing WSS-based relay traffic is untouched; flipping this on makes
    /// `HermesRelayHostService` publish a signed `iroh_pairing` record and
    /// makes `HermesService` prefer the iroh transport with WSS fallback.
    /// See `docs/HERMES_IROH_TRANSPORT.md`.
    var hermesIrohTransportEnabled: Bool = false {
        didSet { persistence.set(hermesIrohTransportEnabled, forKey: "hermesIrohTransportEnabled") }
    }

    var launchHermesWithOpenBurnBar: Bool = false {
        didSet { persistence.set(launchHermesWithOpenBurnBar, forKey: "launchHermesWithOpenBurnBar") }
    }

    // MARK: - Pi Agent Connection Profile

    var piAgentGatewayBaseURL: String = "http://127.0.0.1:8765" {
        didSet { persistence.set(piAgentGatewayBaseURL, forKey: "piAgentGatewayBaseURL") }
    }

    var piAgentBearerToken: String = "" {
        didSet {
            secretPersistence.persist(
                piAgentBearerToken,
                account: OpenBurnBarIdentity.piAgentBearerTokenAccount,
                legacyDefaultsKey: SettingsSecretDefaultsKey.piAgentBearerToken
            )
        }
    }

    var piAgentRedisURL: String = "" {
        didSet { persistence.set(piAgentRedisURL, forKey: "piAgentRedisURL") }
    }

    var piAgentSelectedInstanceID: String = "" {
        didSet { persistence.set(piAgentSelectedInstanceID, forKey: "piAgentSelectedInstanceID") }
    }

    var piAgentChatModelOverride: String = "" {
        didSet { persistence.set(piAgentChatModelOverride, forKey: "piAgentChatModelOverride") }
    }

    var launchPiAgentsWithOpenBurnBar: Bool = false {
        didSet { persistence.set(launchPiAgentsWithOpenBurnBar, forKey: "launchPiAgentsWithOpenBurnBar") }
    }

    // MARK: - Pi Remote Relay
    //
    // Pi gets its own relay toggle + URL so users can enable Pi-over-Relay
    // independently of Hermes. The default URL is the same hosted Cloud Run
    // relay used by Hermes — the relay service multiplexes by `runtime`
    // discriminator (Plan 2 §8.2).
    var piRemoteRelayEnabled: Bool = false {
        didSet { persistence.set(piRemoteRelayEnabled, forKey: "piRemoteRelayEnabled") }
    }

    var piRealtimeRelayURL: String = HermesRealtimeRelayProtocol.defaultHostedRelayURLString {
        didSet { persistence.set(piRealtimeRelayURL, forKey: "piRealtimeRelayURL") }
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

    // MARK: - Hermes Model Picker (second-level row beneath the surface strip)
    //
    // The chat surface picker (above) decides which app drives the
    // conversation (Codex / Claude / Hermes / OpenClaw / Pi). When the
    // selected surface is `.hermes`, this second list decides which
    // underlying model Hermes routes to. Stored as the same CSV pattern
    // so it sync-replicates cleanly through the existing persistence
    // coordinator.

    var enabledHermesModelIDsCSV: String = "" {
        didSet { persistence.set(enabledHermesModelIDsCSV, forKey: "enabledHermesModelIDsCSV") }
    }

    var selectedHermesModelIDRaw: String = "" {
        didSet { persistence.set(selectedHermesModelIDRaw, forKey: "selectedHermesModelIDRaw") }
    }

    var enabledHermesModels: [HermesModelID] {
        let list = HermesModelID.decodeEnabledList(fromCSV: enabledHermesModelIDsCSV)
        return list.isEmpty ? HermesModelID.defaultEnabled : list
    }

    var selectedHermesModel: HermesModelID? {
        get { HermesModelID(rawValue: selectedHermesModelIDRaw) }
        set { selectedHermesModelIDRaw = newValue?.rawValue ?? "" }
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
        self.hermesIrohTransportEnabled = persistence.bool(forKey: "hermesIrohTransportEnabled")
        self.launchHermesWithOpenBurnBar = persistence.bool(forKey: "launchHermesWithOpenBurnBar")
        self.piAgentGatewayBaseURL = persistence.string(forKey: "piAgentGatewayBaseURL", defaultValue: "http://127.0.0.1:8765")
        self.piAgentBearerToken = secretPersistence.load(
            account: OpenBurnBarIdentity.piAgentBearerTokenAccount,
            legacyDefaultsKey: SettingsSecretDefaultsKey.piAgentBearerToken
        )
        self.piAgentRedisURL = persistence.string(forKey: "piAgentRedisURL")
        self.piAgentSelectedInstanceID = persistence.string(forKey: "piAgentSelectedInstanceID")
        self.piAgentChatModelOverride = persistence.string(forKey: "piAgentChatModelOverride")
        self.launchPiAgentsWithOpenBurnBar = persistence.bool(forKey: "launchPiAgentsWithOpenBurnBar")
        self.piRemoteRelayEnabled = persistence.bool(forKey: "piRemoteRelayEnabled")
        self.piRealtimeRelayURL = persistence.string(
            forKey: "piRealtimeRelayURL",
            defaultValue: HermesRealtimeRelayProtocol.defaultHostedRelayURLString
        )
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
        self.enabledHermesModelIDsCSV = persistence.string(forKey: "enabledHermesModelIDsCSV")
        self.selectedHermesModelIDRaw = persistence.string(forKey: "selectedHermesModelIDRaw")
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

    func setEnabledHermesModels(_ models: [HermesModelID]) {
        enabledHermesModelIDsCSV = HermesModelID.encodeEnabledList(models)
    }

    func setHermesModelEnabled(_ id: HermesModelID, enabled: Bool) {
        var list = enabledHermesModels
        if enabled {
            if !list.contains(id) { list.append(id) }
        } else {
            list.removeAll { $0 == id }
        }
        setEnabledHermesModels(list)
    }

    /// Apply a Hermes model selection: stores the typed enum and mirrors
    /// it into `hermesChatModelOverride` so the existing chat resolution
    /// path picks it up without a parallel routing branch.
    func applyHermesModelSelection(_ model: HermesModelID?) {
        selectedHermesModel = model
        if let model {
            hermesChatModelOverride = model.hermesModelOverride
        } else {
            // Cleared selection — let the gateway-advertised default win
            // (`resolvedHermesChatModel` falls through to "hermes").
            hermesChatModelOverride = ""
        }
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

    static func resolvedPiChatModel(override: String, gatewayAdvertisedModel: String?) -> String {
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        guard let advertised = gatewayAdvertisedModel?.trimmingCharacters(in: .whitespacesAndNewlines), !advertised.isEmpty else {
            return "pi"
        }
        return advertised
    }

    func resolvedPiChatModel(gatewayAdvertisedModel: String?) -> String {
        Self.resolvedPiChatModel(override: piAgentChatModelOverride, gatewayAdvertisedModel: gatewayAdvertisedModel)
    }
}

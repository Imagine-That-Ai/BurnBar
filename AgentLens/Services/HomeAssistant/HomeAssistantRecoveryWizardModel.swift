import Foundation
import os.log

// MARK: - Home Assistant Recovery Wizard Model
//
// State machine for the Mac wizard. All HA I/O goes through the actor
// `HomeAssistantClient`. This view-model owns:
//
//   - the in-progress URL/token/entity selections
//   - retry/diagnose buttons
//   - the eventual call into the Provisioner that installs the
//     recovery automation
//   - persistence into HomeAssistantConfigStore + token store
//
// Step sequence (Phase A, REST):
//
//   .why → .findInstance → .connectToken → .pickDisplay
//        → .installRecovery → .liveTest → .done
//
// Optional .blueprint branch reachable from .installRecovery if the
// REST install hit a 404 / 405 (older HA without automation REST API)
// or the user explicitly chose blueprint mode.
//
// Failures bubble through `.failed` with a precise message. From any
// `.failed` step the user can retry, jump back, or open the Advanced
// debug pane.

@MainActor
@Observable
final class HomeAssistantRecoveryWizardModel {

    // MARK: - Steps

    enum Step: Equatable {
        case why
        case findInstance
        case probing(URL)
        case connectToken(URL, probeVersion: String?)
        case validatingToken(URL)
        case pickDisplay(URL, players: [HomeAssistantClient.MediaPlayer])
        case loadingDisplays(URL)
        case installRecovery(
            URL,
            entityID: String,
            friendlyName: String
        )
        case installing(URL, entityID: String, friendlyName: String)
        case liveTest(HomeAssistantConfig)
        case testing(HomeAssistantConfig)
        case done(HomeAssistantConfig)
        case blueprintIntro(URL)
        case failed(message: String, recoverable: Bool, previous: PreviousStep)

        /// Tracks where to "Back" from a failure screen.
        enum PreviousStep: String, Equatable {
            case findInstance
            case connectToken
            case pickDisplay
            case installRecovery
            case liveTest
            case blueprint
        }
    }

    // MARK: - State

    private(set) var step: Step = .why

    /// Free-form user input for the URL field. We mirror this rather
    /// than recompute on every keystroke so the field can be edited
    /// in-place even while the model is mid-probe.
    var inputURLString: String = "homeassistant.local:8123"

    /// Free-form user input for the long-lived access token.
    var inputAccessToken: String = ""

    /// Cached probe / metadata.
    private(set) var detectedVersion: String?

    /// Existing config snapshot, if the user is reconfiguring an
    /// instance that is already provisioned.
    private(set) var existingConfig: HomeAssistantConfig?

    /// Result of last installation.
    private(set) var installedConfig: HomeAssistantConfig?

    // MARK: - Dependencies

    private let client: HomeAssistantClient
    private let provisioner: HomeAssistantRecoveryProvisioner
    private let tokenStore: HomeAssistantTokenStoring
    private let configStore: HomeAssistantConfigStoring
    private let suggestedFriendlyName: () -> String
    private let dashboardURLProvider: () -> URL?
    private let log = Logger(subsystem: "com.openburnbar.app", category: "HARecoveryWizard")

    // MARK: - Init

    init(
        client: HomeAssistantClient = HomeAssistantClient(),
        provisioner: HomeAssistantRecoveryProvisioner? = nil,
        tokenStore: HomeAssistantTokenStoring = HomeAssistantTokenStore(),
        configStore: HomeAssistantConfigStoring,
        suggestedFriendlyName: @escaping () -> String = { "" },
        dashboardURLProvider: @escaping () -> URL?
    ) {
        self.client = client
        self.provisioner = provisioner ?? HomeAssistantRecoveryProvisioner(client: client)
        self.tokenStore = tokenStore
        self.configStore = configStore
        self.suggestedFriendlyName = suggestedFriendlyName
        self.dashboardURLProvider = dashboardURLProvider
        self.existingConfig = configStore.loadConfig()
    }

    // MARK: - User intents

    func start() {
        if let existing = existingConfig {
            inputURLString = existing.baseURL.absoluteString
        }
        step = .why
    }

    func goFindInstance() { step = .findInstance }

    /// Probe the URL the user entered. This is purely to give them
    /// feedback before they paste a token — we don't need the token
    /// to confirm HA is reachable on the LAN.
    func probeEnteredURL() {
        guard let url = HomeAssistantURLNormalizer.normalize(inputURLString) else {
            step = .failed(
                message: "That doesn't look like a valid Home Assistant URL. Try something like homeassistant.local:8123 or https://your-instance.duckdns.org.",
                recoverable: true,
                previous: .findInstance
            )
            return
        }
        inputURLString = url.absoluteString
        step = .probing(url)
        Task { [weak self] in
            guard let self else { return }
            let result = await self.client.probe(baseURL: url)
            await MainActor.run {
                switch result {
                case .ok(let version):
                    self.detectedVersion = version
                    self.step = .connectToken(url, probeVersion: version)
                case .unauthorized:
                    self.detectedVersion = nil
                    self.step = .connectToken(url, probeVersion: nil)
                case .noHomeAssistantHere:
                    self.step = .failed(
                        message: "We reached \(url.host ?? url.absoluteString), but it doesn't look like Home Assistant. Double-check the URL — it usually ends in :8123 for local installs.",
                        recoverable: true,
                        previous: .findInstance
                    )
                case .unreachable(let why):
                    self.step = .failed(
                        message: "Couldn't reach \(url.host ?? url.absoluteString): \(why). Is your Mac on the same network as Home Assistant?",
                        recoverable: true,
                        previous: .findInstance
                    )
                }
            }
        }
    }

    func validateToken() {
        guard case let .connectToken(url, _) = step else { return }
        let token = inputAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            step = .failed(
                message: "Paste your long-lived access token to connect.",
                recoverable: true,
                previous: .connectToken
            )
            return
        }
        step = .validatingToken(url)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.validateToken(baseURL: url, accessToken: token)
                try self.tokenStore.saveAccessToken(token)
                await self.loadDisplays(baseURL: url)
            } catch let error as HomeAssistantClient.ClientError {
                await MainActor.run {
                    self.step = .failed(
                        message: error.errorDescription ?? "Could not validate the token.",
                        recoverable: true,
                        previous: .connectToken
                    )
                }
            } catch {
                await MainActor.run {
                    self.step = .failed(
                        message: error.localizedDescription,
                        recoverable: true,
                        previous: .connectToken
                    )
                }
            }
        }
    }

    private func loadDisplays(baseURL: URL) async {
        await MainActor.run { self.step = .loadingDisplays(baseURL) }
        let token: String
        do {
            guard let stored = try tokenStore.loadAccessToken() else {
                await MainActor.run {
                    self.step = .failed(
                        message: "Token disappeared from the keychain — try connecting again.",
                        recoverable: true,
                        previous: .connectToken
                    )
                }
                return
            }
            token = stored
        } catch {
            await MainActor.run {
                self.step = .failed(
                    message: "Could not read the saved token: \(error.localizedDescription)",
                    recoverable: true,
                    previous: .connectToken
                )
            }
            return
        }

        do {
            let players = try await self.client.listMediaPlayers(baseURL: baseURL, accessToken: token)
            await MainActor.run {
                if players.isEmpty {
                    self.step = .failed(
                        message: "Home Assistant didn't expose any media_player entities to OpenBurnBar. Add your Cast device to HA first (Settings → Devices → Add Integration → Google Cast), then come back.",
                        recoverable: true,
                        previous: .connectToken
                    )
                } else {
                    self.step = .pickDisplay(baseURL, players: players)
                }
            }
        } catch let error as HomeAssistantClient.ClientError {
            await MainActor.run {
                self.step = .failed(
                    message: error.errorDescription ?? "Could not load Home Assistant entities.",
                    recoverable: true,
                    previous: .connectToken
                )
            }
        } catch {
            await MainActor.run {
                self.step = .failed(
                    message: error.localizedDescription,
                    recoverable: true,
                    previous: .connectToken
                )
            }
        }
    }

    func pickDisplay(_ player: HomeAssistantClient.MediaPlayer) {
        guard case let .pickDisplay(url, _) = step else { return }
        step = .installRecovery(url, entityID: player.entityID, friendlyName: player.friendlyName)
    }

    func installRecovery() {
        guard case let .installRecovery(url, entityID, friendlyName) = step else { return }
        step = .installing(url, entityID: entityID, friendlyName: friendlyName)
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let token = try self.tokenStore.loadAccessToken() else {
                    await MainActor.run {
                        self.step = .failed(
                            message: "Lost the access token. Reconnect to Home Assistant.",
                            recoverable: true,
                            previous: .connectToken
                        )
                    }
                    return
                }
                guard let dashboardURL = self.dashboardURLProvider() else {
                    await MainActor.run {
                        self.step = .failed(
                            message: "OpenBurnBar can't find its own bridge URL. Open Settings → Smart Display → Advanced and check the Dashboard URL.",
                            recoverable: false,
                            previous: .installRecovery
                        )
                    }
                    return
                }
                let config = try await self.provisioner.install(
                    baseURL: url,
                    accessToken: token,
                    mediaPlayerEntityID: entityID,
                    mediaPlayerFriendlyName: friendlyName,
                    fallbackDashboardURL: dashboardURL,
                    existingWebhookID: self.existingConfig?.webhookID
                )
                await MainActor.run {
                    self.installedConfig = config
                    self.configStore.saveConfig(config)
                    self.step = .liveTest(config)
                }
            } catch let error as HomeAssistantClient.ClientError {
                await MainActor.run {
                    let isRESTUnavailable: Bool
                    switch error {
                    case .notFound, .forbidden:
                        isRESTUnavailable = true
                    case .server(let code, _):
                        isRESTUnavailable = code == 405 || code == 409 || code == 501
                    default:
                        isRESTUnavailable = false
                    }
                    if isRESTUnavailable {
                        self.step = .blueprintIntro(url)
                    } else {
                        self.step = .failed(
                            message: error.errorDescription ?? "Could not install the recovery automation.",
                            recoverable: true,
                            previous: .installRecovery
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    self.step = .failed(
                        message: error.localizedDescription,
                        recoverable: true,
                        previous: .installRecovery
                    )
                }
            }
        }
    }

    func runLiveTest() {
        guard case let .liveTest(config) = step else { return }
        guard let dashboardURL = dashboardURLProvider() else {
            step = .failed(
                message: "OpenBurnBar can't find its own bridge URL. Reopen Settings → Smart Display → Advanced and check the Dashboard URL.",
                recoverable: false,
                previous: .liveTest
            )
            return
        }
        step = .testing(config)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.provisioner.runLiveTest(config: config, dashboardURL: dashboardURL)
                var updated = config
                updated.lastTestPassed = true
                updated.lastVerifiedAt = Date()
                self.configStore.saveConfig(updated)
                await MainActor.run {
                    self.installedConfig = updated
                    self.step = .done(updated)
                }
            } catch let error as HomeAssistantClient.ClientError {
                await MainActor.run {
                    self.step = .failed(
                        message: error.errorDescription ?? "Recovery webhook test failed.",
                        recoverable: true,
                        previous: .liveTest
                    )
                }
            } catch {
                await MainActor.run {
                    self.step = .failed(
                        message: error.localizedDescription,
                        recoverable: true,
                        previous: .liveTest
                    )
                }
            }
        }
    }

    /// Move user from the `.installRecovery` confirmation screen to the
    /// blueprint fallback intentionally (e.g. they want a non-REST path).
    func chooseBlueprintFallback() {
        let url: URL?
        switch step {
        case .installRecovery(let u, _, _):
            url = u
        case .liveTest(let c):
            url = c.baseURL
        case .blueprintIntro(let u):
            url = u
        default:
            url = HomeAssistantURLNormalizer.normalize(inputURLString)
        }
        guard let resolved = url else {
            step = .failed(
                message: "Set up your Home Assistant URL first.",
                recoverable: true,
                previous: .findInstance
            )
            return
        }
        step = .blueprintIntro(resolved)
    }

    /// Persist a manual blueprint-mode config: webhook ID is generated
    /// here and surfaced to the user so they can paste it into HA's
    /// blueprint dialog.
    func saveBlueprintWebhook(generatedID: String? = nil) -> HomeAssistantConfig? {
        guard case let .blueprintIntro(url) = step else { return nil }
        let id = generatedID ?? HomeAssistantWebhookID.generate()
        let config = HomeAssistantConfig(
            baseURL: url,
            mediaPlayerEntityID: "",
            mediaPlayerFriendlyName: suggestedFriendlyName(),
            webhookID: id,
            automationEntityID: "",
            automationInstalled: false,
            lastTestPassed: false,
            lastVerifiedAt: nil,
            setupMode: .blueprint
        )
        configStore.saveConfig(config)
        installedConfig = config
        step = .liveTest(config)
        return config
    }

    func reset() {
        step = .why
        inputAccessToken = ""
    }

    func retryFromFailure() {
        guard case let .failed(_, _, previous) = step else { return }
        switch previous {
        case .findInstance:
            step = .findInstance
        case .connectToken:
            if let url = HomeAssistantURLNormalizer.normalize(inputURLString) {
                step = .connectToken(url, probeVersion: detectedVersion)
            } else {
                step = .findInstance
            }
        case .pickDisplay:
            if let url = HomeAssistantURLNormalizer.normalize(inputURLString) {
                Task { [weak self] in await self?.loadDisplays(baseURL: url) }
            } else {
                step = .findInstance
            }
        case .installRecovery:
            if case let .installRecovery(_, entityID, friendlyName) = step,
               let url = HomeAssistantURLNormalizer.normalize(inputURLString) {
                step = .installRecovery(url, entityID: entityID, friendlyName: friendlyName)
            } else {
                step = .findInstance
            }
        case .liveTest:
            if let config = installedConfig {
                step = .liveTest(config)
            } else {
                step = .findInstance
            }
        case .blueprint:
            if let url = HomeAssistantURLNormalizer.normalize(inputURLString) {
                step = .blueprintIntro(url)
            } else {
                step = .findInstance
            }
        }
    }

    func disconnect() {
        do {
            try tokenStore.deleteAccessToken()
            try tokenStore.deleteWebhookSecret()
            configStore.clear()
            installedConfig = nil
            existingConfig = nil
        } catch {
            log.error("Failed to disconnect HA: \(error.localizedDescription, privacy: .public)")
        }
        reset()
    }
}

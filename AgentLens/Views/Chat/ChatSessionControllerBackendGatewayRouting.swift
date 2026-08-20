import Foundation
import SwiftUI
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
#if canImport(AppKit)
import AppKit
#endif

@MainActor
extension ChatSessionController {
    /// The model currently loaded in Hermes (e.g. "NousResearch/Hermes-3-Llama-3.1-8B").
    var hermesModelName: String? { cliBridge.hermesModelName }

    var hermesAdvertisedModels: [HermesAdvertisedModel] { cliBridge.hermesAdvertisedModels }

    var hermesGatewayModels: [OpenAICompatibleAdvertisedModel] { cliBridge.hermesGatewayModels }

    var openClawGatewayModels: [OpenAICompatibleAdvertisedModel] { cliBridge.openClawGatewayModels }

    var piAgentGatewayModels: [OpenAICompatibleAdvertisedModel] { cliBridge.piAgentGatewayModels }

    var isElderWandActive: Bool {
        settingsManager.elderWandPluginsPayload() != nil
    }

    func chatModelSelection(for backend: ChatBackendID) -> String {
        switch backend {
        case .codex: return chatModelCodex
        case .claude: return chatModelClaude
        case .hermes: return chatModelHermes
        case .openclaw: return chatModelOpenClaw
        case .piAgent: return chatModelPiAgent
        case .droid: return chatModelDroid
        case .forge: return chatModelForge
        case .antigravity: return chatModelAntigravity
        case .cursorAgent: return chatModelCursorAgent
        case .openClaude: return chatModelOpenClaude
        case .omp: return chatModelOMP
        case .junie: return chatModelJunie
        case .fx: return chatModelFx
        case .grok, .kimi: return chatModelJunie
        }
    }

    func setChatModelSelection(_ value: String, for backend: ChatBackendID) {
        switch backend {
        case .codex: chatModelCodex = value
        case .claude: chatModelClaude = value
        case .hermes: chatModelHermes = value
        case .openclaw: chatModelOpenClaw = value
        case .piAgent: chatModelPiAgent = value
        case .droid: chatModelDroid = value
        case .forge: chatModelForge = value
        case .antigravity: chatModelAntigravity = value
        case .cursorAgent: chatModelCursorAgent = value
        case .openClaude: chatModelOpenClaude = value
        case .omp: chatModelOMP = value
        case .junie: chatModelJunie = value
        case .fx: chatModelFx = value
        case .grok, .kimi: chatModelJunie = value
        }
    }

    /// Copy non-global dependencies that pane controllers need to behave like
    /// the app-wide chat controller. This intentionally avoids thread, message,
    /// and stream state.
    func copyPaneRuntimeBindings(from source: ChatSessionController) {
        memoryService = source.memoryService
        memoryExtractionEngine = source.memoryExtractionEngine
        sharedFeaturesAvailable = source.sharedFeaturesAvailable
        #if canImport(AppKit) && !DISTRIBUTION_MAS
        computerUseRuntimeController = source.computerUseRuntimeController
        #endif
    }

    /// Copy the active conversation controls without resolving a new thread slot.
    /// Used when creating or re-homing tiled panes, where backend/model state is
    /// pane-local and must not fall back to the primary controller defaults.
    func copyPaneConversationControls(from source: ChatSessionController) {
        chatBackend = source.chatBackend
        for backend in ChatBackendID.allCases {
            setChatModelSelection(source.chatModelSelection(for: backend), for: backend)
        }
        // A new pane inherits the voice it was split from; re-picking a persona
        // per pane would make splitting a window feel like starting over.
        customPersonaSeats = source.customPersonaSeats
        personaSeatsByBackend = source.personaSeatsByBackend
        chatViewMode = source.chatViewMode
        hermesAvailable = source.hermesAvailable
        openClawAvailable = source.openClawAvailable
        piAgentAvailable = source.piAgentAvailable
    }

    func assistantRuntimeID(for backend: ChatBackendID) -> AssistantRuntimeID {
        switch backend {
        case .codex: return .codex
        case .claude: return .claude
        case .hermes: return .hermes
        case .openclaw: return .openClaw
        case .piAgent: return .pi
        case .droid: return .droid
        case .forge: return .forge
        case .antigravity: return .antigravity
        case .cursorAgent: return .cursorAgent
        case .openClaude: return .openClaude
        case .omp: return .omp
        case .junie: return .junie
        case .fx: return .fx
        case .grok: return .grok
        case .kimi: return .grok
        }
    }

    /// Resolved `model` argument for the next chat request for this backend.
    func effectiveChatModel(for backend: ChatBackendID) -> String {
        switch backend {
        case .codex:
            let s = chatModelCodex.trimmingCharacters(in: .whitespacesAndNewlines)
            return CLIBridge.normalizedCodexModel(s)
        case .claude:
            return chatModelClaude.trimmingCharacters(in: .whitespacesAndNewlines)
        case .hermes:
            if isElderWandActive {
                return Self.resolvedElderWandOriginatingModel(
                    selection: chatModelHermes,
                    liveModels: burnBarGatewayModels
                )
            }
            return Self.resolvedHermesModelSelection(
                panelSelection: chatModelHermes,
                settingsOverride: settingsManager.hermesChatModelOverride,
                selectedFamily: settingsManager.selectedHermesModel,
                advertisedModels: hermesAdvertisedModels,
                gatewayDefault: liveDefaultModel(for: .hermes)
            )
        case .openclaw:
            if isElderWandActive {
                return Self.resolvedElderWandOriginatingModel(
                    selection: chatModelOpenClaw,
                    liveModels: burnBarGatewayModels
                )
            }
            let s = chatModelOpenClaw.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { return liveDefaultModel(for: .openclaw) ?? "" }
            return s
        case .piAgent:
            if isElderWandActive {
                return Self.resolvedElderWandOriginatingModel(
                    selection: chatModelPiAgent,
                    liveModels: burnBarGatewayModels
                )
            }
            let s = chatModelPiAgent.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { return liveDefaultModel(for: .piAgent) ?? "" }
            return s
        case .droid:
            return chatModelDroid.trimmingCharacters(in: .whitespacesAndNewlines)
        case .forge:
            return chatModelForge.trimmingCharacters(in: .whitespacesAndNewlines)
        case .antigravity:
            return chatModelAntigravity.trimmingCharacters(in: .whitespacesAndNewlines)
        case .cursorAgent:
            return chatModelCursorAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        case .openClaude:
            return chatModelOpenClaude.trimmingCharacters(in: .whitespacesAndNewlines)
        case .omp:
            return chatModelOMP.trimmingCharacters(in: .whitespacesAndNewlines)
        case .junie, .grok, .kimi:
            return chatModelJunie.trimmingCharacters(in: .whitespacesAndNewlines)
        case .fx:
            // fx has no `--model` flag; the selection is only a picker
            // placeholder. Return it trimmed so the mirror/analytics rows
            // stay consistent with the other CLI backends.
            return chatModelFx.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Resolve the model family used to pick the prompt token arbiter's context
    /// window + ceiling (G9). Ollama and genuinely unknown local backends get the
    /// conservative floor; all other backends route to cloud models and receive the
    /// large-context ceiling. Static + param-driven so it is unit-testable.
    nonisolated static func memoryArbiterModelFamily(
        backend: ChatBackendID,
        resolvedModel: String,
        hermesFamily: HermesModelID?
    ) -> HermesModelID {
        if let family = hermesFamilyHint(for: resolvedModel) {
            return family
        }
        if backend == .hermes, let family = hermesFamily {
            return family
        }
        // All other shipped backends (and Hermes without an explicit family) route to
        // cloud models; use a generic cloud family so they receive the large-context
        // ceiling rather than the ollama floor.
        return .codex
    }

    nonisolated static func promptPayloadTokenReserve(
        history: [ChatMessageRecord],
        userMessage: String
    ) -> Int {
        if history.isEmpty {
            return PromptTokenArbiter.estimateProseTokens(userMessage)
        }
        let contentChars = history.reduce(0) { partial, message in
            partial + message.content.count
        }
        let attachmentTokens = history.reduce(0) { partial, message in
            partial + message.attachments.reduce(0) { $0 + $1.estimatedTokenCost }
        }
        return OpenBurnBarCore.TokenExtractionUtility.estimatedTokenCount(for: contentChars, charsPerToken: 3.5) + attachmentTokens
    }

    nonisolated static func promptSystemWrapperTokenReserve(
        backend: ChatBackendID,
        piAgentInstanceID: String
    ) -> Int {
        switch backend {
        case .hermes:
            return PromptTokenArbiter.estimateProseTokens(HermesSystemPromptBuilder.atomDirective)
        case .piAgent:
            return PromptTokenArbiter.estimateProseTokens(piSystemPromptWrapper(instanceID: piAgentInstanceID))
        case .openclaw, .codex, .claude, .droid, .forge, .antigravity, .cursorAgent, .openClaude, .omp, .junie, .fx, .grok, .kimi:
            return 0
        }
    }

    func liveAdvertisedModels(for backend: ChatBackendID) -> [OpenAICompatibleAdvertisedModel] {
        switch backend {
        case .hermes:
            return hermesGatewayModels
        case .openclaw:
            return openClawGatewayModels
        case .piAgent:
            return piAgentGatewayModels
        case .codex, .claude, .droid, .forge, .antigravity, .cursorAgent, .openClaude, .omp, .junie, .fx:
            return []
        }
    }

    func backendCapabilities(
        for backend: ChatBackendID,
        modelID: String
    ) -> HermesBackendCapabilities {
        chatModelCatalog(for: backend)
            .first { $0.id.caseInsensitiveCompare(modelID) == .orderedSame }?
            .modelCapabilities?
            .asHermesBackendCapabilities
            ?? HermesBackendCapabilities.default
    }

    func liveDefaultModel(for backend: ChatBackendID) -> String? {
        liveAdvertisedModels(for: backend)
            .first { $0.routeEligible }?
            .id
    }

    /// Catalog shown by the chat model picker. Fusion executes on the BurnBar
    /// daemon, not the selected upstream chat gateway, so an active Elder Wand
    /// preset switches every compatible OpenAI chat surface to the daemon's
    /// exact advertised catalog.
    func chatModelCatalog(for backend: ChatBackendID) -> [OpenAICompatibleAdvertisedModel] {
        if isElderWandActive, Self.supportsElderWandGateway(backend) {
            return burnBarGatewayModels
        }
        return liveAdvertisedModels(for: backend)
    }

    nonisolated static func allowsTextExpansionRewriteGateway(_ baseURL: URL) -> Bool {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              components.user == nil,
              components.password == nil else {
            return false
        }
        return LocalLLMEndpointPolicy.isLoopbackHost(host)
    }

    nonisolated static func allowsElderWandHostedSearchAuthGateway(_ baseURL: URL) -> Bool {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              components.user == nil,
              components.password == nil,
              components.path.isEmpty || components.path == "/",
              components.query == nil,
              components.fragment == nil else {
            return false
        }
        return LocalLLMEndpointPolicy.isLoopbackHost(host)
    }

    static func resolvedHermesModelSelection(
        panelSelection: String,
        settingsOverride: String,
        selectedFamily: HermesModelID?,
        advertisedModels: [HermesAdvertisedModel],
        gatewayDefault: String?
    ) -> String {
        let panel = panelSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        if !panel.isEmpty {
            if advertisedModels.contains(where: { $0.id == panel }) {
                return panel
            }
            if let family = hermesFamilyHint(for: panel),
               let advertised = advertisedModels.first(where: { $0.family == family }) {
                return advertised.id
            }
            if advertisedModels.isEmpty {
                return panel
            }
        }

        let override = settingsOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if advertisedModels.contains(where: { $0.id == override }) {
            return override
        }
        if let family = hermesFamilyHint(for: override) {
            if let advertised = advertisedModels.first(where: { $0.family == family }) {
                return advertised.id
            }
        } else if !override.isEmpty, advertisedModels.isEmpty {
            return override
        }

        if let selectedFamily,
           let advertised = advertisedModels.first(where: { $0.family == selectedFamily }) {
            return advertised.id
        }

        let liveDefault = gatewayDefault?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !liveDefault.isEmpty { return liveDefault }
        // Catalog unreadable (cold start, or /v1/models behind an unset API key
        // while /health stays open) so there is no gateway default. Preserve any
        // explicit family intent first: the gateway routes canonical family
        // names ("claude", "codex", …) directly, so a user who picked a family
        // keeps their provider instead of being silently rerouted to the
        // gateway's default agent.
        if let family = hermesFamilyHint(for: override) { return family.rawValue }
        if let selectedFamily { return selectedFamily.rawValue }
        // Nothing selected anywhere: fall back to the gateway's canonical self
        // alias instead of "". The gateway routes "hermes" to its default agent
        // and remains the routing authority, so the send surfaces the gateway's
        // real error (e.g. "Invalid API key") instead of dead-ending locally on
        // the "No eligible route" gate. `chatHermes` always allowlists this alias.
        return hermesCanonicalModelAlias
    }

    /// Resolve the top-level model that writes an Elder Wand response. An
    /// explicit user selection is preserved so a stale choice fails visibly;
    /// Automatic selects the first route-eligible model from the same daemon
    /// catalog that will execute the request.
    nonisolated static func resolvedElderWandOriginatingModel(
        selection: String,
        liveModels: [OpenAICompatibleAdvertisedModel]
    ) -> String {
        let selected = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty { return selected }
        return liveModels.first { $0.routeEligible }?.id ?? ""
    }

    /// The Hermes gateway's self alias: routed server-side to the gateway's
    /// default agent, and permanently present in `CLIBridge.chatHermes`'s model
    /// allowlist even when the `/v1/models` catalog is unreadable.
    nonisolated static let hermesCanonicalModelAlias = "hermes"

    nonisolated static func hermesFamilyHint(for model: String) -> HermesModelID? {
        let normalized = model
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        guard !normalized.isEmpty else { return nil }
        if let family = HermesModelID(rawValue: normalized) { return family }
        if normalized.contains("claude") || normalized.contains("anthropic") { return .claude }
        if normalized.contains("codex") || normalized.contains("openai") || normalized.hasPrefix("gpt-") { return .codex }
        if normalized.contains("zai") || normalized.contains("z.ai") || normalized.contains("glm") { return .zai }
        if normalized.contains("kimi") || normalized.contains("moonshot") { return .kimi }
        if normalized.contains("minimax") { return .minimax }
        if normalized.contains("ollama")
            || normalized.contains("llama")
            || normalized.contains("mistral")
            || normalized.contains("qwen")
            || normalized.contains("deepseek")
            || normalized.contains("gemma") {
            return .ollama
        }
        return nil
    }

    func selectedModelRoutingError(for backend: ChatBackendID) -> String? {
        if isElderWandActive {
            return Self.elderWandRoutingError(
                backend: backend,
                selectedModel: effectiveChatModel(for: backend),
                gatewayAvailable: burnBarGatewayAvailable,
                authRejected: burnBarGatewayCatalogAuthRejected,
                liveModels: burnBarGatewayModels
            )
        }
        return Self.selectedModelRoutingError(
            backend: backend,
            selectedModel: effectiveChatModel(for: backend).trimmingCharacters(in: .whitespacesAndNewlines),
            liveModels: liveAdvertisedModels(for: backend)
        )
    }

    nonisolated static func elderWandRoutingError(
        backend: ChatBackendID,
        selectedModel: String,
        gatewayAvailable: Bool,
        authRejected: Bool,
        liveModels: [OpenAICompatibleAdvertisedModel]
    ) -> String? {
        guard supportsElderWandGateway(backend) else {
            return "The Elder Wand requires an OpenAI-compatible chat engine. Switch to Hermes, OpenClaw, or Pi Agent and try again."
        }
        if authRejected {
            return "The BurnBar gateway rejected its bearer token. Open Settings -> Model Gateway, repair the gateway token, and try again."
        }
        guard gatewayAvailable else {
            return "The BurnBar gateway is unavailable. Start or restart OpenBurnBar, then try The Elder Wand again."
        }
        guard !liveModels.isEmpty else {
            return "The BurnBar gateway has no live routed models. Add or enable a provider before using The Elder Wand."
        }
        let model = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            return "Choose a live final-answer model from the chat model menu before using The Elder Wand."
        }
        guard liveModels.contains(where: {
            $0.id.caseInsensitiveCompare(model) == .orderedSame && $0.routeEligible
        }) else {
            return "The Elder Wand final-answer model '\(model)' is not routed by the BurnBar gateway. Choose a live model from the chat model menu."
        }
        return nil
    }

    nonisolated static func supportsElderWandGateway(_ backend: ChatBackendID) -> Bool {
        backend == .hermes || backend == .openclaw || backend == .piAgent
    }

    /// Pure routing-eligibility gate (extracted so the empty-catalog policy is
    /// unit-testable). Only reached after `validateChatBackendAvailability()`
    /// already confirmed the gateway is up, so an empty `liveModels` here means
    /// "gateway reachable, catalog not read yet", not "gateway down".
    ///
    /// For **Hermes** an unread catalog must NOT block the send: the gateway
    /// routes the canonical family names ("claude", "codex", "ollama", …)
    /// directly and is itself the routing authority — it returns a real error if
    /// the model is genuinely unroutable. The gateway's own
    /// `hermesCanonicalModelAlias` is likewise always eligible — it is never
    /// advertised in `/v1/models`, yet the gateway routes it to its default
    /// agent (verified against hermes-agent 0.17.0). OpenClaw/Pi are generic
    /// OpenAI-compatible gateways whose model id must match the advertised
    /// catalog, so they keep verifying against it.
    nonisolated static func selectedModelRoutingError(
        backend: ChatBackendID,
        selectedModel: String,
        liveModels: [OpenAICompatibleAdvertisedModel]
    ) -> String? {
        guard backend == .hermes || backend == .openclaw || backend == .piAgent else { return nil }
        if backend == .hermes, selectedModel == hermesCanonicalModelAlias { return nil }
        guard !selectedModel.isEmpty else {
            return "No eligible route for \(backend.displayName). Add or enable an account/provider that serves this model."
        }
        guard !liveModels.isEmpty else {
            if backend == .hermes { return nil }
            return "Selected \(backend.displayName) model '\(selectedModel)' has not been verified against this gateway's live /v1/models catalog. Refresh the gateway before sending, so the request is not silently rerouted."
        }
        guard liveModels.contains(where: { $0.id == selectedModel && $0.routeEligible }) else {
            return "No eligible route for \(selectedModel). Add or enable an account/provider that serves this model."
        }
        return nil
    }

    static func abbreviateChatModelName(_ name: String) -> String {
        var short = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !short.isEmpty else { return "Model" }
        let prefixes = ["NousResearch/", "meta-llama/", "mistralai/", "Qwen/", "google/", "deepseek-ai/"]
        for prefix in prefixes where short.hasPrefix(prefix) {
            short = String(short.dropFirst(prefix.count))
            break
        }
        if short.count > 32 {
            short = String(short.prefix(30)) + "…"
        }
        return short
    }

    func probeHermesAvailability() async {
        await refreshHermesEnvFallbackBearerToken()
        await cliBridge.probeHermesAvailability(
            baseURL: hermesGatewayBaseURL,
            bearerToken: hermesBearerToken
        )
        hermesAvailable = cliBridge.hermesAvailable
        hermesCatalogAuthRejected = cliBridge.hermesCatalogAuthRejected
        scheduleHermesCatalogWarmIfNeeded()
    }

    /// True while `hermesEnvFallbackBearerToken` holds a key read from
    /// `~/.hermes/.env` (exposed so extensions in other files can tailor the
    /// auth-rejection guidance without widening access to the key itself).
    var hermesEnvFallbackKeyPresent: Bool {
        hermesEnvFallbackBearerToken?.isEmpty == false
    }

    /// Actionable transcript reply for the "gateway up, key rejected" state,
    /// tailored to which key was actually presented. Pure for unit tests.
    nonisolated static func hermesAuthRejectedMessage(
        settingsTokenPresent: Bool,
        envKeyPresent: Bool
    ) -> String {
        if settingsTokenPresent {
            return "The Hermes gateway is running but rejected the Bearer Token from Settings → Chat Gateway → Hermes Gateway. "
                + "For a local gateway it must match API_SERVER_KEY in ~/.hermes/.env — update it there "
                + "(or clear the field to let OpenBurnBar reuse the local key automatically) and send again."
        }
        if envKeyPresent {
            return "The Hermes gateway rejected the local API_SERVER_KEY from ~/.hermes/.env — it is likely running with an older key. "
                + "Use Settings → Chat Gateway → Hermes Gateway → Open Hermes + Gateway to restart it with the current key, then send again."
        }
        return "The Hermes gateway requires an API key. Paste API_SERVER_KEY (from ~/.hermes/.env on the gateway machine) "
            + "into Settings → Chat Gateway → Hermes Gateway → Bearer Token, then send again."
    }

    /// Refreshes the cached `~/.hermes/.env` `API_SERVER_KEY` fallback. Skips
    /// the file read entirely when Settings already carries an explicit token
    /// (it always wins) or when the configured gateway is not loopback (the
    /// local key must never leave the machine). Not `private`: the send path
    /// (`validateChatBackendAvailability`, in the Search extension) re-runs it
    /// per send so clearing the Settings token mid-session picks the env key
    /// back up without waiting for the next availability probe.
    func refreshHermesEnvFallbackBearerToken() async {
        let settingsToken = settingsManager.hermesBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settingsToken.isEmpty, Self.allowsHermesEnvKeyReuse(hermesGatewayBaseURL) else {
            hermesEnvFallbackBearerToken = nil
            return
        }
        hermesEnvFallbackBearerToken = await HermesEnvironmentFile.readAPIServerKey()
    }

    /// When the gateway is reachable but its `/v1/models` catalog has not loaded
    /// yet (cold start), re-probe a few times with backoff so the model picker
    /// self-heals without the user having to retry. Chat already functions in the
    /// meantime — the gateway routes the selected family directly — so this only
    /// backfills the picker/header. Idempotent: a warm already in flight is left
    /// to finish.
    private func scheduleHermesCatalogWarmIfNeeded() {
        guard hermesAvailable, cliBridge.hermesGatewayModels.isEmpty else { return }
        guard hermesCatalogWarmTask == nil else { return }
        hermesCatalogWarmTask = Task { [weak self] in
            for delay in [Duration.seconds(2), .seconds(4), .seconds(8)] {
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled else { break }
                await self.cliBridge.probeHermesAvailability(
                    baseURL: self.hermesGatewayBaseURL,
                    bearerToken: self.hermesBearerToken
                )
                self.hermesAvailable = self.cliBridge.hermesAvailable
                self.hermesCatalogAuthRejected = self.cliBridge.hermesCatalogAuthRejected
                if !self.cliBridge.hermesGatewayModels.isEmpty { break }
            }
            self?.hermesCatalogWarmTask = nil
        }
    }

    func probeOpenClawAvailability() async {
        guard let url = URL(string: settingsManager.openClawGatewayBaseURL) else {
            openClawAvailable = false
            return
        }
        await cliBridge.probeOpenClawAvailability(
            baseURL: url,
            bearerToken: openClawBearerToken
        )
        openClawAvailable = cliBridge.openClawAvailable
    }

    func probePiAgentAvailability() async {
        await cliBridge.probePiAgentAvailability(
            baseURL: piAgentGatewayBaseURL,
            bearerToken: piAgentBearerToken
        )
        piAgentAvailable = cliBridge.piAgentAvailable
    }

    func probeBurnBarGatewayAvailability() async {
        let result = await OpenAICompatibleModelProbe.probeWithModels(
            baseURL: burnBarGatewayBaseURL,
            bearerToken: burnBarGatewayBearerToken
        )
        burnBarGatewayAvailable = result.available
        burnBarGatewayCatalogAuthRejected = result.authRejected
        burnBarGatewayModels = result.models
    }

    /// Pi agent model name currently advertised by the configured Pi gateway.
    var piAgentModelName: String? { cliBridge.piAgentModelName }

    var piAgentBearerToken: String? {
        let t = settingsManager.piAgentBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    var piAgentGatewayBaseURL: URL {
        URL(string: settingsManager.piAgentGatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? URL(string: "http://127.0.0.1:8765")!
    }

    var hermesBearerToken: String? {
        Self.resolvedHermesBearerToken(
            settingsToken: settingsManager.hermesBearerToken,
            envFallbackKey: hermesEnvFallbackBearerToken,
            baseURL: hermesGatewayBaseURL
        )
    }

    /// Pure bearer-token resolution for the Hermes chat path (unit-testable).
    /// An explicit Settings token always wins. Otherwise the cached
    /// `API_SERVER_KEY` from `~/.hermes/.env` is reused — but only toward a
    /// loopback gateway, so the local gateway's key is never attached to a
    /// request leaving this machine.
    nonisolated static func resolvedHermesBearerToken(
        settingsToken: String,
        envFallbackKey: String?,
        baseURL: URL
    ) -> String? {
        let explicit = settingsToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty { return explicit }
        guard let envFallbackKey,
              !envFallbackKey.isEmpty,
              allowsHermesEnvKeyReuse(baseURL) else {
            return nil
        }
        return envFallbackKey
    }

    /// The `~/.hermes/.env` `API_SERVER_KEY` authenticates the *local* Hermes
    /// gateway; reuse is restricted to loopback hosts.
    nonisolated static func allowsHermesEnvKeyReuse(_ baseURL: URL) -> Bool {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let host = components.host,
              components.user == nil,
              components.password == nil else {
            return false
        }
        return LocalLLMEndpointPolicy.isLoopbackHost(host)
    }

    var hermesGatewayBaseURL: URL {
        URL(string: settingsManager.hermesGatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? URL(string: "http://127.0.0.1:8642")!
    }

    /// Base URL of the BurnBar **daemon** gateway (default port 8317). The Elder
    /// Wand model-fusion orchestrator lives in the daemon, not the Hermes CLI, so
    /// when a fusion preset is active the chat send path redirects here instead of
    /// `hermesGatewayBaseURL` (8642). Host/port mirror the daemon launch config.
    var burnBarGatewayBaseURL: URL {
        let rawHost = settingsManager.gatewayHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = (rawHost.isEmpty || rawHost == "0.0.0.0" || rawHost == "::") ? "127.0.0.1" : rawHost
        let port = settingsManager.gatewayPort > 0 ? settingsManager.gatewayPort : 8317
        return URL(string: "http://\(host):\(port)") ?? URL(string: "http://127.0.0.1:8317")!
    }

    /// Bearer token the daemon gateway enforces (fail-closed by default). Used
    /// when an Elder Wand request is redirected to `burnBarGatewayBaseURL`.
    var burnBarGatewayBearerToken: String? {
        let t = settingsManager.gatewayAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    var openClawBearerToken: String? {
        let t = settingsManager.openClawBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    func setChatBackend(_ backend: ChatBackendID) {
        Task { await setChatBackendAsync(backend) }
    }

    func setChatBackendAsync(_ backend: ChatBackendID) async {
        guard backend != chatBackend else {
            await probeHermesAvailability()
            await probeOpenClawAvailability()
            return
        }

        streamTask?.cancel()
        cliBridge.cancel()
        streamTask = nil
        isStreaming = false
        activeStreamMessageId = nil
        streamError = nil
        completedFusionSessionToken = nil
        selectedContext = nil
        conversationJumpTargets = []
        fxResumeSessionID = nil
        revokeDesktopControl()

        persistActiveThreadSlot()

        let previousBackend = chatBackend
        chatBackend = backend
        Analytics.shared.track(.chatBackendSwitched, [
            "backend": .string(backend.rawValue),
            "previous_backend": .string(previousBackend.rawValue)
        ])
        // A tiling pane (persistsViewState == false) is bound to a fixed thread:
        // switching its engine keeps the SAME conversation and writes NO global keys.
        // It must never re-resolve the thread from the shared per-backend slot.
        if persistsViewState {
            UserDefaults.standard.set(backend.rawValue, forKey: Self.udChatBackend)

            let nextThread = await resolveThreadID(for: backend, createIfMissing: true)
            activeThreadID = nextThread
            let fetchedMessages: [ChatMessageRecord]
            do {
                fetchedMessages = try await dataStore.fetchChatMessages(threadID: nextThread)
            } catch {
                AppLogger.chat.silentFailure("fetchChatMessages (switchBackend)", error: error)
                fetchedMessages = []
            }
            guard chatBackend == backend, activeThreadID == nextThread else { return }
            messages = fetchedMessages

            if messages.isEmpty {
                if backend.requiresCLIAssistantConsent {
                    chatViewMode = .cli
                } else {
                    chatViewMode = .agent
                }
            }

            firstAssistantBadgeShown = messages.contains { $0.role == .assistant && $0.cliUsed != nil }
            persistActiveThreadSlot()
        }
        await Task.yield()
        refreshHistory()
        refreshRetrievalHealth(sharedFeaturesAvailable: sharedFeaturesAvailable)
        ensureChatWorkspaceDirectoryExists()
        await probeHermesAvailability()
        await probeOpenClawAvailability()
    }

    /// When Settings removes the active engine from the enabled list, switch to the first remaining one.
    func syncChatBackendWithEnabledBackends() {
        Task { await syncChatBackendWithEnabledBackendsAsync() }
    }

    func syncChatBackendWithEnabledBackendsAsync() async {
        let enabled = settingsManager.enabledChatBackends
        guard !enabled.isEmpty else { return }
        guard enabled.contains(chatBackend) == false else { return }
        await setChatBackendAsync(enabled[0])
    }

    static func migrateLegacyChatModeIfNeeded() {
        guard UserDefaults.standard.string(forKey: Self.udChatBackend) == nil else { return }
        if let old = UserDefaults.standard.string(forKey: Self.udChatMode), old == "hermes" {
            UserDefaults.standard.set(ChatBackendID.hermes.rawValue, forKey: Self.udChatBackend)
        } else {
            UserDefaults.standard.set(ChatBackendID.codex.rawValue, forKey: Self.udChatBackend)
        }
    }

    static func migrateThreadIDSlotsIfNeeded() {
        let def = UserDefaults.standard
        if def.string(forKey: Self.threadStorageKey(for: .codex)) == nil,
           let old = def.string(forKey: Self.udThreadIDLocalIndex) {
            def.set(old, forKey: Self.threadStorageKey(for: .codex))
        }
        if def.string(forKey: Self.threadStorageKey(for: .hermes)) == nil,
           let old = def.string(forKey: Self.udThreadIDHermes) {
            def.set(old, forKey: Self.threadStorageKey(for: .hermes))
        }
    }
}

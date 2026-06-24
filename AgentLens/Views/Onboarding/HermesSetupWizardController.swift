import Foundation
import SwiftUI

// MARK: - HermesSetupWizardController

/// Observable state machine for the Prepare Hermes wizard.
///
/// The wizard view (`HermesSetupWizardView`) is pure presentation; every
/// mutating action flows through this controller so the reachability logic,
/// the "make gateway reachable" remediation, and the step-gating rules are
/// unit-testable without a SwiftUI snapshot harness.
///
/// The controller is a thin orchestration layer over three already-tested
/// services:
///   • `HermesRuntimeLauncher` — gateway/dashboard lifecycle and probing.
///   • `HermesEnvironmentFile` — `~/.hermes/.env` API-server flag and key.
///   • `CLIBridge` — Hermes CLI resolution and the verification chat turn.
///
/// It owns no I/O of its own; everything funnels through
/// `HermesSetupWizardDependencies` so tests inject fakes exactly the way
/// `HermesRuntimeLauncherTests` does.
@Observable
@MainActor
final class HermesSetupWizardController {

    // MARK: Step

    var currentStep: HermesSetupStep = .prepare {
        didSet { guard currentStep != oldValue else { return }; navigationDirection = .trailing }
    }

    /// Direction the next step transition should travel. Set to `.leading`
    /// by `navigateBack()` so the asymmetric slide reverses cleanly.
    var navigationDirection: Edge = .trailing

    // MARK: Prepare step state

    /// `nil` = not checked yet. `true`/`false` = resolved.
    var hermesCLIInstalled: Bool?
    var hermesCLIPath: String?
    var isCheckingCLI = false

    var envFileExists: Bool?
    var apiServerEnabled: Bool?
    var hasAPIServerKey: Bool?
    var isCheckingConfig = false

    /// User-editable bearer token; pre-filled from settings, written back on
    /// completion. Empty means "let the launcher read the `.env` key."
    var bearerTokenInput: String = ""

    // MARK: Connect step state

    var isGatewayRunning = false
    var isDashboardRunning = false
    var isProbingGateway = false
    var gatewayModelName: String?
    var probeAttempts = 0
    var lastGatewayMessage: String = ""
    var isMakingReachable = false
    var makeReachableError: String?

    /// Derived, single source of truth for the Connect step's hero card.
    var reachability: GatewayReachabilityState {
        if hermesCLIInstalled == false { return .cliMissing }
        if apiServerEnabled != true { return .apiServerDisabled }
        if isGatewayRunning { return .gatewayRunning }
        if isDashboardRunning { return .dashboardOnly }
        if probeAttempts == 0 { return .unknown }
        return .unreachable
    }

    // MARK: Chat step state

    var isVerifying = false
    var verificationResponse: String?
    var verificationError: String?

    // MARK: Lifecycle

    private let dependencies: HermesSetupWizardDependencies
    private var autoProbeTask: Task<Void, Never>?

    init(dependencies: HermesSetupWizardDependencies) {
        self.dependencies = dependencies
    }

    // MARK: Navigation

    func navigateForward() {
        guard let next = HermesSetupStep(rawValue: currentStep.rawValue + 1) else { return }
        navigationDirection = .trailing
        currentStep = next
    }

    func navigateBack() {
        guard let prev = HermesSetupStep(rawValue: currentStep.rawValue - 1) else { return }
        navigationDirection = .leading
        currentStep = prev
    }

    // MARK: Prepare step

    func checkCLI() {
        guard !isCheckingCLI else { return }
        isCheckingCLI = true
        hermesCLIInstalled = nil
        hermesCLIPath = nil
        Task { @MainActor in
            let resolved = await dependencies.resolveHermesExecutable()
            hermesCLIInstalled = resolved != nil
            hermesCLIPath = resolved
            isCheckingCLI = false
        }
    }

    func checkConfig() {
        guard !isCheckingConfig else { return }
        isCheckingConfig = true
        envFileExists = nil
        apiServerEnabled = nil
        hasAPIServerKey = nil
        Task { @MainActor in
            let snapshot = await dependencies.readEnvSnapshot()
            envFileExists = snapshot.fileExists
            apiServerEnabled = snapshot.apiServerEnabled
            hasAPIServerKey = snapshot.hasAPIServerKey
            if bearerTokenInput.isEmpty {
                bearerTokenInput = snapshot.savedBearerToken
            }
            isCheckingConfig = false
        }
    }

    func writeEnvFile() {
        Task { @MainActor in
            do {
                try await dependencies.ensureAPIServerEnabled()
                checkConfig()
            } catch {
                apiServerEnabled = false
            }
        }
    }

    /// Prepare-step Continue gate: CLI present and API server enabled.
    var canContinueFromPrepare: Bool {
        hermesCLIInstalled == true && apiServerEnabled == true
    }

    // MARK: Connect step — the "make it reachable" action

    /// Starts auto-probing on appear. Probes immediately, then every 3s for up
    /// to 30 attempts (90s) — but stops the moment the gateway becomes
    /// reachable. Cancels on disappear.
    func startAutoProbe() {
        probeGateway()
        autoProbeTask?.cancel()
        autoProbeTask = Task { @MainActor in
            for _ in 0..<30 {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled, !isGatewayRunning else { return }
                probeGateway()
            }
        }
    }

    func stopAutoProbe() {
        autoProbeTask?.cancel()
        autoProbeTask = nil
    }

    func probeGateway() {
        guard !isProbingGateway else { return }
        isProbingGateway = true
        probeAttempts += 1
        Task { @MainActor in
            let status = await dependencies.refreshStatus(
                resolvedGatewayBaseURL,
                resolvedBearerToken
            )
            applyStatus(status)
            isProbingGateway = false
        }
    }

    /// The single, unambiguous "make the gateway reachable" action.
    ///
    /// This is the button the old wizard was missing. It does the right thing
    /// for every non-running state:
    ///   • Ensures `API_SERVER_ENABLED=true` is in `~/.hermes/.env`.
    ///   • Installs the gateway if `gateway run` fails (Hermes' own install hook).
    ///   • Launches the gateway detached.
    ///   • Launches the Hermes Dashboard (TUI) if it isn't already running.
    ///   • Re-probes and reflects the new state.
    ///
    /// After it completes, `reachability` flips to `.gatewayRunning` (on
    /// success) or stays non-running with `makeReachableError` set (on
    /// failure), and the Connect-step Continue button enables accordingly.
    func makeGatewayReachable() {
        guard !isMakingReachable else { return }
        isMakingReachable = true
        makeReachableError = nil
        probeAttempts += 1
        Task { @MainActor in
            let status = await dependencies.openHermesAndGateway(
                resolvedGatewayBaseURL,
                resolvedBearerToken
            )
            applyStatus(status)
            if !status.gatewayRunning {
                makeReachableError = status.message.isEmpty
                    ? "Hermes could not start the gateway. Check the Hermes Dashboard for errors, then try again."
                    : status.message
            }
            isMakingReachable = false
        }
    }

    private func applyStatus(_ status: HermesRuntimeStatus) {
        isGatewayRunning = status.gatewayRunning
        isDashboardRunning = status.dashboardRunning
        gatewayModelName = status.modelName
        lastGatewayMessage = status.message
        // If the launcher discovered the CLI path, mirror it so the Prepare
        // step's row stays in sync after a makeReachable that resolved the CLI.
        if hermesCLIPath == nil, let path = status.hermesCLIPath {
            hermesCLIPath = path
            hermesCLIInstalled = true
        }
    }

    var canContinueFromConnect: Bool { isGatewayRunning }

    // MARK: Chat step

    func runVerification() {
        guard !isVerifying else { return }
        isVerifying = true
        verificationResponse = nil
        verificationError = nil
        Task { @MainActor in
            do {
                let response = try await dependencies.runVerificationChat(
                    resolvedGatewayBaseURL,
                    resolvedBearerToken
                )
                let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    verificationError = "Hermes returned an empty response. The gateway might still be initializing \u{2014} try again in a moment."
                } else {
                    verificationResponse = String(trimmed.prefix(300))
                }
            } catch {
                verificationError = error.localizedDescription
            }
            isVerifying = false
        }
    }

    var canRetryVerification: Bool { !isVerifying && isGatewayRunning }

    // MARK: Completion

    func completeHermesSetup(
        settingsManager: SettingsManager,
        chatController: ChatSessionController?
    ) {
        var backends = Set(settingsManager.enabledChatBackends)
        backends.insert(.hermes)
        settingsManager.setEnabledChatBackends(ChatBackendID.allCases.filter { backends.contains($0) })
        let trimmedToken = bearerTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedToken.isEmpty {
            settingsManager.hermesBearerToken = trimmedToken
        }
        chatController?.setChatBackend(.hermes)
        settingsManager.chatBackendOnboardingCompleted = true
        settingsManager.hermesSetupWizardCompleted = true
        dependencies.installHermesSkillIfNeeded()
    }

    // MARK: Resolved values

    /// Overridden in tests via `dependencies.gatewayBaseURLProvider`; in
    /// production this reads `SettingsManager.hermesGatewayBaseURL`.
    var resolvedGatewayBaseURL: URL {
        dependencies.gatewayBaseURLProvider() ?? URL(string: "http://127.0.0.1:8642")!
    }

    var resolvedBearerToken: String? {
        let token = bearerTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}

// MARK: - GatewayReachabilityState

/// The Connect step's status hero renders one of these. Each carries the
/// copy and the single primary action that resolves it, so the view never
/// has to decide what to do — it just asks the state.
enum GatewayReachabilityState: Equatable {
    case unknown
    case cliMissing
    case apiServerDisabled
    case dashboardOnly
    case gatewayRunning
    case unreachable

    var eyebrow: String {
        switch self {
        case .unknown: return "GATEWAY"
        case .cliMissing: return "BLOCKED"
        case .apiServerDisabled: return "CONFIG"
        case .dashboardOnly: return "PARTIAL"
        case .gatewayRunning: return "READY"
        case .unreachable: return "OFFLINE"
        }
    }

    var headline: String {
        switch self {
        case .unknown: return "Waiting for Hermes"
        case .cliMissing: return "Hermes CLI not found"
        case .apiServerDisabled: return "API server is off"
        case .dashboardOnly: return "Dashboard up, gateway down"
        case .gatewayRunning: return "Gateway is reachable"
        case .unreachable: return "Gateway not reachable"
        }
    }

    var detail: String {
        switch self {
        case .unknown:
            return "OpenBurnBar hasn't probed the local gateway yet. Tap Check Health, or make it reachable in one step."
        case .cliMissing:
            return "Install the Hermes CLI, then return here. The wizard can open Terminal and copy the install command for you."
        case .apiServerDisabled:
            return "Hermes is installed but the local API server isn't enabled. OpenBurnBar can add API_SERVER_ENABLED=true to ~/.hermes/.env for you."
        case .dashboardOnly:
            return "The Hermes Dashboard is running, but the local gateway isn't reachable yet. Make it reachable in one step — OpenBurnBar will start the gateway for you."
        case .gatewayRunning:
            return "The local gateway is responding. You can continue to the test chat."
        case .unreachable:
            return "Nothing is responding at the gateway address. Make it reachable in one step — OpenBurnBar will start the gateway and dashboard for you."
        }
    }

    /// The single primary action label for this state. `nil` when there is
    /// nothing for the user to do (gateway already running).
    var primaryActionLabel: String? {
        switch self {
        case .unknown, .dashboardOnly, .unreachable:
            return "Make Gateway Reachable"
        case .cliMissing:
            return nil  // Prepare step owns the install flow.
        case .apiServerDisabled:
            return "Enable API Server"
        case .gatewayRunning:
            return nil
        }
    }

    /// Tint for the status dot and the hero hairline accent.
    var accent: GatewayReachabilityAccent {
        switch self {
        case .unknown: return .neutral
        case .cliMissing: return .blocked
        case .apiServerDisabled: return .warning
        case .dashboardOnly: return .warning
        case .gatewayRunning: return .ready
        case .unreachable: return .blocked
        }
    }

    var isReady: Bool { self == .gatewayRunning }
}

enum GatewayReachabilityAccent: Equatable {
    case neutral, warning, blocked, ready

    @MainActor
    var color: Color {
        switch self {
        case .neutral: return DesignSystem.Colors.hermesAureate
        case .warning: return DesignSystem.Colors.warning
        case .blocked: return DesignSystem.Colors.error
        case .ready: return DesignSystem.Colors.success
        }
    }
}

// MARK: - HermesSetupWizardDependencies

struct HermesEnvSnapshot: Equatable {
    var fileExists: Bool
    var apiServerEnabled: Bool
    var hasAPIServerKey: Bool
    var savedBearerToken: String
}

struct HermesSetupWizardDependencies: Sendable {
    /// `@MainActor` because it reads `SettingsManager` (a `@MainActor` type).
    var gatewayBaseURLProvider: @MainActor @Sendable () -> URL?
    var resolveHermesExecutable: @Sendable () async -> String?
    var readEnvSnapshot: @Sendable () async -> HermesEnvSnapshot
    var ensureAPIServerEnabled: @Sendable () async throws -> Void
    /// `@MainActor` because it constructs `HermesRuntimeLauncher` (a `@MainActor`
    /// `@Observable` class). The controller always awaits this from a
    /// `Task { @MainActor in ... }`, so the main-actor isolation is honored.
    var refreshStatus: @MainActor @Sendable (URL, String?) async -> HermesRuntimeStatus
    var openHermesAndGateway: @MainActor @Sendable (URL, String?) async -> HermesRuntimeStatus
    /// `@MainActor` because it constructs `CLIBridge` (a `@MainActor` type).
    var runVerificationChat: @MainActor @Sendable (URL, String?) async throws -> String
    var installHermesSkillIfNeeded: @Sendable () -> Void

    /// Convenience alias for `makeLive(settingsManager:)` so call sites read
    /// `HermesSetupWizardController(dependencies: .live(settingsManager:))`.
    static func live(settingsManager: SettingsManager) -> HermesSetupWizardDependencies {
        makeLive(settingsManager: settingsManager)
    }

    /// Live factory. `SettingsManager` is captured weakly via the closures the
    /// view passes in at `makeLive(settingsManager:)`, keeping the controller
    /// decoupled from SettingsManager at the type level.
    static func makeLive(settingsManager: SettingsManager) -> HermesSetupWizardDependencies {
        HermesSetupWizardDependencies(
            gatewayBaseURLProvider: { @MainActor in
                let raw = settingsManager.hermesGatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                return raw.isEmpty ? nil : URL(string: raw)
            },
            resolveHermesExecutable: {
                await CLIExecutableResolver().resolveExecutable(named: "hermes")
            },
            readEnvSnapshot: {
                await Self.readEnvSnapshotLive()
            },
            ensureAPIServerEnabled: {
                try await HermesEnvironmentFile.ensureAPIServerEnabled()
            },
            refreshStatus: { @MainActor baseURL, bearerToken in
                let launcher = HermesRuntimeLauncher()
                return await launcher.refreshStatus(baseURL: baseURL, bearerToken: bearerToken)
            },
            openHermesAndGateway: { @MainActor baseURL, bearerToken in
                let launcher = HermesRuntimeLauncher()
                return await launcher.openHermesAndGateway(baseURL: baseURL, bearerToken: bearerToken)
            },
            runVerificationChat: { @MainActor baseURL, bearerToken in
                try await Self.runVerificationChatLive(
                    baseURL: baseURL,
                    bearerToken: bearerToken
                )
            },
            installHermesSkillIfNeeded: {
                Self.installHermesSkillIfNeededLive()
            }
        )
    }

    // MARK: Live helpers

    /// Reads `~/.hermes/.env` and the saved bearer token in one pass so the
    /// Prepare step's two rows stay consistent without two racing tasks.
    private static func readEnvSnapshotLive() async -> HermesEnvSnapshot {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let envPath = "\(homeDir)/.hermes/.env"
        let fm = FileManager.default
        guard fm.fileExists(atPath: envPath),
              let content = try? String(contentsOfFile: envPath, encoding: .utf8)
        else {
            return HermesEnvSnapshot(
                fileExists: false,
                apiServerEnabled: false,
                hasAPIServerKey: false,
                savedBearerToken: ""
            )
        }
        let apiServerEnabled = content.contains("API_SERVER_ENABLED=true")
        let hasKey = content.split(separator: "\n").contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("API_SERVER_KEY=") else { return false }
            let value = trimmed.dropFirst("API_SERVER_KEY=".count)
            return !value.isEmpty && value != "\"\"" && value != "''"
        }
        return HermesEnvSnapshot(
            fileExists: true,
            apiServerEnabled: apiServerEnabled,
            hasAPIServerKey: hasKey,
            savedBearerToken: await HermesEnvironmentFile.readAPIServerKey() ?? ""
        )
    }

    @MainActor
    private static func runVerificationChatLive(
        baseURL: URL,
        bearerToken: String?
    ) async throws -> String {
        let bridge = CLIBridge()
        let systemPrompt = "You are a test assistant. Reply with exactly: \"Hermes is ready.\" Nothing else."
        let userMessage = "Hello. Reply with exactly: \"Hermes is ready.\" Nothing else."
        var response = ""
        let stream = bridge.chatHermes(
            baseURL: baseURL,
            systemPrompt: systemPrompt,
            history: [ChatMessageRecord(role: .user, content: userMessage)],
            bearerToken: bearerToken
        )
        for try await event in stream {
            if case .text(let chunk) = event {
                response += chunk
            }
        }
        return response
    }

    /// Symlinks the burnbar-operator Hermes skill from the repo into
    /// `~/.hermes/skills/`. The repo copy at
    /// `tools/openburnbar-mcp/hermes-skill/SKILL.md` is the source of truth.
    /// Preserved verbatim from the original wizard's completion path.
    private static func installHermesSkillIfNeededLive() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let hermesDir = "\(home)/.hermes"
        let skillDir = "\(hermesDir)/skills/software-development/burnbar-operator"
        let target = "\(skillDir)/SKILL.md"

        guard fm.fileExists(atPath: hermesDir) else { return }

        let candidates: [String] = [
            "\(home)/Documents/Windsurf/BurnBar/tools/openburnbar-mcp/hermes-skill/SKILL.md",
            Bundle.main.bundleURL.deletingLastPathComponent()
                .appendingPathComponent("tools/openburnbar-mcp/hermes-skill/SKILL.md")
                .path
        ]
        guard let repoSkill = candidates.first(where: { fm.fileExists(atPath: $0) }) else { return }

        try? fm.createDirectory(atPath: skillDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: target) {
            try? fm.removeItem(atPath: target)
        }
        try? fm.createSymbolicLink(atPath: target, withDestinationPath: repoSkill)
    }
}

// MARK: - HermesSetupStep (shared)

enum HermesSetupStep: Int, CaseIterable {
    case prepare
    case connect
    case chat

    var progressFraction: Double {
        Double(rawValue) / Double(Self.allCases.count - 1)
    }

    var stepLabel: String {
        switch self {
        case .prepare: return "1 · Prepare"
        case .connect: return "2 · Connect"
        case .chat: return "3 · Chat"
        }
    }

    var headline: String {
        switch self {
        case .prepare: return "Prepare Hermes"
        case .connect: return "Connect the gateway"
        case .chat: return "Start chatting"
        }
    }
}

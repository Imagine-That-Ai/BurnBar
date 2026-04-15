import SwiftUI
import AppKit
import OpenBurnBarCore

struct ProvidersSettingsView: View {
    @Bindable var settingsManager: SettingsManager
    @Bindable var daemonManager: OpenBurnBarDaemonManager
    let dataStore: DataStore

    @State private var quotaService = ProviderQuotaService.shared

    @State private var wizardProviderID: ProviderWizardTarget?

    private var providers: [AgentProvider] {
        AgentProvider.allCases.sorted { $0.displayName < $1.displayName }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                SettingsSectionHeader(title: "Routed Providers")

                GlassCard {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Daemon routing")
                                    .font(DesignSystem.Typography.body)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                                Text("OpenBurnBar's routed providers live behind the local daemon and are mirrored here from the daemon config.")
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                            }
                            Spacer()
                            Button("Refresh") {
                                Task { await daemonManager.refreshHealth() }
                            }
                            .buttonStyle(.bordered)
                        }

                        if daemonManager.providerConfigurations.isEmpty {
                            Text("No daemon provider configuration is available yet. Install or repair the daemon to manage routed providers.")
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        } else {
                            ForEach(daemonManager.providerConfigurations) { configuration in
                                providerCard(configuration)

                                if configuration.id != daemonManager.providerConfigurations.last?.id {
                                    Divider().background(DesignSystem.Colors.border)
                                }
                            }
                        }
                    }
                    .padding(DesignSystem.Spacing.lg)
                }

                SettingsSectionHeader(title: "Quota Reporting")

                ProviderQuotaSettingsSection(
                    settingsManager: settingsManager,
                    quotaService: quotaService,
                    dataStore: dataStore,
                    onOpenProviderPlans: openProviderPlans(for:),
                    quotaSourceSummary: quotaSourceSummary(for:)
                )

                SettingsSectionHeader(title: "CLI Connections")

                CLIConnectionsSettingsSection()

                SettingsSectionHeader(title: "Observed Log Sources")

                GlassCard {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                        ForEach(providers) { provider in
                            ProviderObservationRow(
                                provider: provider,
                                configuredPath: settingsManager.logPaths[provider] ?? provider.logDirectory,
                                isDetected: settingsManager.detectAvailableProviders()[provider] ?? false
                            )

                            if provider.id != providers.last?.id {
                                Divider().background(DesignSystem.Colors.border)
                            }
                        }
                    }
                    .padding(DesignSystem.Spacing.lg)
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background(DesignSystem.Colors.background)
        .scrollContentBackground(.hidden)
        .sheet(item: $wizardProviderID) { target in
            ProviderPlanWizardView(
                daemonManager: daemonManager,
                initialProviderID: target.providerID
            ) {
                wizardProviderID = nil
            }
        }
        .task {
            await daemonManager.refreshHealth()
        }
    }

    // MARK: - Provider Card

    @ViewBuilder
    private func providerCard(_ config: OpenBurnBarDaemonProviderConfiguration) -> some View {
        Button {
            wizardProviderID = ProviderWizardTarget(providerID: config.providerID)
        } label: {
            HStack(spacing: DesignSystem.Spacing.md) {
                CatalogProviderLogoView(brand: config.brand, size: 28)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Text(config.displayName)
                            .font(DesignSystem.Typography.headline)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)

                        if config.isEnabled == false {
                            Text("Off")
                                .font(DesignSystem.Typography.tiny)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(DesignSystem.Colors.textMuted.opacity(0.15))
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                .clipShape(Capsule())
                        }
                    }

                    if config.credentialSlots.isEmpty {
                        Text("No plans configured")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    } else {
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            ForEach(config.credentialSlots) { slot in
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(slotStatusColor(for: slot.status))
                                        .frame(width: 6, height: 6)
                                    Text(slot.label)
                                        .font(DesignSystem.Typography.tiny)
                                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                                    if let pct = slot.lastQuotaRemainingPercent {
                                        Text("\(Int(pct.rounded()))%")
                                            .font(DesignSystem.Typography.monoTiny)
                                            .foregroundStyle(DesignSystem.Colors.textMuted)
                                    }
                                }
                            }
                        }
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .padding(DesignSystem.Spacing.md)
            .background(DesignSystem.Colors.surfaceElevated.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func slotStatusColor(for status: BurnBarProviderCredentialSlotStatus) -> Color {
        switch status {
        case .ready: return DesignSystem.Colors.success
        case .coolingDown: return DesignSystem.Colors.warning
        case .exhausted, .missingSecret: return DesignSystem.Colors.error
        case .disabled: return DesignSystem.Colors.textMuted
        }
    }

    private func openProviderPlans(for provider: AgentProvider) {
        guard let providerID = provider.providerCatalogID else { return }
        wizardProviderID = ProviderWizardTarget(providerID: providerID)
    }

    private func quotaSourceSummary(for provider: AgentProvider) -> String? {
        switch provider {
        case .minimax, .zai:
            guard let configuration = daemonManager.providerConfigurations.first(where: { $0.provider == provider }) else {
                return "No routed provider plan is configured yet."
            }
            guard !configuration.credentialSlots.isEmpty else {
                return "No provider plans configured yet."
            }
            if let preferredSlotID = configuration.preferredCredentialSlotID,
               let preferredSlot = configuration.credentialSlots.first(where: { $0.slotID == preferredSlotID }) {
                return "Using preferred daemon plan “\(preferredSlot.label)” for quota refresh when available."
            }
            if let firstEnabledSlot = configuration.credentialSlots.first(where: \.isEnabled) {
                return "Using daemon plan “\(firstEnabledSlot.label)” for quota refresh when available."
            }
            return "Provider plans exist, but none are enabled for quota refresh."
        case .codex:
            return "Quota comes from local Codex rollout/session logs on this Mac."
        case .claudeCode:
            return "Quota comes from Claude Code status line payloads captured locally."
        case .factory:
            return "Factory quota uses your local session credentials or selected plan tier."
        case .cursor:
            return "Cursor quota uses the configured cookie header or local routed-token estimates."
        default:
            return nil
        }
    }
}

// MARK: - Wizard Sheet Target

private struct ProviderWizardTarget: Identifiable {
    let providerID: String
    var id: String { providerID }
}

private struct ProviderObservationRow: View {
    let provider: AgentProvider
    let configuredPath: String
    let isDetected: Bool

    private var supportLabel: String {
        switch provider.supportLevel {
        case .supported: return "Supported"
        case .partial: return "Partial"
        case .unsupported: return "Not yet supported"
        }
    }

    private var supportColor: Color {
        switch provider.supportLevel {
        case .supported: return DesignSystem.Colors.success
        case .partial: return DesignSystem.Colors.warning
        case .unsupported: return DesignSystem.Colors.textMuted
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            ProviderLogoView(provider: provider, size: 20, useFallbackColor: false)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Text(provider.displayName)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(supportLabel)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(supportColor)
                }

                Text(configuredPath)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .textSelection(.enabled)

                Text(isDetected ? "Detected on this Mac" : "Not currently detected")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(isDetected ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted)
            }

            Spacer()
        }
    }
}

private struct CLIConnectionsSettingsSection: View {
    @State private var authStates: [SwitcherCLIProfileType: CLIAuthInfo] = [:]
    @State private var testResults: [SwitcherCLIProfileType: String] = [:]
    @State private var activeTests: Set<SwitcherCLIProfileType> = []
    @State private var activeLogins: Set<SwitcherCLIProfileType> = []

    private let supportedCLIs: [SwitcherCLIProfileType] = [.claude, .codex]

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                Text("Check whether Claude Code and Codex are installed and authenticated, then open their login flow in Terminal when needed.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                ForEach(supportedCLIs, id: \.self) { cliType in
                    CLIConnectionCard(
                        cliType: cliType,
                        authInfo: authStates[cliType],
                        testResult: testResults[cliType],
                        isTesting: activeTests.contains(cliType),
                        isLoggingIn: activeLogins.contains(cliType),
                        onTest: { runCheck(for: cliType) },
                        onLogin: { openLogin(for: cliType) }
                    )

                    if cliType != supportedCLIs.last {
                        Divider().background(DesignSystem.Colors.border)
                    }
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .task {
            refreshAll()
        }
    }

    private func refreshAll() {
        for cliType in supportedCLIs {
            authStates[cliType] = CLIAuthDiscovery.discoverAuthState(for: cliType)
            testResults[cliType] = nil
        }
    }

    private func runCheck(for cliType: SwitcherCLIProfileType) {
        activeTests.insert(cliType)
        defer { activeTests.remove(cliType) }

        let authInfo = CLIAuthDiscovery.discoverAuthState(for: cliType)
        authStates[cliType] = authInfo
        testResults[cliType] = statusSummary(for: authInfo)
    }

    private func openLogin(for cliType: SwitcherCLIProfileType) {
        guard let executablePath = CLILaunchAdapter.executablePath(for: cliType) else {
            testResults[cliType] = "\(cliType.displayName) is not installed."
            return
        }

        activeLogins.insert(cliType)
        defer { activeLogins.remove(cliType) }

        let command = loginCommands(for: cliType, executablePath: executablePath).first
        guard let command else {
            testResults[cliType] = "No login command is available for \(cliType.displayName)."
            return
        }

        do {
            let scriptURL = try makeLoginScript(command: command, title: cliType.displayName)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([scriptURL], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: configuration) { _, error in
                if let error {
                    testResults[cliType] = "Could not open Terminal: \(error.localizedDescription)"
                    return
                }
                testResults[cliType] = "Opened \(cliType.displayName) login in Terminal. Run Test again after signing in."
            }
        } catch {
            testResults[cliType] = "Could not prepare login command: \(error.localizedDescription)"
        }
    }

    private func loginCommands(for cliType: SwitcherCLIProfileType, executablePath: String) -> [String] {
        let candidates: [[String]]
        switch cliType {
        case .codex:
            candidates = [["login"], ["auth", "login"]]
        case .claude:
            candidates = [["auth", "login"], ["login"]]
        case .opencode:
            candidates = []
        }

        return candidates.map { args in
            ([executablePath] + args).map(shellEscape).joined(separator: " ")
        }
    }

    private func makeLoginScript(command: String, title: String) throws -> URL {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))-\(UUID().uuidString).command")
        let contents = """
        #!/bin/zsh
        \(command)
        printf '\\nPress Enter to close…'
        read
        """
        try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func statusSummary(for authInfo: CLIAuthInfo) -> String {
        guard authInfo.isInstalled else {
            return "\(authInfo.cliType.displayName) is not installed."
        }

        switch authInfo.authState {
        case .authenticated:
            if let accountDescription = authInfo.accountDescription {
                return "Connected as \(accountDescription)."
            }
            return "Connected."
        case .apiKeyPresent:
            return "API key detected."
        case .notAuthenticated:
            return "Installed, but not authenticated."
        case .notInstalled:
            return "Not installed."
        }
    }
}

private struct CLIConnectionCard: View {
    let cliType: SwitcherCLIProfileType
    let authInfo: CLIAuthInfo?
    let testResult: String?
    let isTesting: Bool
    let isLoggingIn: Bool
    let onTest: () -> Void
    let onLogin: () -> Void

    private var stateColor: Color {
        guard let authInfo else { return DesignSystem.Colors.textMuted }
        switch authInfo.authState {
        case .authenticated, .apiKeyPresent:
            return DesignSystem.Colors.success
        case .notAuthenticated:
            return DesignSystem.Colors.warning
        case .notInstalled:
            return DesignSystem.Colors.error
        }
    }

    private var stateLabel: String {
        guard let authInfo else { return "Checking…" }
        switch authInfo.authState {
        case .authenticated:
            return "Connected"
        case .apiKeyPresent:
            return "API key present"
        case .notAuthenticated:
            return "Needs login"
        case .notInstalled:
            return "Not installed"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            ProviderLogoView(provider: cliType.provider, size: 28, useFallbackColor: true)

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Text(cliType.displayName)
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(stateLabel)
                        .font(DesignSystem.Typography.tiny)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(stateColor.opacity(0.14))
                        .foregroundStyle(stateColor)
                        .clipShape(Capsule())
                }

                if let accountDescription = authInfo?.accountDescription, !accountDescription.isEmpty {
                    Text(accountDescription)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }

                if let executablePath = authInfo?.executablePath {
                    Text(executablePath)
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .textSelection(.enabled)
                }

                if let configDirectory = authInfo?.configDirectory {
                    Text(configDirectory)
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .textSelection(.enabled)
                }

                Text(testResult ?? helperText)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: DesignSystem.Spacing.sm) {
                Button(isTesting ? "Testing…" : "Test") {
                    onTest()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isTesting)

                Button(isLoggingIn ? "Opening…" : loginButtonTitle) {
                    onLogin()
                }
                .buttonStyle(.bordered)
                .disabled(isLoggingIn)
            }
        }
    }

    private var loginButtonTitle: String {
        switch authInfo?.authState {
        case .authenticated, .apiKeyPresent:
            return "Reconnect"
        default:
            return "Connect"
        }
    }

    private var helperText: String {
        switch cliType {
        case .claude:
            return "Claude Code must be logged in locally before BurnBar can confirm the CLI connection."
        case .codex:
            return "Codex supports either OAuth or an OpenAI API key in the local config."
        case .opencode:
            return ""
        }
    }
}

private extension SwitcherCLIProfileType {
    var provider: AgentProvider {
        switch self {
        case .claude:
            return .claudeCode
        case .codex:
            return .codex
        case .opencode:
            return .openClaw
        }
    }
}

private extension AgentProvider {
    var providerCatalogID: String? {
        switch self {
        case .minimax:
            return "minimax"
        case .zai:
            return "zai"
        default:
            return nil
        }
    }
}

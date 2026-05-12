import SwiftUI

// MARK: - Wizard Steps

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

private struct HermesInventoryImportSetupCard: View {
    @Bindable var service: HermesInventoryImportService

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "books.vertical.fill")
                        .foregroundStyle(DesignSystem.Colors.hermesAureate)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Bring your Hermes history")
                            .font(DesignSystem.Typography.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Text("Import existing conversations now, then choose whether iPhone/iPad can read them through OpenBurnBar Cloud or your iCloud Drive archive.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text(service.primaryStatusText)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(statusColor)

                if service.hasImportableInventory {
                    HStack(spacing: DesignSystem.Spacing.lg) {
                        metric("Chats", "\(service.summary.conversationCount)")
                        metric("Usage", "\(service.summary.usageEventCount)")
                        if let latest = service.summary.lastActivityAt {
                            metric("Latest", latest.formatted(date: .abbreviated, time: .omitted))
                        }
                    }

                    Toggle("OpenBurnBar Cloud for iPhone/iPad", isOn: Binding(
                        get: { service.decision.backupToOpenBurnBarCloud },
                        set: { service.decision.backupToOpenBurnBarCloud = $0 }
                    ))
                    .font(DesignSystem.Typography.caption)

                    Toggle("iCloud Drive archive", isOn: Binding(
                        get: { service.decision.mirrorToICloud },
                        set: { service.decision.mirrorToICloud = $0 }
                    ))
                    .font(DesignSystem.Typography.caption)
                }

                HStack {
                    Button {
                        Task { await service.scan() }
                    } label: {
                        Label("Scan History", systemImage: "magnifyingglass")
                    }
                    .disabled(isBusy)

                    Spacer()

                    Button {
                        Task { await service.importInventory() }
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignSystem.Colors.hermesAureate)
                    .disabled(isBusy || !service.hasImportableInventory)
                }
                .controlSize(.small)
                .font(DesignSystem.Typography.caption)
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .task {
            if service.phase == .idle {
                await service.scan()
            }
        }
    }

    private var isBusy: Bool {
        switch service.phase {
        case .scanning, .importing:
            return true
        default:
            return false
        }
    }

    private var statusColor: Color {
        switch service.phase {
        case .failed:
            return DesignSystem.Colors.error
        case .complete:
            return DesignSystem.Colors.success
        default:
            return DesignSystem.Colors.textSecondary
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(DesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            Text(label)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }
}

// MARK: - Main Wizard View

struct HermesSetupWizardView: View {
    let settingsManager: SettingsManager
    let chatController: ChatSessionController?
    let inventoryImportService: HermesInventoryImportService?
    let onDismiss: () -> Void

    @Environment(\.openURL) private var openURL

    @State private var currentStep: HermesSetupStep = .prepare
    @State private var navigationDirection: Edge = .trailing
    @State private var hermesRuntimeLauncher = HermesRuntimeLauncher()

    // Install step state
    @State private var hermesCLIInstalled: Bool?
    @State private var hermesCLIPath: String?
    @State private var isCheckingCLI = false

    // Configure step state
    @State private var envFileExists: Bool?
    @State private var apiServerEnabled: Bool?
    @State private var hasAPIServerKey: Bool?
    @State private var bearerTokenInput: String = ""
    @State private var isCheckingConfig = false

    // Start step state
    @State private var isGatewayRunning: Bool = false
    @State private var isProbingGateway: Bool = false
    @State private var gatewayModelName: String?
    @State private var probeAttempts: Int = 0

    // Verify step state
    @State private var isVerifying: Bool = false
    @State private var verificationResponse: String?
    @State private var verificationError: String?
    @State private var probePulseScale: CGFloat = 1.0
    @State private var autoProbeTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: DesignSystem.Spacing.sm) {
                Button {
                    if currentStep != .prepare {
                        navigateBack()
                    } else {
                        onDismiss()
                    }
                } label: {
                    Image(systemName: currentStep == .prepare ? "xmark" : "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)

                // Step dots
                HStack(spacing: DesignSystem.Spacing.xxs) {
                    ForEach(HermesSetupStep.allCases, id: \.rawValue) { step in
                        Capsule()
                            .fill(stepColor(for: step))
                            .frame(
                                width: step == currentStep ? 20 : 6,
                                height: 6
                            )
                            .animation(DesignSystem.Animation.snappy, value: currentStep)
                    }
                }

                Spacer()

                Text(currentStep.stepLabel)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.top, DesignSystem.Spacing.md)
            .padding(.bottom, DesignSystem.Spacing.sm)

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(DesignSystem.Colors.borderSubtle)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(DesignSystem.Colors.mercuryGradient)
                        .frame(width: geo.size.width * currentStep.progressFraction)
                        .animation(DesignSystem.Animation.gentle, value: currentStep)
                }
            }
            .frame(height: 2)

            // Step content
            Group {
                switch currentStep {
                case .prepare:
                    hermesPrepareStep
                case .connect:
                    hermesConnectStep
                case .chat:
                    hermesChatStep
                }
            }
            .padding(DesignSystem.Spacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(
                insertion: .move(edge: navigationDirection).combined(with: .opacity),
                removal: .move(edge: navigationDirection == .trailing ? .leading : .trailing).combined(with: .opacity)
            ))
        }
        .frame(width: 520, height: 540)
        .background(DesignSystem.Colors.background)
        .preferredColorScheme(settingsManager.preferredSwiftUIColorScheme)
    }

    // MARK: - Step Colors

    private func stepColor(for step: HermesSetupStep) -> Color {
        if step.rawValue < currentStep.rawValue {
            return DesignSystem.Colors.success
        } else if step == currentStep {
            return DesignSystem.Colors.hermesAureate
        } else {
            return DesignSystem.Colors.border
        }
    }

    // MARK: - Navigation

    private func navigateForward() {
        guard let next = HermesSetupStep(rawValue: currentStep.rawValue + 1) else { return }
        navigationDirection = .trailing
        withAnimation(DesignSystem.Animation.gentle) {
            currentStep = next
        }
    }

    private func navigateBack() {
        guard let prev = HermesSetupStep(rawValue: currentStep.rawValue - 1) else { return }
        navigationDirection = .leading
        withAnimation(DesignSystem.Animation.gentle) {
            currentStep = prev
        }
    }

    // MARK: - 1-2-3 Wizard

    private var hermesPrepareStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            simpleStepHeader(
                number: "1",
                title: "Prepare Hermes",
                subtitle: "Install the CLI once and let OpenBurnBar turn on the local API server."
            )

            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    setupStatusRow(
                        icon: "terminal",
                        title: "Hermes CLI",
                        detail: hermesCLIPath ?? "Needed to run the gateway on this Mac.",
                        isReady: hermesCLIInstalled == true,
                        isChecking: isCheckingCLI
                    )

                    if hermesCLIInstalled == false {
                        commandCopyRow(
                            label: "Install command",
                            command: "npm install -g @hermesai/cli"
                        )
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            Button("Open Terminal") {
                                if let url = URL(string: "terminal://") {
                                    openURL(url)
                                } else {
                                    NSWorkspace.shared.open(
                                        URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
                                    )
                                }
                            }
                            .buttonStyle(.bordered)

                            Button("Re-check") {
                                checkCLI()
                            }
                            .buttonStyle(.bordered)
                        }
                        .font(DesignSystem.Typography.caption)
                    }

                    Divider().background(DesignSystem.Colors.border)

                    setupStatusRow(
                        icon: "switch.2",
                        title: "API server",
                        detail: apiServerEnabled == true
                            ? "~/.hermes/.env includes API_SERVER_ENABLED=true"
                            : "OpenBurnBar can add API_SERVER_ENABLED=true for you.",
                        isReady: apiServerEnabled == true,
                        isChecking: isCheckingConfig
                    )

                    if apiServerEnabled != true {
                        Button {
                            writeEnvFile()
                        } label: {
                            Label("Enable API Server", systemImage: "wrench.and.screwdriver")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(DesignSystem.Colors.hermesAureate)
                        .font(DesignSystem.Typography.caption)
                    }

                    HStack {
                        Button("Re-check") {
                            checkCLI()
                            checkConfig()
                        }
                        .buttonStyle(.plain)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)

                        Spacer()

                        Button("Continue") {
                            navigateForward()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(DesignSystem.Colors.hermesAureate)
                        .disabled(hermesCLIInstalled != true || apiServerEnabled != true)
                    }
                }
                .padding(DesignSystem.Spacing.lg)
            }

            Spacer()
        }
        .onAppear {
            checkCLI()
            checkConfig()
        }
    }

    private var hermesConnectStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            simpleStepHeader(
                number: "2",
                title: "Connect the gateway",
                subtitle: "Run Hermes locally, then optionally make this Mac the relay host for iPhone and iPad."
            )

            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Button {
                            openHermesRuntime()
                        } label: {
                            Label("Open Hermes + Gateway", systemImage: "play.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(DesignSystem.Colors.hermesAureate)
                        .disabled(hermesRuntimeLauncher.isBusy)

                        Button {
                            probeGateway()
                        } label: {
                            Label("Check Health", systemImage: "waveform.path.ecg")
                        }
                        .buttonStyle(.bordered)
                        .disabled(hermesRuntimeLauncher.isBusy)
                    }
                    .controlSize(.small)
                    .font(DesignSystem.Typography.caption)

                    HStack(spacing: DesignSystem.Spacing.md) {
                        ZStack {
                            Circle()
                                .fill(statusDotColor)
                                .frame(width: 12, height: 12)

                            if isProbingGateway {
                                Circle()
                                    .stroke(statusDotColor.opacity(0.4), lineWidth: 2)
                                    .frame(width: 20, height: 20)
                            }
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(statusText)
                                .font(DesignSystem.Typography.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(statusDotColor)

                            if !hermesRuntimeLauncher.status.message.isEmpty {
                                Text(hermesRuntimeLauncher.status.message)
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            if isGatewayRunning, let model = gatewayModelName {
                                Text("Model: \(model)")
                                    .font(DesignSystem.Typography.monoTiny)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                            }
                        }

                        Spacer()

                        Button("Re-check") {
                            probeGateway()
                        }
                        .buttonStyle(.plain)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.hermesAureate)
                    }

                    Toggle("Launch Hermes Dashboard and gateway when OpenBurnBar opens", isOn: Binding(
                        get: { settingsManager.launchHermesWithOpenBurnBar },
                        set: { settingsManager.launchHermesWithOpenBurnBar = $0 }
                    ))
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                    Toggle(isOn: Binding(
                        get: { settingsManager.hermesRemoteRelayEnabled },
                        set: { settingsManager.hermesRemoteRelayEnabled = $0 }
                    )) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Relay to iPhone and iPad")
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                            Text("When signed in, this Mac advertises a private Remote Relay host for your mobile devices.")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)

                    HStack {
                        Button("Back") {
                            navigateBack()
                        }
                        .buttonStyle(.plain)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)

                        Spacer()

                        Button("Continue") {
                            navigateForward()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(DesignSystem.Colors.hermesAureate)
                        .disabled(!isGatewayRunning)
                    }
                }
                .padding(DesignSystem.Spacing.lg)
            }

            Spacer()
        }
        .onAppear {
            startAutoProbe()
        }
        .onDisappear {
            autoProbeTask?.cancel()
        }
    }

    private var hermesChatStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            simpleStepHeader(
                number: "3",
                title: "Start chatting",
                subtitle: "Send one tiny test prompt. If Hermes answers, OpenBurnBar will enable it as a chat engine."
            )

            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    if isVerifying {
                        HStack(spacing: DesignSystem.Spacing.md) {
                            HermesThinkingView()
                                .frame(width: 48, height: 28)
                            Text("Asking Hermes to confirm it is ready…")
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        }
                    } else if let response = verificationResponse {
                        setupStatusRow(
                            icon: "checkmark.seal.fill",
                            title: "Hermes answered",
                            detail: response,
                            isReady: true,
                            isChecking: false
                        )
                    } else if let error = verificationError {
                        setupStatusRow(
                            icon: "exclamationmark.triangle.fill",
                            title: "Test failed",
                            detail: error,
                            isReady: false,
                            isChecking: false
                        )
                    } else {
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                            Text("Test prompt")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)

                            Text("Reply with exactly: \"Hermes is ready.\" Nothing else.")
                                .font(DesignSystem.Typography.monoSmall)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                                .padding(DesignSystem.Spacing.sm)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                        .fill(DesignSystem.Colors.surface)
                                )
                        }
                    }

                    HStack {
                        Button("Back") {
                            navigateBack()
                        }
                        .buttonStyle(.plain)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)

                        Spacer()

                        if verificationResponse == nil {
                            Button(verificationError == nil ? "Send Test Message" : "Try Again") {
                                runVerification()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(DesignSystem.Colors.hermesAureate)
                            .disabled(isVerifying || !isGatewayRunning)
                        } else {
                            Button("Start Using Hermes") {
                                completeHermesSetup()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(DesignSystem.Colors.hermesAureate)
                        }
                    }
                }
                .padding(DesignSystem.Spacing.lg)
            }

            if let inventoryImportService {
                HermesInventoryImportSetupCard(service: inventoryImportService)
            }

            Spacer()
        }
    }

    private func simpleStepHeader(number: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            ZStack {
                Circle()
                    .fill(DesignSystem.Colors.mercuryGradient)
                    .frame(width: 44, height: 44)
                Text(number)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(hex: "151210"))
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text(title)
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(subtitle)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func setupStatusRow(
        icon: String,
        title: String,
        detail: String,
        isReady: Bool,
        isChecking: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            ZStack {
                Circle()
                    .fill(statusBackgroundColor(isReady: isReady, isChecking: isChecking))
                    .frame(width: 34, height: 34)
                if isChecking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: isReady ? "checkmark" : icon)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(isReady ? DesignSystem.Colors.success : DesignSystem.Colors.hermesAureate)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(DesignSystem.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(detail)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func commandCopyRow(label: String, command: String) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text(label)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            HStack {
                Text(command)
                    .font(DesignSystem.Typography.monoSmall)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .buttonStyle(.plain)
                .help("Copy command")
            }
            .padding(DesignSystem.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .fill(DesignSystem.Colors.surface)
            )
        }
    }

    private func statusBackgroundColor(isReady: Bool, isChecking: Bool) -> Color {
        if isReady { return DesignSystem.Colors.success.opacity(0.12) }
        if isChecking { return DesignSystem.Colors.hermesAureate.opacity(0.10) }
        return DesignSystem.Colors.surface
    }

    private var statusDotColor: Color {
        if isGatewayRunning { return DesignSystem.Colors.success }
        if isProbingGateway { return DesignSystem.Colors.hermesAureate }
        return DesignSystem.Colors.textMuted
    }

    private var statusText: String {
        if isGatewayRunning { return "Gateway is running" }
        if isProbingGateway || hermesRuntimeLauncher.isBusy { return "Checking Hermes…" }
        if probeAttempts > 0 { return "Not reachable yet" }
        return "Waiting for gateway"
    }

    // MARK: - Actions

    private func completeHermesSetup() {
        var backends = Set(settingsManager.enabledChatBackends)
        backends.insert(.hermes)
        settingsManager.setEnabledChatBackends(ChatBackendID.allCases.filter { backends.contains($0) })
        chatController?.setChatBackend(.hermes)
        settingsManager.chatBackendOnboardingCompleted = true
        settingsManager.hermesSetupWizardCompleted = true
        installHermesSkillIfNeeded()
        onDismiss()
    }

    private func checkCLI() {
        isCheckingCLI = true
        hermesCLIInstalled = nil
        hermesCLIPath = nil
        Task {
            // Use CLIBridge's static resolution which searches PATH + common directories
            let env = ProcessInfo.processInfo.environment
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let dirs = CLIBridge.baseExecutableSearchDirectories(environment: env, homeDirectory: home)
                + CLIBridge.userManagedExecutableSearchDirectories(homeDirectory: home)
            if let path = CLIBridge.resolveExecutable(named: "hermes", searchDirectories: dirs) {
                hermesCLIInstalled = true
                hermesCLIPath = path
            } else if let path = CLIBridge.resolveExecutableFromLoginShell(
                named: "hermes",
                environment: env,
                fileManager: .default
            ) {
                hermesCLIInstalled = true
                hermesCLIPath = path
            } else {
                hermesCLIInstalled = false
            }
            isCheckingCLI = false
        }
    }

    private func checkConfig() {
        isCheckingConfig = true
        envFileExists = nil
        apiServerEnabled = nil
        hasAPIServerKey = nil
        Task {
            let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
            let hermesDir = "\(homeDir)/.hermes"
            let envPath = "\(hermesDir)/.env"

            let fm = FileManager.default
            if fm.fileExists(atPath: envPath),
               let content = try? String(contentsOfFile: envPath, encoding: .utf8) {
                envFileExists = true
                apiServerEnabled = content.contains("API_SERVER_ENABLED=true")
                hasAPIServerKey = content.contains("API_SERVER_KEY=")
                    && content.split(separator: "\n").contains(where: { line in
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("API_SERVER_KEY=") else { return false }
                        let value = trimmed.dropFirst("API_SERVER_KEY=".count)
                        return !value.isEmpty
                            && value != "\"\""
                            && value != "''"
                    })
            } else {
                envFileExists = false
                apiServerEnabled = false
                hasAPIServerKey = false
            }

            // Pre-fill bearer token from settings
            if !settingsManager.hermesBearerToken.isEmpty {
                bearerTokenInput = settingsManager.hermesBearerToken
            }

            isCheckingConfig = false
        }
    }

    private func writeEnvFile() {
        Task {
            let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
            let hermesDir = "\(homeDir)/.hermes"
            let envPath = "\(hermesDir)/.env"

            let fm = FileManager.default
            try? fm.createDirectory(atPath: hermesDir, withIntermediateDirectories: true)

            var content = ""
            if fm.fileExists(atPath: envPath),
               let existing = try? String(contentsOfFile: envPath, encoding: .utf8) {
                content = existing
                // Remove existing API_SERVER_ENABLED line
                content = content.split(separator: "\n")
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("API_SERVER_ENABLED=") }
                    .joined(separator: "\n")
                if !content.isEmpty && !content.hasSuffix("\n") {
                    content += "\n"
                }
            }
            content += "API_SERVER_ENABLED=true\n"

            do {
                try content.write(toFile: envPath, atomically: true, encoding: .utf8)
                // Re-check after writing
                await MainActor.run {
                    checkConfig()
                }
            } catch {
                apiServerEnabled = false
            }
        }
    }

    private func startAutoProbe() {
        probeGateway()
        autoProbeTask?.cancel()
        autoProbeTask = Task {
            // Probe every 3 seconds for up to 30 attempts (90 seconds)
            for _ in 0..<30 {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                guard !isGatewayRunning else { return }
                await MainActor.run {
                    probeGateway()
                }
            }
        }
    }

    private func probeGateway() {
        isProbingGateway = true
        probeAttempts += 1
        Task {
            let token = bearerTokenInput.isEmpty ? settingsManager.hermesBearerToken : bearerTokenInput
            let baseURL = URL(string: settingsManager.hermesGatewayBaseURL)
                ?? URL(string: "http://127.0.0.1:8642")!
            let status = await hermesRuntimeLauncher.refreshStatus(baseURL: baseURL, bearerToken: token.isEmpty ? nil : token)
            await MainActor.run {
                isGatewayRunning = status.gatewayRunning
                gatewayModelName = status.modelName
                isProbingGateway = false
            }
        }
    }

    private func openHermesRuntime() {
        isProbingGateway = true
        probeAttempts += 1
        Task {
            let token = bearerTokenInput.isEmpty ? settingsManager.hermesBearerToken : bearerTokenInput
            let baseURL = URL(string: settingsManager.hermesGatewayBaseURL)
                ?? URL(string: "http://127.0.0.1:8642")!
            let status = await hermesRuntimeLauncher.openHermesAndGateway(baseURL: baseURL, bearerToken: token.isEmpty ? nil : token)
            await MainActor.run {
                isGatewayRunning = status.gatewayRunning
                gatewayModelName = status.modelName
                isProbingGateway = false
            }
        }
    }

    private func runVerification() {
        isVerifying = true
        verificationResponse = nil
        verificationError = nil

        Task {
            let bridge = CLIBridge()
            let systemPrompt = "You are a test assistant. Reply with exactly: \"Hermes is ready.\" Nothing else."
            let userMessage = "Hello. Reply with exactly: \"Hermes is ready.\" Nothing else."
            let token = bearerTokenInput.isEmpty ? settingsManager.hermesBearerToken : bearerTokenInput

            do {
                let baseURL = URL(string: settingsManager.hermesGatewayBaseURL)
                    ?? URL(string: "http://127.0.0.1:8642")!
                var response = ""
                for try await event in bridge.chatHermes(
                    baseURL: baseURL,
                    systemPrompt: systemPrompt,
                    history: [ChatMessageRecord(role: .user, content: userMessage)],
                    bearerToken: token.isEmpty ? nil : token
                ) {
                    if case .text(let chunk) = event {
                        response += chunk
                    }
                }

                await MainActor.run {
                    isVerifying = false
                    if response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        verificationError = "Hermes returned an empty response. The gateway might still be initializing \u{2014} try again in a moment."
                    } else {
                        verificationResponse = response.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300).description
                    }
                }
            } catch {
                await MainActor.run {
                    isVerifying = false
                    verificationError = error.localizedDescription
                }
            }
        }
    }

    /// Symlinks the burnbar-operator Hermes skill from the repo into ~/.hermes/skills/.
    /// The repo copy at tools/openburnbar-mcp/hermes-skill/SKILL.md is the source of truth.
    private func installHermesSkillIfNeeded() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let hermesDir = "\(home)/.hermes"
        let skillDir = "\(hermesDir)/skills/software-development/burnbar-operator"
        let target = "\(skillDir)/SKILL.md"

        // Only install if ~/.hermes exists (Hermes has been set up)
        guard fm.fileExists(atPath: hermesDir) else { return }

        // Find the repo SKILL.md — check a few common locations relative to the app bundle
        let candidates: [String] = [
            // Development build: repo is next to the built app
            "\(home)/Documents/Windsurf/BurnBar/tools/openburnbar-mcp/hermes-skill/SKILL.md",
            // Check next to the running binary (for dev builds)
            Bundle.main.bundleURL.deletingLastPathComponent()
                .appendingPathComponent("tools/openburnbar-mcp/hermes-skill/SKILL.md")
                .path,
        ]

        guard let repoSkill = candidates.first(where: { fm.fileExists(atPath: $0) }) else { return }

        try? fm.createDirectory(atPath: skillDir, withIntermediateDirectories: true)

        // Remove existing symlink or stale file
        if fm.fileExists(atPath: target) || fm.fileExists(atPath: target) {
            try? fm.removeItem(atPath: target)
        }

        try? fm.createSymbolicLink(atPath: target, withDestinationPath: repoSkill)
    }
}

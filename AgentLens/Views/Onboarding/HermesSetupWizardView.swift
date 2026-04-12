import SwiftUI

// MARK: - Wizard Steps

enum HermesSetupStep: Int, CaseIterable {
    case welcome
    case install
    case configure
    case start
    case verify
    case done

    var progressFraction: Double {
        Double(rawValue) / Double(Self.allCases.count - 1)
    }

    var stepLabel: String {
        switch self {
        case .welcome: return "Welcome"
        case .install: return "Install"
        case .configure: return "Configure"
        case .start: return "Start"
        case .verify: return "Verify"
        case .done: return "Done"
        }
    }
}

// MARK: - Main Wizard View

struct HermesSetupWizardView: View {
    let settingsManager: SettingsManager
    let chatController: ChatSessionController?
    let onDismiss: () -> Void

    @Environment(\.openURL) private var openURL

    @State private var currentStep: HermesSetupStep = .welcome
    @State private var navigationDirection: Edge = .trailing

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
                    if currentStep != .welcome {
                        navigateBack()
                    } else {
                        onDismiss()
                    }
                } label: {
                    Image(systemName: currentStep == .welcome ? "xmark" : "chevron.left")
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
                case .welcome:
                    hermesWelcomeStep
                case .install:
                    hermesInstallStep
                case .configure:
                    hermesConfigureStep
                case .start:
                    hermesStartStep
                case .verify:
                    hermesVerifyStep
                case .done:
                    hermesDoneStep
                }
            }
            .padding(DesignSystem.Spacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(
                insertion: .move(edge: navigationDirection).combined(with: .opacity),
                removal: .move(edge: navigationDirection == .trailing ? .leading : .trailing).combined(with: .opacity)
            ))
        }
        .frame(width: 520, height: 580)
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

    // MARK: - Step 1: Welcome

    private var hermesWelcomeStep: some View {
        VStack(spacing: DesignSystem.Spacing.xl) {
            Spacer()

            // Hermes logo
            Image("HermesLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 88 * 0.2237, style: .continuous))

            VStack(spacing: DesignSystem.Spacing.sm) {
                Text("Meet Hermes")
                    .font(DesignSystem.Typography.display)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("Your local AI companion with full context on your coding sessions, token usage, and workflow patterns.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
            }

            // Feature highlights
            VStack(spacing: DesignSystem.Spacing.sm) {
                featureRow(icon: "bubble.left.and.text.bubble.right", text: "Multi-turn conversation with memory")
                featureRow(icon: "magnifyingglass", text: "Searches your indexed session logs")
                featureRow(icon: "chart.line.uptrend.xyaxis", text: "Analyzes spend patterns and burn rate")
                featureRow(icon: "lock.shield", text: "Runs entirely on your Mac \u{2014} nothing leaves")
            }
            .padding(.vertical, DesignSystem.Spacing.md)

            Spacer()

            Button {
                navigateForward()
            } label: {
                Text("Get Started")
                    .font(DesignSystem.Typography.body)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DesignSystem.Spacing.sm)
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignSystem.Colors.hermesAureate)
        }
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DesignSystem.Colors.hermesMercury)
                .frame(width: 20)

            Text(text)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DesignSystem.Spacing.md)
    }

    // MARK: - Step 2: Install

    private var hermesInstallStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Install Hermes CLI")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("Hermes runs as a local gateway. First, let's make sure the CLI is installed.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if isCheckingCLI {
                HStack(spacing: DesignSystem.Spacing.md) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking for hermes CLI...")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
            } else if let installed = hermesCLIInstalled, installed {
                // Already installed
                GlassCard {
                    VStack(spacing: DesignSystem.Spacing.md) {
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(DesignSystem.Colors.success)
                            Text("Hermes CLI found")
                                .font(DesignSystem.Typography.body)
                                .fontWeight(.semibold)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                        }

                        if let path = hermesCLIPath {
                            HStack(spacing: DesignSystem.Spacing.sm) {
                                Text(path)
                                    .font(DesignSystem.Typography.monoSmall)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                                    .textSelection(.enabled)
                            }
                            .padding(DesignSystem.Spacing.sm)
                            .background(
                                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                    .fill(DesignSystem.Colors.surface)
                            )
                        }

                        Button("Continue to Configuration") {
                            navigateForward()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(DesignSystem.Colors.hermesAureate)
                    }
                    .padding(DesignSystem.Spacing.lg)
                }
            } else {
                // Not installed
                GlassCard {
                    VStack(spacing: DesignSystem.Spacing.lg) {
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(DesignSystem.Colors.warning)
                            Text("Hermes CLI not found")
                                .font(DesignSystem.Typography.body)
                                .fontWeight(.semibold)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                        }

                        Text("Install Hermes, then come back to this wizard.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)

                        // Install command
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                            Text("Install command")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)

                            HStack {
                                Text("npm install -g @hermesai/cli")
                                    .font(DesignSystem.Typography.monoSmall)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                                Spacer()
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString("npm install -g @hermesai/cli", forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 11))
                                        .foregroundStyle(DesignSystem.Colors.textMuted)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(DesignSystem.Spacing.sm)
                            .background(
                                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                    .fill(DesignSystem.Colors.surface)
                            )
                        }

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
                            .font(DesignSystem.Typography.caption)

                            Button("Re-check") {
                                checkCLI()
                            }
                            .buttonStyle(.bordered)
                            .font(DesignSystem.Typography.caption)
                        }
                    }
                    .padding(DesignSystem.Spacing.lg)
                }
            }

            Spacer()
        }
        .onAppear {
            checkCLI()
        }
    }

    // MARK: - Step 3: Configure

    private var hermesConfigureStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Configure the gateway")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("Hermes needs an env file to enable the API server. Let's set that up.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if isCheckingConfig {
                HStack(spacing: DesignSystem.Spacing.md) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking configuration...")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
            } else {
                GlassCard {
                    VStack(spacing: DesignSystem.Spacing.lg) {
                        // Config file path
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                            Text("Configuration file")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)

                            HStack {
                                Text("~/.hermes/.env")
                                    .font(DesignSystem.Typography.monoSmall)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                                Spacer()
                                Button {
                                    HermesDataFolder.revealInFinder()
                                } label: {
                                    Image(systemName: "folder")
                                        .font(.system(size: 11))
                                        .foregroundStyle(DesignSystem.Colors.textMuted)
                                }
                                .buttonStyle(.plain)
                                .help("Reveal in Finder")
                            }
                            .padding(DesignSystem.Spacing.sm)
                            .background(
                                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                    .fill(DesignSystem.Colors.surface)
                            )
                        }

                        // API_SERVER_ENABLED status
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            if let enabled = apiServerEnabled {
                                Image(systemName: enabled ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(enabled ? DesignSystem.Colors.success : DesignSystem.Colors.error)
                                Text(enabled ? "API_SERVER_ENABLED is set" : "API_SERVER_ENABLED is not set")
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                            } else {
                                Image(systemName: "dash.circle")
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                                Text("Could not read .env file")
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                            }
                        }

                        // One-click fix
                        if apiServerEnabled == false || envFileExists == false {
                            Button {
                                writeEnvFile()
                            } label: {
                                Label("Enable API Server", systemImage: "wrench.and.screwdriver")
                            }
                            .buttonStyle(.bordered)
                            .tint(DesignSystem.Colors.hermesAureate)
                            .font(DesignSystem.Typography.caption)
                        }

                        // Optional API key
                        if let hasKey = hasAPIServerKey, hasKey {
                            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                                Text("API key detected")
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)

                                Text("You have API_SERVER_KEY set. Paste the same value below so OpenBurnBar can connect.")
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                                    .fixedSize(horizontal: false, vertical: true)

                                SecureField("API_SERVER_KEY value", text: $bearerTokenInput)
                                    .textFieldStyle(.roundedBorder)
                                    .font(DesignSystem.Typography.monoSmall)
                            }
                        }

                        // Continue
                        if apiServerEnabled == true {
                            Button("Start the Gateway") {
                                // Save bearer token if entered
                                if !bearerTokenInput.isEmpty {
                                    settingsManager.hermesBearerToken = bearerTokenInput
                                }
                                navigateForward()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(DesignSystem.Colors.hermesAureate)
                        }
                    }
                    .padding(DesignSystem.Spacing.lg)
                }
            }

            Spacer()
        }
        .onAppear {
            checkConfig()
        }
    }

    // MARK: - Step 4: Start Gateway

    private var hermesStartStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Start the Hermes gateway")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("The gateway serves Hermes as an API on port 8642. Open a Terminal and run the command below, then wait for the status to turn green.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            GlassCard {
                VStack(spacing: DesignSystem.Spacing.lg) {
                    // Command
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text("Run in Terminal")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)

                        HStack {
                            Text("hermes gateway run")
                                .font(DesignSystem.Typography.monoSmall)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("hermes gateway run", forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 11))
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(DesignSystem.Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                .fill(DesignSystem.Colors.surface)
                        )
                    }

                    // Live status
                    HStack(spacing: DesignSystem.Spacing.md) {
                        // Animated status dot
                        ZStack {
                            Circle()
                                .fill(statusDotColor)
                                .frame(width: 12, height: 12)

                            if isProbingGateway {
                                Circle()
                                    .stroke(statusDotColor.opacity(0.4), lineWidth: 2)
                                    .frame(width: 20, height: 20)
                                    .scaleEffect(probePulseScale)
                            }
                        }
                        .animation(DesignSystem.Animation.standard, value: isGatewayRunning)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(statusText)
                                .font(DesignSystem.Typography.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(statusDotColor)

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

                    if !isGatewayRunning && probeAttempts > 2 {
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            Image(systemName: "lightbulb.max")
                                .font(.system(size: 11))
                                .foregroundStyle(DesignSystem.Colors.hermesAureate)
                            Text("Make sure you ran the command and the gateway says it's listening on port 8642. This check retries automatically.")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(DesignSystem.Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                .fill(DesignSystem.Colors.hermesAureate.opacity(0.08))
                        )
                    }
                }
                .padding(DesignSystem.Spacing.lg)
            }

            if isGatewayRunning {
                Button("Verify Connection") {
                    navigateForward()
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.hermesAureate)
                .frame(maxWidth: .infinity)
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

    private var statusDotColor: Color {
        if isGatewayRunning { return DesignSystem.Colors.success }
        if isProbingGateway { return DesignSystem.Colors.hermesAureate }
        return DesignSystem.Colors.textMuted
    }

    private var statusText: String {
        if isGatewayRunning { return "Gateway is running" }
        if isProbingGateway { return "Probing localhost:8642\u{2026}" }
        if probeAttempts > 0 { return "Not reachable yet" }
        return "Waiting for gateway"
    }

    // MARK: - Step 5: Verify

    private var hermesVerifyStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Verify Hermes works")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("Let's send a test message to confirm everything is wired up.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if isVerifying {
                GlassCard {
                    VStack(spacing: DesignSystem.Spacing.lg) {
                        HermesThinkingView()
                            .frame(height: 32)

                        Text("Sending test message to Hermes...")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                    .padding(DesignSystem.Spacing.lg)
                    .frame(maxWidth: .infinity)
                }
            } else if let response = verificationResponse {
                GlassCard {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(DesignSystem.Colors.success)
                            Text("Hermes responded")
                                .font(DesignSystem.Typography.body)
                                .fontWeight(.semibold)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                        }

                        // Response bubble
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            Text("\u{263F}")
                                .font(.system(size: 14))
                                .foregroundStyle(DesignSystem.Colors.hermesAureate)
                            Text(response)
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(DesignSystem.Spacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                                .strokeBorder(DesignSystem.Colors.mercuryGradient, lineWidth: 1)
                        )
                        .background(
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                                .fill(DesignSystem.Colors.surfaceElevated)
                        )

                        Button("Continue") {
                            navigateForward()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(DesignSystem.Colors.hermesAureate)
                        .frame(maxWidth: .infinity)
                    }
                    .padding(DesignSystem.Spacing.lg)
                }
            } else if let error = verificationError {
                GlassCard {
                    VStack(spacing: DesignSystem.Spacing.md) {
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(DesignSystem.Colors.error)
                            Text("Verification failed")
                                .font(DesignSystem.Typography.body)
                                .fontWeight(.semibold)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                        }

                        Text(error)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: DesignSystem.Spacing.sm) {
                            Button("Go back and re-check gateway") {
                                verificationError = nil
                                navigateBack()
                            }
                            .buttonStyle(.bordered)
                            .font(DesignSystem.Typography.caption)

                            Button("Try again") {
                                verificationError = nil
                                runVerification()
                            }
                            .buttonStyle(.bordered)
                            .font(DesignSystem.Typography.caption)
                        }
                    }
                    .padding(DesignSystem.Spacing.lg)
                }
            } else {
                // Not yet verified - show the test prompt
                GlassCard {
                    VStack(spacing: DesignSystem.Spacing.lg) {
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            Text("\u{263F}")
                                .font(.system(size: 14))
                                .foregroundStyle(DesignSystem.Colors.hermesAureate)
                            Text("Say hello to Hermes")
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        }

                        // Preview of the test message
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

                        Button("Send Test Message") {
                            runVerification()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(DesignSystem.Colors.hermesAureate)
                        .frame(maxWidth: .infinity)
                    }
                    .padding(DesignSystem.Spacing.lg)
                }
            }

            Spacer()
        }
    }

    // MARK: - Step 6: Done

    private var hermesDoneStep: some View {
        VStack(spacing: DesignSystem.Spacing.xl) {
            Spacer()

            // Animated success
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                DesignSystem.Colors.success.opacity(0.15),
                                DesignSystem.Colors.success.opacity(0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 100, height: 100)

                Text("\u{263F}")
                    .font(.system(size: 44, weight: .light, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.mercuryGradient)
            }

            VStack(spacing: DesignSystem.Spacing.sm) {
                Text("Hermes is ready")
                    .font(DesignSystem.Typography.display)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("Your local AI companion is running and connected. Start chatting from the dashboard or menu bar.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
            }

            // Quick tips
            VStack(spacing: DesignSystem.Spacing.sm) {
                tipRow(text: "Open the dashboard and click the chat panel to start a conversation")
                tipRow(text: "Hermes has full context on your sessions and usage data")
                tipRow(text: "You can always reconfigure in Settings \u{2192} Chat engines")
            }
            .padding(.vertical, DesignSystem.Spacing.md)

            Spacer()

            Button {
                // Enable Hermes backend
                var backends = Set(settingsManager.enabledChatBackends)
                backends.insert(.hermes)
                settingsManager.setEnabledChatBackends(ChatBackendID.allCases.filter { backends.contains($0) })
                chatController?.setChatBackend(.hermes)
                settingsManager.chatBackendOnboardingCompleted = true

                onDismiss()
            } label: {
                Text("Start Using Hermes")
                    .font(DesignSystem.Typography.body)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DesignSystem.Spacing.sm)
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignSystem.Colors.hermesAureate)
        }
    }

    private func tipRow(text: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 10))
                .foregroundStyle(DesignSystem.Colors.success)
            Text(text)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DesignSystem.Spacing.md)
    }

    // MARK: - Actions

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
            let bridge = CLIBridge()
            let token = bearerTokenInput.isEmpty ? settingsManager.hermesBearerToken : bearerTokenInput
            await bridge.probeHermesAvailability(bearerToken: token.isEmpty ? nil : token)
            await MainActor.run {
                isGatewayRunning = bridge.hermesAvailable
                gatewayModelName = bridge.hermesModelName
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
                var response = ""
                for try await event in bridge.chatHermes(
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
}

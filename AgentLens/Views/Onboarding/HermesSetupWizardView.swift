import SwiftUI

// MARK: - Main Wizard View

/// The Prepare Hermes wizard.
///
/// Redesigned for the editorial Observatory voice and hardened with a
/// state-driven "Make Gateway Reachable" action. All mutable state lives in
/// `HermesSetupWizardController`; this view is pure presentation and never
/// probes, launches, or writes files directly.
///
/// The three steps:
///   1. **Prepare** — resolve the Hermes CLI and enable the local API server.
///   2. **Connect** — make the gateway reachable, then confirm it responds.
///      The hero card renders one `GatewayReachabilityState` at a time, each
///      with its own copy and a single primary action that resolves it.
///   3. **Chat** — send one test prompt; if Hermes answers, setup completes.
struct HermesSetupWizardView: View {
    let settingsManager: SettingsManager
    let chatController: ChatSessionController?
    let inventoryImportService: HermesInventoryImportService?
    let onDismiss: () -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var controller: HermesSetupWizardController

    init(
        settingsManager: SettingsManager,
        chatController: ChatSessionController?,
        inventoryImportService: HermesInventoryImportService?,
        onDismiss: @escaping () -> Void
    ) {
        self.settingsManager = settingsManager
        self.chatController = chatController
        self.inventoryImportService = inventoryImportService
        self.onDismiss = onDismiss
        // Build the live dependencies once, capturing settingsManager weakly
        // inside the closures (see makeLive).
        let deps = HermesSetupWizardDependencies.makeLive(settingsManager: settingsManager)
        _controller = State(initialValue: HermesSetupWizardController(dependencies: deps))
    }

    var body: some View {
        VStack(spacing: 0) {
            wizardHeader
            wizardProgressBar
            stepContent
        }
        .frame(width: 560, height: 620)
        .background(DesignSystem.Colors.background)
        .openBurnBarPreferredColorScheme(settingsManager.preferredSwiftUIColorScheme)
    }

    // MARK: Header

    private var wizardHeader: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Button {
                if controller.currentStep != .prepare {
                    controller.navigateBack()
                } else {
                    onDismiss()
                }
            } label: {
                Image(systemName: controller.currentStep == .prepare ? "xmark" : "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(controller.currentStep == .prepare ? "Close" : "Back")

            stepDots

            Spacer()

            Text(controller.currentStep.stepLabel)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.top, DesignSystem.Spacing.md)
        .padding(.bottom, DesignSystem.Spacing.sm)
    }

    private var stepDots: some View {
        HStack(spacing: DesignSystem.Spacing.xxs) {
            ForEach(HermesSetupStep.allCases, id: \.rawValue) { step in
                Capsule()
                    .fill(stepColor(for: step))
                    .frame(width: step == controller.currentStep ? 20 : 6, height: 6)
                    .animation(reduceMotion ? nil : DesignSystem.Animation.snappy, value: controller.currentStep)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(controller.currentStep.rawValue + 1) of \(HermesSetupStep.allCases.count)")
    }

    private func stepColor(for step: HermesSetupStep) -> Color {
        if step.rawValue < controller.currentStep.rawValue {
            return DesignSystem.Colors.success
        } else if step == controller.currentStep {
            return DesignSystem.Colors.hermesAureate
        } else {
            return DesignSystem.Colors.border
        }
    }

    // MARK: Progress bar

    private var wizardProgressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(DesignSystem.Colors.borderSubtle)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(DesignSystem.Colors.mercuryGradient)
                    .frame(width: geo.size.width * controller.currentStep.progressFraction)
                    .animation(reduceMotion ? nil : DesignSystem.Animation.gentle, value: controller.currentStep)
            }
        }
        .frame(height: 2)
    }

    // MARK: Step content

    @ViewBuilder
    private var stepContent: some View {
        Group {
            switch controller.currentStep {
            case .prepare: prepareStep
            case .connect: connectStep
            case .chat: chatStep
            }
        }
        .padding(DesignSystem.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.asymmetric(
            insertion: .move(edge: controller.navigationDirection).combined(with: .opacity),
            removal: .move(edge: controller.navigationDirection == .trailing ? .leading : .trailing).combined(with: .opacity)
        ))
    }

    // MARK: Step 1 — Prepare

    private var prepareStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            stepHeader(number: "1", title: "Prepare Hermes", subtitle: "Install the CLI once and let OpenBurnBar turn on the local API server.")

            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    sectionLabel("PREREQUISITES")

                    statusRow(
                        icon: "terminal",
                        title: "Hermes CLI",
                        detail: controller.hermesCLIPath ?? "Needed to run the gateway on this Mac.",
                        isReady: controller.hermesCLIInstalled == true,
                        isChecking: controller.isCheckingCLI
                    )

                    if controller.hermesCLIInstalled == false {
                        commandCopyRow(label: "Install command", command: "npm install -g @hermesai/cli")
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            Button {
                                openTerminal()
                            } label: {
                                Label("Open Terminal", systemImage: "terminal")
                            }
                            .buttonStyle(.bordered)

                            Button("Re-check") { controller.checkCLI() }
                            .buttonStyle(.bordered)
                        }
                        .controlSize(.small)
                        .font(DesignSystem.Typography.caption)
                    }

                    Divider().background(DesignSystem.Colors.border)

                    statusRow(
                        icon: "switch.2",
                        title: "API server",
                        detail: controller.apiServerEnabled == true
                            ? "~/.hermes/.env includes API_SERVER_ENABLED=true"
                            : "OpenBurnBar can add API_SERVER_ENABLED=true for you.",
                        isReady: controller.apiServerEnabled == true,
                        isChecking: controller.isCheckingConfig
                    )

                    if controller.apiServerEnabled != true {
                        Button {
                            controller.writeEnvFile()
                        } label: {
                            Label("Enable API Server", systemImage: "wrench.and.screwdriver")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(DesignSystem.Colors.hermesAureate)
                        .font(DesignSystem.Typography.caption)
                    }

                    stepFooter(
                        backLabel: nil,
                        continueLabel: "Continue",
                        continueDisabled: !controller.canContinueFromPrepare,
                        continueAction: { controller.navigateForward() }
                    )
                }
                .padding(DesignSystem.Spacing.lg)
            }

            Spacer()
        }
        .onAppear {
            controller.checkCLI()
            controller.checkConfig()
        }
    }

    // MARK: Step 2 — Connect

    private var connectStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            stepHeader(
                number: "2",
                title: "Connect the gateway",
                subtitle: "Run Hermes locally, then optionally make this Mac the relay host for iPhone and iPad."
            )

            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    reachabilityHero

                    Divider().background(DesignSystem.Colors.border)

                    relayToggles

                    stepFooter(
                        backLabel: "Back",
                        continueLabel: "Continue",
                        continueDisabled: !controller.canContinueFromConnect,
                        backAction: { controller.navigateBack() },
                        continueAction: { controller.navigateForward() }
                    )
                }
                .padding(DesignSystem.Spacing.lg)
            }

            Spacer()
        }
        .onAppear { controller.startAutoProbe() }
        .onDisappear { controller.stopAutoProbe() }
    }

    /// The editorial Observatory status hero. One `GatewayReachabilityState`
    /// rendered at a time, each with eyebrow + headline + detail + a single
    /// primary action. This is the heart of the redesign: the old wizard
    /// looped "not reachable yet" with no remediation; this hero always shows
    /// the one button that fixes the current state.
    private var reachabilityHero: some View {
        let state = controller.reachability
        let accent = state.accent

        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            // Eyebrow + status dot row
            HStack(spacing: DesignSystem.Spacing.sm) {
                statusDot(accent: accent, pulsing: controller.isProbingGateway || controller.isMakingReachable)
                Text(state.eyebrow)
                    .font(DesignSystem.Typography.tiny)
                    .tracking(0.8)
                    .foregroundStyle(accent.color)
                Spacer()
                if let model = controller.gatewayModelName, state == .gatewayRunning {
                    Text("model: \(model)")
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }

            // Headline
            Text(state.headline)
                .font(DesignSystem.Typography.title)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            // Detail
            Text(state.detail)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // Mercury hairline — the editorial Observatory hero accent
            mercuryHairline

            // Primary action + secondary controls
            reachabilityActions(for: state)

            if let error = controller.makeReachableError, state != .gatewayRunning {
                Callout(
                    type: .error,
                    title: "Could not start the gateway",
                    content: error
                )
            }

            if !controller.lastGatewayMessage.isEmpty, state != .gatewayRunning {
                Text(controller.lastGatewayMessage)
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var mercuryHairline: some View {
        Rectangle()
            .fill(DesignSystem.Colors.mercuryGradient)
            .frame(height: 1)
            .opacity(0.7)
    }

    @ViewBuilder
    private func reachabilityActions(for state: GatewayReachabilityState) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            // The single primary action for the current state.
            if let label = state.primaryActionLabel {
                Button {
                    primaryAction(for: state)
                } label: {
                    Label(label, systemImage: primaryActionIcon(for: state))
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.hermesAureate)
                .disabled(controller.isMakingReachable)
                .controlSize(.small)
                .font(DesignSystem.Typography.caption)
            }

            Button {
                controller.probeGateway()
            } label: {
                Label("Check Health", systemImage: "waveform.path.ecg")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(DesignSystem.Typography.caption)
            .disabled(controller.isProbingGateway || controller.isMakingReachable)

            Spacer()
        }
    }

    private func primaryAction(for state: GatewayReachabilityState) {
        switch state {
        case .apiServerDisabled:
            controller.writeEnvFile()
            // After enabling, immediately try to make the gateway reachable so
            // the user doesn't have to tap twice.
            controller.makeGatewayReachable()
        case .unknown, .dashboardOnly, .unreachable:
            controller.makeGatewayReachable()
        case .cliMissing, .gatewayRunning:
            break
        }
    }

    private func primaryActionIcon(for state: GatewayReachabilityState) -> String {
        switch state {
        case .apiServerDisabled: return "wrench.and.screwdriver"
        case .unknown, .dashboardOnly, .unreachable: return "play.circle.fill"
        case .cliMissing, .gatewayRunning: return "checkmark.circle"
        }
    }

    private func statusDot(accent: GatewayReachabilityAccent, pulsing: Bool) -> some View {
        ZStack {
            Circle()
                .fill(accent.color)
                .frame(width: 10, height: 10)
            if pulsing {
                Circle()
                    .stroke(accent.color.opacity(0.4), lineWidth: 2)
                    .frame(width: 18, height: 18)
                    .scaleEffect(pulsing ? 1.0 : 0.6)
                    .opacity(pulsing ? 0.0 : 0.8)
                    .animation(reduceMotion ? nil : DesignSystem.Animation.mercuryPulse, value: pulsing)
            }
        }
        .frame(width: 18, height: 18)
    }

    private var relayToggles: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            sectionLabel("OPTIONS")

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
        }
    }

    // MARK: Step 3 — Chat

    private var chatStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            stepHeader(
                number: "3",
                title: "Start chatting",
                subtitle: "Send one tiny test prompt. If Hermes answers, OpenBurnBar will enable it as a chat engine."
            )

            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    verificationBody

                    stepFooter(
                        backLabel: "Back",
                        continueLabel: controller.verificationResponse == nil ? "Send Test Message" : "Start Using Hermes",
                        continueDisabled: controller.verificationResponse == nil ? !controller.canRetryVerification : false,
                        backAction: { controller.navigateBack() },
                        continueAction: {
                            if controller.verificationResponse == nil {
                                controller.runVerification()
                            } else {
                                controller.completeHermesSetup(
                                    settingsManager: settingsManager,
                                    chatController: chatController
                                )
                                onDismiss()
                            }
                        }
                    )
                }
                .padding(DesignSystem.Spacing.lg)
            }

            if let inventoryImportService {
                HermesInventoryImportSetupCard(service: inventoryImportService)
            }

            Spacer()
        }
    }

    @ViewBuilder
    private var verificationBody: some View {
        if controller.isVerifying {
            HStack(spacing: DesignSystem.Spacing.md) {
                HermesThinkingView()
                    .frame(width: 48, height: 28)
                Text("Asking Hermes to confirm it is ready…")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        } else if let response = controller.verificationResponse {
            statusRow(
                icon: "checkmark.seal.fill",
                title: "Hermes answered",
                detail: response,
                isReady: true,
                isChecking: false
            )
        } else if let error = controller.verificationError {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                statusRow(
                    icon: "exclamationmark.triangle.fill",
                    title: "Test failed",
                    detail: error,
                    isReady: false,
                    isChecking: false
                )
                if !controller.isGatewayRunning {
                    Callout(
                        type: .warning,
                        title: "Gateway went away",
                        content: "The gateway stopped responding before the test finished. Go back to Connect and make it reachable again."
                    )
                }
            }
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
    }

    // MARK: Shared step primitives

    private func stepHeader(number: String, title: String, subtitle: String) -> some View {
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

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(DesignSystem.Typography.tiny)
            .tracking(0.6)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
    }

    private func statusRow(
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
                    ProgressView().controlSize(.small)
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
        .accessibilityElement(children: .combine)
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

    private func stepFooter(
        backLabel: String?,
        continueLabel: String,
        continueDisabled: Bool,
        backAction: (() -> Void)? = nil,
        continueAction: @escaping () -> Void
    ) -> some View {
        HStack {
            if let backLabel {
                Button(backLabel) {
                    backAction?()
                }
                .buttonStyle(.plain)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            }

            Spacer()

            Button {
                continueAction()
            } label: {
                Text(continueLabel)
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignSystem.Colors.hermesAureate)
            .disabled(continueDisabled)
        }
    }

    // MARK: Terminal helper

    private func openTerminal() {
        if let url = URL(string: "terminal://") {
            openURL(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
        }
    }
}

// MARK: - HermesInventoryImportSetupCard (unchanged, preserved)

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
        case .scanning, .importing: return true
        default: return false
        }
    }

    private var statusColor: Color {
        switch service.phase {
        case .failed: return DesignSystem.Colors.error
        case .complete: return DesignSystem.Colors.success
        default: return DesignSystem.Colors.textSecondary
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

// MARK: - Callout (lightweight editorial Observatory callout)

/// A small mercury-stroked callout used for inline error/warning messages
/// inside the wizard. Mirrors the `EmptyEvidenceCallout` pattern from the
/// Project Memory editorial sheets without taking a dependency on that type.
private struct Callout: View {
    enum Kind { case error, warning, info }
    let type: Kind
    let title: String
    let content: String

    var body: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: iconName)
                .foregroundStyle(accent)
                .font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(content)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DesignSystem.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .fill(accent.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .strokeBorder(accent.opacity(0.3), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
    }

    private var iconName: String {
        switch type {
        case .error: return "exclamationmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private var accent: Color {
        switch type {
        case .error: return DesignSystem.Colors.error
        case .warning: return DesignSystem.Colors.warning
        case .info: return DesignSystem.Colors.hermesAureate
        }
    }
}

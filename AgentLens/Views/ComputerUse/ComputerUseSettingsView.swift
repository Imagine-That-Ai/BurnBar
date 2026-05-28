#if canImport(SwiftUI) && canImport(AppKit) && !DISTRIBUTION_MAS
import AppKit
import ApplicationServices
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import SwiftUI

// MARK: - Glass Card Container

struct SettingsGlassCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(18)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(DesignSystem.Colors.surface.opacity(colorScheme == .dark ? 0.35 : 0.65))
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(colorScheme == .dark ? 0.03 : 0.10),
                                    Color.clear,
                                    DesignSystem.Colors.ember.opacity(colorScheme == .dark ? 0.01 : 0.02)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }
            .clipShape(.rect(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.12 : 0.30),
                                DesignSystem.Colors.border.opacity(colorScheme == .dark ? 0.40 : 0.55),
                                DesignSystem.Colors.border.opacity(colorScheme == .dark ? 0.20 : 0.35)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
            )
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.15 : 0.04),
                radius: 8,
                x: 0,
                y: 3
            )
    }
}

// MARK: - Glass Button Component

struct SettingsGlassButton: View {
    enum Style {
        case prominent
        case regular
        case destructive
    }

    let title: String
    let icon: String
    var style: Style = .regular
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(foregroundStyle)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(backgroundFill)
                    if isHovered && isEnabled {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    }
                }
            }
            .clipShape(.rect(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(borderGradient, lineWidth: 0.75)
            )
            .scaleEffect(isHovered && isEnabled ? 1.02 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isHovered)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.45)
        .onHover { isHovered = $0 }
    }

    private var foregroundStyle: AnyShapeStyle {
        switch style {
        case .prominent:
            return AnyShapeStyle(Color.white)
        case .destructive:
            return AnyShapeStyle(Color.white)
        case .regular:
            return AnyShapeStyle(DesignSystem.Colors.textPrimary)
        }
    }

    private var backgroundFill: AnyShapeStyle {
        switch style {
        case .prominent:
            return AnyShapeStyle(DesignSystem.Colors.primaryGradient)
        case .destructive:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Color(hex: "FA5053"), Color(hex: "D43030")],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        case .regular:
            return AnyShapeStyle(.ultraThinMaterial)
        }
    }

    private var borderGradient: LinearGradient {
        switch style {
        case .prominent:
            return LinearGradient(
                colors: [Color.white.opacity(0.4), Color.white.opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .destructive:
            return LinearGradient(
                colors: [Color.white.opacity(0.3), Color.white.opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .regular:
            return LinearGradient(
                colors: [Color.white.opacity(0.18), DesignSystem.Colors.border.opacity(0.45)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

// MARK: - Computer Use Settings View

/// Settings surface for direct-download Computer Use.
struct ComputerUseSettingsView: View {
    private struct AuditOperationStatus: Equatable {
        var kind: Kind
        var message: String

        enum Kind: Equatable {
            case idle
            case running
            case succeeded
            case failed
        }
    }

    private enum Tab: String, CaseIterable, Identifiable {
        case setup
        case policy
        case forensics

        var id: String { rawValue }

        var title: String {
            switch self {
            case .setup: return "Setup"
            case .policy: return "Policy"
            case .forensics: return "Forensics"
            }
        }
    }

    @Environment(SettingsManager.self) private var settingsManager
    @StateObject private var panelModel = ComputerUseSessionPanelModel()
    @StateObject private var wizardModel = ComputerUseSetupWizardModel()
    #if canImport(AppKit) && !DISTRIBUTION_MAS
    @StateObject private var permissionsCoordinator = PermissionsOnboardingCoordinator()
    #endif
    @State private var accessibilityTrusted = AXIsProcessTrusted()
    @State private var showingSetupWizard = false
    @State private var showingPermissionsWizard = false
    @State private var auditSessionId = ""
    @State private var auditIncludeScreenshots = true
    @State private var auditAdvancedExpanded = false
    @State private var auditNotarizationOptIn = false
    @State private var auditStatus = AuditOperationStatus(
        kind: .idle,
        message: "Enter a session id to validate, export, or notarize its local audit chain."
    )
    @State private var selectedTab: Tab = .setup
    private let runtimeController: ComputerUseRuntimeController?

    init(runtimeController: ComputerUseRuntimeController? = nil) {
        self.runtimeController = runtimeController
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                heroStatusCard
                    .settingsAnchor(SettingsAnchor.computerUseReadiness)

                tabSwitcher

                tabContent
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(DesignSystem.Colors.background)
        .onAppear(perform: configureModels)
        .sheet(isPresented: $showingSetupWizard) {
            ComputerUseSetupWizard(
                model: wizardModel,
                onComplete: {
                    showingSetupWizard = false
                    refreshReadiness()
                },
                onCancel: {
                    showingSetupWizard = false
                    refreshReadiness()
                }
            )
        }
        #if canImport(AppKit) && !DISTRIBUTION_MAS
        .sheet(isPresented: $showingPermissionsWizard) {
            permissionsWizardSheet
        }
        #endif
    }

    #if canImport(AppKit) && !DISTRIBUTION_MAS
    private var permissionsWizardSheet: some View {
        VStack(spacing: 0) {
            OnboardingSystemPermissionsView(coordinator: permissionsCoordinator)
                .padding(24)
                .frame(width: 520, height: 540)
            Divider()
            HStack {
                Button("Reset deferrals") {
                    permissionsCoordinator.resetDeferrals()
                }
                .buttonStyle(.plain)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                Spacer()
                Button("Done") {
                    settingsManager.systemPermissionsDeferredKinds = permissionsCoordinator.deferredKinds()
                    settingsManager.systemPermissionsOnboardingCompleted = true
                    showingPermissionsWizard = false
                    refreshReadiness()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .background(DesignSystem.Colors.background)
    }
    #endif

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Computer Use")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            Text("Browser automation, Mac input, approvals, panic halt, and audit chain controls.")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
    }

    // MARK: - Hero status card

    private var heroStatusCard: some View {
        SettingsGlassCard {
            HStack(alignment: .center, spacing: 16) {
                heroStatusBadge

                VStack(alignment: .leading, spacing: 4) {
                    Text(heroStatusTitle)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(heroStatusSubtitle)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    SettingsGlassButton(title: "Run Setup", icon: "wand.and.stars", style: .prominent) {
                        showingSetupWizard = true
                    }
                    if runtimeController != nil {
                        SettingsGlassButton(title: "Start Session", icon: "play.circle") {
                            startSystemSession()
                        }
                    }
                    heroRefreshButton
                }
            }
        }
    }

    private var heroStatusBadge: some View {
        ZStack {
            Circle()
                .fill(heroStatusColor.opacity(0.14))
                .frame(width: 44, height: 44)
            Image(systemName: heroStatusIcon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(heroStatusColor)
        }
        .accessibilityHidden(true)
    }

    private var heroRefreshButton: some View {
        Button(action: refreshReadiness) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .frame(width: 30, height: 30)
                .background {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Circle()
                                .strokeBorder(DesignSystem.Colors.border.opacity(0.45), lineWidth: 0.75)
                        )
                }
        }
        .buttonStyle(.plain)
        .help("Refresh readiness")
        .accessibilityLabel("Refresh readiness")
    }

    private var heroStatusIcon: String {
        accessibilityTrusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
    }

    private var heroStatusColor: Color {
        accessibilityTrusted ? DesignSystem.Colors.success : DesignSystem.Colors.warning
    }

    private var heroStatusTitle: String {
        accessibilityTrusted ? "Computer Use is ready" : "Setup required"
    }

    private var heroStatusSubtitle: String {
        let trustWord = activePanelModel.liveTrustMode.rawValue.capitalized
        let denyCount = activePanelModel.scopeRules.filter { $0.effect == .deny }.count
        let denyLabel = denyCount == 1 ? "1 deny rule" : "\(denyCount) deny rules"
        let sessionPart: String
        if let started = activePanelModel.currentSessionStartedAt {
            sessionPart = "session active since \(heroTimeFormatter.string(from: started))"
        } else {
            sessionPart = "no active session"
        }
        return "\(trustWord) trust  ·  \(denyLabel)  ·  \(sessionPart)"
    }

    private let heroTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    // MARK: - Tab switcher

    private var tabSwitcher: some View {
        Picker("View", selection: $selectedTab) {
            ForEach(Tab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 360, alignment: .leading)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .setup:
            setupTab
        case .policy:
            policyTab
        case .forensics:
            forensicsTab
        }
    }

    private var activePanelModel: ComputerUseSessionPanelModel {
        runtimeController?.panelModel ?? panelModel
    }

    // MARK: - Setup tab

    private var setupTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            readinessSection
            setupActionsSection
        }
    }

    private var readinessSection: some View {
        SettingsGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("System Readiness", icon: "checklist", iconColor: DesignSystem.Colors.ember)

                Divider().opacity(0.22)

                VStack(spacing: 0) {
                    readinessRow(
                        icon: accessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                        iconColor: accessibilityTrusted ? DesignSystem.Colors.success : DesignSystem.Colors.warning,
                        title: "Accessibility permission",
                        detail: accessibilityTrusted
                            ? "Granted. OpenBurnBar can post approved CGEvents."
                            : "Not granted. System Computer Use cannot click or type until this is granted."
                    ) {
                        if !accessibilityTrusted {
                            SettingsGlassButton(title: "Open", icon: "lock.open") {
                                requestAccessibility()
                            }
                        }
                    }

                    readinessRowDivider

                    readinessRow(
                        icon: "checkmark.circle.fill",
                        iconColor: DesignSystem.Colors.success,
                        title: "Mac App Store build guard",
                        detail: "Path C is compiled out when DISTRIBUTION_MAS is set."
                    )

                    readinessRowDivider

                    readinessRow(
                        icon: "checkmark.circle.fill",
                        iconColor: DesignSystem.Colors.success,
                        title: "Phone control stream",
                        detail: "iroh host exposes a Computer Use dispatcher for active sessions."
                    )

                    readinessRowDivider

                    readinessRow(
                        icon: "checkmark.circle.fill",
                        iconColor: DesignSystem.Colors.success,
                        title: "Approval presenter",
                        detail: "Daemon approvals surface in an app-wide floating panel."
                    )
                }
            }
        }
    }

    private var setupActionsSection: some View {
        SettingsGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("Setup Actions", icon: "wand.and.stars", iconColor: DesignSystem.Colors.whimsy)

                Divider().opacity(0.22)

                VStack(spacing: 0) {
                    actionRow(
                        icon: "lock.shield",
                        iconColor: DesignSystem.Colors.amber,
                        title: "Mac permissions",
                        detail: "Re-run the full permissions onboarding flow.",
                        buttonTitle: "Re-run",
                        buttonIcon: "arrow.clockwise"
                    ) { showingPermissionsWizard = true }
                    .settingsAnchor(SettingsAnchor.computerUsePermissionsSetup)

                    readinessRowDivider

                    actionRow(
                        icon: "globe",
                        iconColor: DesignSystem.Colors.teal,
                        title: "Playwright runtime",
                        detail: "Installs the bundled Playwright bridge for browser automation.",
                        buttonTitle: "Install",
                        buttonIcon: "arrow.down.circle"
                    ) { runPlaywrightInstaller() }
                }
            }
        }
    }

    private var readinessRowDivider: some View {
        Divider()
            .opacity(0.16)
            .padding(.leading, 32)
    }

    private func readinessRow(
        icon: String,
        iconColor: Color,
        title: String,
        detail: String
    ) -> some View {
        readinessRow(icon: icon, iconColor: iconColor, title: title, detail: detail) {
            EmptyView()
        }
    }

    private func readinessRow<Trailing: View>(
        icon: String,
        iconColor: Color,
        title: String,
        detail: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 20, height: 20)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(detail)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            trailing()
        }
        .padding(.vertical, 10)
    }

    private func actionRow(
        icon: String,
        iconColor: Color,
        title: String,
        detail: String,
        buttonTitle: String,
        buttonIcon: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(detail)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            SettingsGlassButton(title: buttonTitle, icon: buttonIcon, isEnabled: isEnabled, action: action)
        }
        .padding(.vertical, 10)
    }

    // MARK: - Policy tab

    private var policyTab: some View {
        ComputerUseSessionPanel(model: activePanelModel)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Forensics tab

    private var forensicsTab: some View {
        SettingsGlassCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader(
                    "Forensics & Notarization",
                    icon: "checkmark.seal",
                    iconColor: DesignSystem.Colors.whimsy
                )

                Text("Validate the local hash chain, export a signed .tar.gz archive, or notarize the terminal chain head.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                Divider().opacity(0.22)

                sessionIdField

                HStack(spacing: 8) {
                    SettingsGlassButton(
                        title: "Validate Chain",
                        icon: "checkmark.seal",
                        isEnabled: !trimmedAuditSessionId.isEmpty && auditStatus.kind != .running
                    ) {
                        validateAuditChain()
                    }

                    SettingsGlassButton(
                        title: "Export Archive",
                        icon: "archivebox",
                        isEnabled: !trimmedAuditSessionId.isEmpty && auditStatus.kind != .running
                    ) {
                        exportAuditArchive()
                    }

                    Spacer(minLength: 12)

                    Toggle("Include screenshots", isOn: $auditIncludeScreenshots)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .font(DesignSystem.Typography.caption)
                }

                advancedNotarizationDisclosure

                Divider().opacity(0.18)

                statusRow(
                    icon: auditStatusIcon,
                    title: "Operation log",
                    detail: auditStatus.message,
                    color: auditStatusColor
                )
            }
        }
    }

    private var sessionIdField: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.viewfinder")
                .font(.system(size: 12))
                .foregroundStyle(DesignSystem.Colors.textMuted)
            TextField("Session id", text: $auditSessionId)
                .textFieldStyle(.plain)
                .font(DesignSystem.Typography.monoSmall)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.8))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 1)
                )
        }
    }

    private var advancedNotarizationDisclosure: some View {
        DisclosureGroup(isExpanded: $auditAdvancedExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Allow OpenTimestamps notarization for this session", isOn: $auditNotarizationOptIn)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(DesignSystem.Typography.caption)

                Text("Submits only the audit-chain root hash to OpenTimestamps and stores the returned .ots proof beside the local chain.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                SettingsGlassButton(
                    title: "Notarize via OTS",
                    icon: "clock.badge.checkmark",
                    isEnabled: !trimmedAuditSessionId.isEmpty
                        && auditStatus.kind != .running
                        && auditNotarizationOptIn
                ) {
                    notarizeAuditChain()
                }
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.5)
                    )
            }
            .padding(.top, 4)
        } label: {
            Label("Advanced notarization options", systemImage: "wrench.and.screwdriver")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
    }

    // MARK: - Shared helpers

    private func sectionHeader(_ title: String, icon: String, iconColor: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(iconColor)
            Text(title)
                .font(DesignSystem.Typography.headline)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
        }
    }

    private func statusRow(icon: String, title: String, detail: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.12))
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(detail)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineSpacing(2)
            }
        }
    }

    private func configureModels() {
        refreshReadiness()
        runtimeController?.refreshEntitlement()
        guard runtimeController == nil else { return }
        panelModel.scopeRules = ComputerUseDenyRegistry.builtInRules
        panelModel.setTrustMode = { mode in
            panelModel.liveTrustMode = mode
        }
        panelModel.addRule = { rule in
            panelModel.scopeRules.append(rule)
        }
        panelModel.panicHalt = {
            panelModel.recentAuditEntries.insert(
                HermesRealtimeRelayActionLogEntry(
                    entryIndex: panelModel.recentAuditEntries.count,
                    timestamp: Date(),
                    actionKind: "panic.user_halt",
                    summary: "Panic halt requested from Settings",
                    status: .panicHalted
                ),
                at: 0
            )
        }
        wizardModel.requestAccessibility = {
            requestAccessibility()
        }
        wizardModel.installPlaywright = {
            runPlaywrightInstaller()
        }
        wizardModel.runSampleAction = {
            runSetupSmoke()
        }
    }

    private var trimmedAuditSessionId: String {
        auditSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var auditStatusIcon: String {
        switch auditStatus.kind {
        case .idle:
            return "info.circle.fill"
        case .running:
            return "hourglass.badge.elipseloading"
        case .succeeded:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        }
    }

    private var auditStatusColor: Color {
        switch auditStatus.kind {
        case .idle:
            return DesignSystem.Colors.whimsy
        case .running:
            return DesignSystem.Colors.amber
        case .succeeded:
            return DesignSystem.Colors.success
        case .failed:
            return DesignSystem.Colors.error
        }
    }

    private func refreshReadiness() {
        accessibilityTrusted = AXIsProcessTrusted()
        wizardModel.accessibilityGranted = accessibilityTrusted
        wizardModel.playwrightReady = FileManager.default.fileExists(
            atPath: "OpenBurnBarDaemon/Resources/PlaywrightBridge/openburnbar-playwright-bridge.js"
        )
    }

    private func requestAccessibility() {
        _ = MacAccessibilityPermissionRequester.promptAndOpenSettings()
        refreshReadiness()
    }

    private func runPlaywrightInstaller() {
        guard let script = Bundle.main.path(forResource: "install-playwright", ofType: "sh") else {
            if let url = URL(string: "file://\(FileManager.default.currentDirectoryPath)/scripts/install-playwright.sh") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script]
        try? process.run()
    }

    private func startSystemSession() {
        guard let runtimeController else { return }
        Task { @MainActor in
            do {
                let response = try await runtimeController.startSystemSession(
                    trustMode: activePanelModel.liveTrustMode
                )
                auditSessionId = response.sessionId
                auditStatus = AuditOperationStatus(
                    kind: .succeeded,
                    message: "System session started. Audit head \(response.manifestHashHex.prefix(16))."
                )
            } catch {
                auditStatus = AuditOperationStatus(
                    kind: .failed,
                    message: "Could not start system session: \(error.localizedDescription)"
                )
            }
        }
    }

    private func runSetupSmoke() {
        wizardModel.sampleIsRunning = true
        wizardModel.sampleStatus.openCalculator = .running
        let calculatorURL = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        NSWorkspace.shared.openApplication(at: calculatorURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            Task { @MainActor in
                wizardModel.sampleStatus.openCalculator = error == nil ? .succeeded : .failed
                wizardModel.sampleStatus.click2 = .pending
                wizardModel.sampleStatus.clickPlus = .pending
                wizardModel.sampleStatus.click2Again = .pending
                wizardModel.sampleStatus.clickEquals = .pending
                wizardModel.sampleStatus.verifiedResult = error == nil ? .succeeded : .failed
                wizardModel.sampleIsRunning = false
            }
        }
    }

    private func validateAuditChain() {
        let sessionId = trimmedAuditSessionId
        guard !sessionId.isEmpty else { return }
        auditStatus = AuditOperationStatus(kind: .running, message: "Validating audit chain for \(sessionId)...")
        Task { @MainActor in
            do {
                let result = try validateLocalAuditChain(sessionId: sessionId)
                if result.isValid {
                    auditStatus = AuditOperationStatus(
                        kind: .succeeded,
                        message: "Valid chain: \(result.entryCount) entries linked to head \(result.headHashHex?.prefix(16) ?? "unknown")."
                    )
                } else {
                    let index = result.firstInvalidEntryIndex.map(String.init) ?? "unknown"
                    auditStatus = AuditOperationStatus(
                        kind: .failed,
                        message: "Tamper or corruption detected at entry \(index): \(String(describing: result.firstInvalidReason))."
                    )
                }
            } catch {
                auditStatus = AuditOperationStatus(kind: .failed, message: error.localizedDescription)
            }
        }
    }

    private func exportAuditArchive() {
        let sessionId = trimmedAuditSessionId
        guard !sessionId.isEmpty else { return }
        auditStatus = AuditOperationStatus(kind: .running, message: "Exporting audit archive for \(sessionId)...")
        Task { @MainActor in
            do {
                let response = try await OpenBurnBarDaemonManager.shared.exportComputerUseAudit(
                    ComputerUseAuditExportRequest(
                        sessionId: sessionId,
                        includeScreenshots: auditIncludeScreenshots
                    )
                )
                let archiveURL = URL(fileURLWithPath: response.archiveURL)
                NSWorkspace.shared.activateFileViewerSelecting([archiveURL])
                let signatureSuffix = response.signatureURL == nil
                    ? ""
                    : " Signature sidecar: \(URL(fileURLWithPath: response.signatureURL!).lastPathComponent)."
                let readbackSuffix: String
                if response.signatureURL != nil {
                    if let runtimeController {
                        do {
                            try await runtimeController.publishAuditExportSignerReadback(for: response)
                            readbackSuffix = " Signer key readback published."
                        } catch {
                            readbackSuffix = " Signer key readback was not published: \(error.localizedDescription)"
                        }
                    } else {
                        readbackSuffix = " Signer key readback was not published: Computer Use runtime is not attached."
                    }
                } else {
                    readbackSuffix = ""
                }
                auditStatus = AuditOperationStatus(
                    kind: .succeeded,
                    message: "Exported \(response.entryCount) archive entries (\(response.archiveSizeBytes) bytes) to \(archiveURL.lastPathComponent).\(signatureSuffix)\(readbackSuffix)"
                )
            } catch {
                auditStatus = AuditOperationStatus(kind: .failed, message: error.localizedDescription)
            }
        }
    }

    private func notarizeAuditChain() {
        let sessionId = trimmedAuditSessionId
        guard !sessionId.isEmpty else { return }
        auditStatus = AuditOperationStatus(kind: .running, message: "Notarizing audit-chain head for \(sessionId)...")
        Task { @MainActor in
            do {
                let result = try validateLocalAuditChain(sessionId: sessionId)
                guard result.isValid, let headHash = result.headHashHex else {
                    throw NSError(
                        domain: "ComputerUseAudit",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Audit chain must validate before notarization."]
                    )
                }
                let configuration = ComputerUseOpenTimestampsClient.Configuration()
                let client = ComputerUseOpenTimestampsClient(configuration: configuration)
                let chainURL = auditChainURL(sessionId: sessionId)
                let proof = try await client.notarize(chainFileAt: chainURL)
                let proofURL = try ComputerUseOpenTimestampsArchive.writeProof(
                    proofBytes: proof,
                    sourceChainURL: chainURL,
                    calendarURL: configuration.calendarURL
                )
                NSWorkspace.shared.activateFileViewerSelecting([proofURL])
                auditStatus = AuditOperationStatus(
                    kind: .succeeded,
                    message: "Wrote OpenTimestamps proof \(proofURL.lastPathComponent) for head \(headHash.prefix(16))."
                )
            } catch {
                auditStatus = AuditOperationStatus(kind: .failed, message: error.localizedDescription)
            }
        }
    }

    private func validateLocalAuditChain(sessionId: String) throws -> ComputerUseAuditChain.ValidationResult {
        let manifestURL = auditSessionDirectory(sessionId: sessionId).appendingPathComponent("manifest.json")
        let chainURL = auditChainURL(sessionId: sessionId)
        let headURL = auditSessionDirectory(sessionId: sessionId).appendingPathComponent("head.json")
        let manifest = try ComputerUseAuditHasher.canonicalJSONDecoder.decode(
            ComputerUseSessionManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let expectedHeadHash: String?
        if FileManager.default.fileExists(atPath: headURL.path) {
            struct HeadFile: Decodable { let hashHex: String }
            expectedHeadHash = try ComputerUseAuditHasher.canonicalJSONDecoder
                .decode(HeadFile.self, from: Data(contentsOf: headURL))
                .hashHex
        } else {
            expectedHeadHash = nil
        }
        return try ComputerUseAuditChain().validate(
            at: chainURL,
            sessionManifestHashHex: ComputerUseAuditChain().hashSessionManifest(manifest),
            expectedHeadHashHex: expectedHeadHash
        )
    }

    private func auditSessionDirectory(sessionId: String) -> URL {
        OpenBurnBarAppPaths.live().supportDirectory
            .appendingPathComponent("computer-use-audit", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
    }

    private func auditChainURL(sessionId: String) -> URL {
        auditSessionDirectory(sessionId: sessionId)
            .appendingPathComponent("chain.jsonl", isDirectory: false)
    }
}
#endif

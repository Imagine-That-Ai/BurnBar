import SwiftUI
import OpenBurnBarCore

// MARK: - Plan Strategy

enum ProviderPlanStrategy: String, CaseIterable, Identifiable {
    case auto
    case preferred
    case backup

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto (round-robin)"
        case .preferred: return "Always preferred"
        case .backup: return "Backup only"
        }
    }

    var iconName: String {
        switch self {
        case .auto: return "arrow.triangle.2.circlepath"
        case .preferred: return "star.fill"
        case .backup: return "shield.fill"
        }
    }

    var description: String {
        switch self {
        case .auto: return "Rotates fairly across all active plans"
        case .preferred: return "Always use this plan first, fall back to others only if it fails"
        case .backup: return "Keep disabled until other plans fail, then activate automatically"
        }
    }
}

// MARK: - Wizard Steps

private enum ProviderPlanWizardStep: Int, CaseIterable {
    case dashboard
    case provider
    case apiKey
    case strategy
    case confirm

    var progressFraction: Double {
        guard Self.allCases.count > 1 else { return 1 }
        return Double(rawValue) / Double(Self.allCases.count - 1)
    }

    var stepLabel: String {
        switch self {
        case .dashboard: return "Plans"
        case .provider: return "Provider"
        case .apiKey: return "API Key"
        case .strategy: return "Strategy"
        case .confirm: return "Confirm"
        }
    }

    var shortTitle: String {
        switch self {
        case .dashboard: return "Plans"
        case .provider: return "Provider"
        case .apiKey: return "API Key"
        case .strategy: return "Strategy"
        case .confirm: return "Review"
        }
    }
}

// MARK: - Wizard View

struct ProviderPlanWizardView: View {
    let daemonManager: OpenBurnBarDaemonManager
    let initialProviderID: String?
    let onDismiss: () -> Void

    @State private var currentStep: ProviderPlanWizardStep = .dashboard
    @State private var navigationDirection: Edge = .trailing

    // Step 1 (dashboard) state
    @State private var activeProviderID: String?

    // Step 2 (provider pick) state
    @State private var selectedProviderID: String?

    // Step 3 state
    @State private var planLabel = ""
    @State private var apiKeyInput = ""
    @State private var showAPIKey = false
    @State private var keyValidationMessage: String?
    @State private var keyValidationIsWarning = false
    @State private var isProbingQuota = false
    @State private var quotaProbeResult: String?
    @State private var quotaProbePercent: Double?
    @State private var quotaProbeTask: Task<Void, Never>?

    // Step 4 state
    @State private var selectedStrategy: ProviderPlanStrategy = .auto

    // Save state
    @State private var isSaving = false
    @State private var saveError: String?

    // Delete confirmation
    @State private var slotToDelete: SlotDeleteTarget?

    private struct SlotDeleteTarget: Identifiable {
        let providerID: String
        let slotID: String
        let slotLabel: String
        var id: String { slotID }
    }

    // MARK: - Computed

    private var eligibleProviders: [OpenBurnBarDaemonProviderConfiguration] {
        // All providers with at least accounting capability are eligible for plan management.
        // Routing-capable providers can also proxy requests.
        daemonManager.providerConfigurations
    }

    /// The provider whose plans are being managed on the dashboard.
    private var activeProvider: OpenBurnBarDaemonProviderConfiguration? {
        guard let id = activeProviderID else { return nil }
        return daemonManager.providerConfigurations.first { $0.providerID == id }
    }

    private var selectedProvider: OpenBurnBarDaemonProviderConfiguration? {
        guard let id = selectedProviderID else { return nil }
        return eligibleProviders.first { $0.providerID == id }
    }

    private var canProceedFromProvider: Bool {
        selectedProviderID != nil
    }

    private var canProceedFromAPIKey: Bool {
        let trimmedLabel = planLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedLabel.isEmpty && !trimmedKey.isEmpty
    }

    /// Whether to show the provider-pick step (only when no initial provider and multiple eligible).
    private var needsProviderPick: Bool {
        initialProviderID == nil && eligibleProviders.count > 1
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header
            wizardHeader

            Divider().background(DesignSystem.Colors.border)

            // Content
            ScrollView {
                VStack(spacing: DesignSystem.Spacing.lg) {
                    stepContent
                }
                .padding(DesignSystem.Spacing.lg)
            }

            Divider().background(DesignSystem.Colors.border)

            // Navigation
            wizardNavigation
        }
        .frame(width: 520)
        .frame(minHeight: 480)
        .background(DesignSystem.Colors.background)
        .onAppear {
            if let initialID = initialProviderID {
                activeProviderID = initialID
            } else if eligibleProviders.count == 1 {
                activeProviderID = eligibleProviders.first?.providerID
            }
        }
        .onDisappear {
            quotaProbeTask?.cancel()
        }
        .alert("Delete Plan?", isPresented: Binding(
            get: { slotToDelete != nil },
            set: { if !$0 { slotToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { slotToDelete = nil }
            Button("Delete", role: .destructive) {
                if let target = slotToDelete {
                    deleteSlot(target)
                }
            }
        } message: {
            Text("This will permanently remove the plan \"\(slotToDelete?.slotLabel ?? "")\" and its API key. This cannot be undone.")
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var wizardHeader: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Button {
                    if currentStep == .dashboard {
                        onDismiss()
                    } else if currentStep == .provider {
                        navigateToStep(.dashboard)
                    } else {
                        navigateBack()
                    }
                } label: {
                    Image(systemName: currentStep == .dashboard ? "xmark" : "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)

                Spacer()

                // Show step indicators only during the add flow (not on dashboard)
                if currentStep != .dashboard {
                    ForEach(addFlowSteps, id: \.rawValue) { step in
                        stepIndicator(step)
                        if step != addFlowSteps.last {
                            Spacer()
                        }
                    }
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.top, DesignSystem.Spacing.md)

            Text(stepTitle)
                .font(DesignSystem.Typography.title)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Text(stepDescription)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .padding(.bottom, DesignSystem.Spacing.md)
    }

    /// The steps shown in the add-flow progress indicator (excludes dashboard).
    private var addFlowSteps: [ProviderPlanWizardStep] {
        [.provider, .apiKey, .strategy, .confirm]
    }

    @ViewBuilder
    private func stepIndicator(_ step: ProviderPlanWizardStep) -> some View {
        VStack(spacing: DesignSystem.Spacing.xs) {
            ZStack {
                Circle()
                    .fill(stepStateColor(step))
                    .frame(width: 28, height: 28)

                if step.rawValue < currentStep.rawValue {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(step.rawValue + 1)")
                        .font(DesignSystem.Typography.tiny)
                        .fontWeight(.bold)
                        .foregroundStyle(step == currentStep ? .white : DesignSystem.Colors.textSecondary)
                }
            }

            Text(step.shortTitle)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(step == currentStep ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textMuted)
                .frame(width: 80)
        }
    }

    private func stepStateColor(_ step: ProviderPlanWizardStep) -> Color {
        if step.rawValue < currentStep.rawValue {
            return DesignSystem.Colors.success
        } else if step == currentStep {
            return DesignSystem.Colors.blaze
        } else {
            return DesignSystem.Colors.surface
        }
    }

    // MARK: - Step Content

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .dashboard:
            dashboardStep
        case .provider:
            providerSelectionStep
        case .apiKey:
            apiKeyEntryStep
        case .strategy:
            strategySelectionStep
        case .confirm:
            confirmStep
        }
    }

    // MARK: - Step 0: Dashboard (Plan Management Hub)

    @ViewBuilder
    private var dashboardStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            // Provider selector (if no initial provider was given and there are multiple)
            if initialProviderID == nil && eligibleProviders.count > 1 {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text("Provider")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)

                    Picker("", selection: $activeProviderID) {
                        Text("Select a provider").tag(String?.none)
                        ForEach(eligibleProviders) { config in
                            Text(config.displayName).tag(String?.some(config.providerID))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }

            if let provider = activeProvider {
                // Provider header
                HStack(spacing: DesignSystem.Spacing.md) {
                    CatalogProviderLogoView(brand: provider.brand, size: 36)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(provider.displayName)
                            .font(DesignSystem.Typography.headline)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Text(provider.baseURL)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }

                    Spacer()

                    Toggle("", isOn: Binding(
                        get: { provider.isEnabled },
                        set: { enabled in
                            Task {
                                await daemonManager.updateProviderConfiguration(
                                    providerID: provider.providerID,
                                    isEnabled: enabled
                                )
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(SwitchToggleStyle(tint: DesignSystem.Colors.blaze))
                }

                // Existing plans list
                if provider.credentialSlots.isEmpty {
                    VStack(spacing: DesignSystem.Spacing.md) {
                        Image(systemName: "tray")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(DesignSystem.Colors.textMuted)

                        Text("No plans yet")
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)

                        Text("Add a plan with an API key to start using this provider through OpenBurnBar.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(DesignSystem.Spacing.xl)
                    .background(DesignSystem.Colors.surfaceElevated.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous))
                } else {
                    VStack(spacing: DesignSystem.Spacing.sm) {
                        ForEach(provider.credentialSlots) { slot in
                            planCard(slot, provider: provider)
                        }
                    }
                }

                // Add plan button
                Button {
                    startAddFlow(providerID: provider.providerID)
                } label: {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16))
                        Text("Add Plan")
                            .font(DesignSystem.Typography.body)
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DesignSystem.Spacing.sm)
                    .background(DesignSystem.Colors.blaze)
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
                }
                .buttonStyle(.plain)
            } else if eligibleProviders.isEmpty {
                HStack(spacing: DesignSystem.Spacing.md) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(DesignSystem.Colors.warning)
                    Text("No providers found. Make sure the daemon is running and at least one provider is configured.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                .padding(DesignSystem.Spacing.md)
                .background(DesignSystem.Colors.warning.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private func planCard(_ slot: OpenBurnBarDaemonProviderConfiguration.CredentialSlot, provider: OpenBurnBarDaemonProviderConfiguration) -> some View {
        GlassCard {
            VStack(spacing: DesignSystem.Spacing.md) {
                // Row 1: label + status + preferred badge
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Circle()
                        .fill(slotStatusColor(for: slot.status))
                        .frame(width: 10, height: 10)

                    Text(slot.label)
                        .font(DesignSystem.Typography.body)
                        .fontWeight(.medium)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                    if provider.preferredCredentialSlotID == slot.slotID {
                        HStack(spacing: 3) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9))
                            Text("Preferred")
                                .font(DesignSystem.Typography.tiny)
                        }
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(DesignSystem.Colors.blaze.opacity(0.12))
                        .foregroundStyle(DesignSystem.Colors.blaze)
                        .clipShape(Capsule())
                    }

                    if !slot.isEnabled {
                        Text("Disabled")
                            .font(DesignSystem.Typography.tiny)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(DesignSystem.Colors.textMuted.opacity(0.12))
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .clipShape(Capsule())
                    }

                    Spacer()

                    // Action buttons
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        if provider.preferredCredentialSlotID != slot.slotID && slot.isEnabled {
                            Button {
                                Task {
                                    await daemonManager.setPreferredProviderCredentialSlot(
                                        providerID: provider.providerID,
                                        slotID: slot.slotID
                                    )
                                }
                            } label: {
                                Image(systemName: "star")
                                    .font(.system(size: 12))
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                            }
                            .buttonStyle(.plain)
                            .help("Set as preferred plan")
                        }

                        Button {
                            Task {
                                await daemonManager.updateProviderCredentialSlot(
                                    providerID: provider.providerID,
                                    slotID: slot.slotID,
                                    isEnabled: !slot.isEnabled
                                )
                            }
                        } label: {
                            Image(systemName: slot.isEnabled ? "pause.circle" : "play.circle")
                                .font(.system(size: 14))
                                .foregroundStyle(slot.isEnabled ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.success)
                        }
                        .buttonStyle(.plain)
                        .help(slot.isEnabled ? "Disable plan" : "Enable plan")

                        Button {
                            slotToDelete = SlotDeleteTarget(
                                providerID: provider.providerID,
                                slotID: slot.slotID,
                                slotLabel: slot.label
                            )
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 12))
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                        }
                        .buttonStyle(.plain)
                        .help("Delete plan")
                    }
                }

                // Row 2: quota info
                HStack(spacing: DesignSystem.Spacing.xs) {
                    if let pct = slot.lastQuotaRemainingPercent {
                        Text("\(Int(pct.rounded()))% remaining")
                            .font(DesignSystem.Typography.monoSmall)
                            .foregroundStyle(pct > 20 ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.warning)

                        if let resetAt = slot.lastQuotaResetsAt {
                            Text("· resets \(resetAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                        }
                    } else if slot.status == .missingSecret {
                        Text("Missing API key")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.error)
                    } else {
                        Text("Quota unknown")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }

                    Spacer()

                    Button {
                        Task {
                            await daemonManager.refreshProviderCredentialSlotQuotas(
                                providerID: provider.providerID
                            )
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                    .buttonStyle(.plain)
                    .help("Refresh quota")
                }
            }
            .padding(DesignSystem.Spacing.md)
        }
    }

    private func slotStatusColor(for status: BurnBarProviderCredentialSlotStatus) -> Color {
        switch status {
        case .ready: return DesignSystem.Colors.success
        case .coolingDown: return DesignSystem.Colors.warning
        case .exhausted, .missingSecret: return DesignSystem.Colors.error
        case .disabled: return DesignSystem.Colors.textMuted
        }
    }

    // MARK: - Step 1: Pick Provider

    @ViewBuilder
    private var providerSelectionStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("Choose a provider to add a plan to")
                .font(DesignSystem.Typography.body)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Text("Each plan gets its own API key and quota. OpenBurnBar rotates between plans automatically.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            if eligibleProviders.isEmpty {
                HStack(spacing: DesignSystem.Spacing.md) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(DesignSystem.Colors.warning)
                    Text("No providers found. Make sure the daemon is running and at least one provider is configured.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                .padding(DesignSystem.Spacing.md)
                .background(DesignSystem.Colors.warning.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
            } else {
                VStack(spacing: DesignSystem.Spacing.sm) {
                    ForEach(eligibleProviders) { provider in
                        providerOption(provider)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func providerOption(_ config: OpenBurnBarDaemonProviderConfiguration) -> some View {
        let isSelected = selectedProviderID == config.providerID

        Button {
            selectedProviderID = config.providerID
        } label: {
            HStack(spacing: DesignSystem.Spacing.md) {
                CatalogProviderLogoView(brand: config.brand, size: 32)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Text(config.displayName)
                            .font(DesignSystem.Typography.body)
                            .fontWeight(.medium)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)

                        Text("\(config.credentialSlots.count) plan\(config.credentialSlots.count == 1 ? "" : "s")")
                            .font(DesignSystem.Typography.tiny)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(DesignSystem.Colors.surfaceElevated)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .clipShape(Capsule())
                    }

                    Text(providerDescription(for: config.provider))
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DesignSystem.Colors.blaze)
                }
            }
            .padding(DesignSystem.Spacing.md)
            .background(isSelected ? DesignSystem.Colors.blaze.opacity(0.1) : DesignSystem.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(isSelected ? DesignSystem.Colors.blaze : DesignSystem.Colors.border, lineWidth: isSelected ? 1.5 : 0.5))
        }
        .buttonStyle(.plain)
    }

    private func providerDescription(for provider: AgentProvider?) -> String {
        switch provider {
        case .zai:
            return "GLM coding plan via Z.ai API"
        case .minimax:
            return "Token Plan or OpenAPI key via MiniMax"
        case .codex:
            return "OpenAI API key for Codex models"
        case .claudeCode:
            return "Anthropic API key for Claude models"
        case .geminiCLI:
            return "Google API key for Gemini models"
        default:
            // Catalog providers that don't map to an AgentProvider get a generic description
            return "API key for this provider"
        }
    }

    // MARK: - Step 2: Enter API Key

    @ViewBuilder
    private var apiKeyEntryStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                if let provider = selectedProvider {
                    CatalogProviderLogoView(brand: provider.brand, size: 20)
                    Text(provider.displayName)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
            }

            Text("Enter a label and API key for this plan")
                .font(DesignSystem.Typography.body)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            // Label field
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Plan label")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                TextField("e.g. Work plan, Personal plan", text: $planLabel)
                    .textFieldStyle(.roundedBorder)
                    .font(DesignSystem.Typography.body)
                    .onChange(of: planLabel) {
                        keyValidationMessage = nil
                    }
            }

            // API key field
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                HStack {
                    Text("API key")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)

                    Spacer()

                    Button {
                        showAPIKey.toggle()
                    } label: {
                        Image(systemName: showAPIKey ? "eye.slash" : "eye")
                            .font(.system(size: 11))
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                    .buttonStyle(.plain)
                }

                if showAPIKey {
                    TextField("Paste your API key here", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(DesignSystem.Typography.monoSmall)
                        .textContentType(.password)
                        .onChange(of: apiKeyInput) {
                            validateAPIKey()
                            scheduleQuotaProbe()
                        }
                } else {
                    SecureField("Paste your API key here", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(DesignSystem.Typography.monoSmall)
                        .onChange(of: apiKeyInput) {
                            validateAPIKey()
                            scheduleQuotaProbe()
                        }
                }
            }

            // Validation message
            if let message = keyValidationMessage {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: keyValidationIsWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(keyValidationIsWarning ? DesignSystem.Colors.warning : DesignSystem.Colors.success)
                    Text(message)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(keyValidationIsWarning ? DesignSystem.Colors.warning : DesignSystem.Colors.success)
                }
            }

            // Quota probe result
            if isProbingQuota {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking quota...")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
            } else if let result = quotaProbeResult {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DesignSystem.Colors.success)
                    Text(result)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
            }
        }
        .onAppear {
            if planLabel.isEmpty {
                let slotProvider = selectedProvider ?? activeProvider
                if let provider = slotProvider {
                    let slotCount = provider.credentialSlots.count
                    planLabel = slotCount == 0 ? "Default" : "Plan \(slotCount + 1)"
                }
            }
        }
    }

    private func validateAPIKey() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            keyValidationMessage = nil
            return
        }

        guard let provider = selectedProvider?.provider else { return }

        switch provider {
        case .minimax:
            if !trimmed.hasPrefix("sk-cp-") {
                keyValidationMessage = "This doesn't look like a MiniMax coding plan key (expected sk-cp-...)"
                keyValidationIsWarning = true
            } else {
                keyValidationMessage = "Key format looks correct"
                keyValidationIsWarning = false
            }
        case .zai:
            keyValidationMessage = "Key entered"
            keyValidationIsWarning = false
        default:
            break
        }
    }

    private func scheduleQuotaProbe() {
        quotaProbeTask?.cancel()
        quotaProbeResult = nil
        quotaProbePercent = nil

        let trimmedKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, let provider = selectedProvider else { return }

        guard let quotaProvider = providerSlotQuotaProvider(for: provider.providerID) else { return }

        quotaProbeTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                isProbingQuota = true
            }

            do {
                let snapshot = try await ProviderQuotaService.shared.fetchSnapshot(
                    for: quotaProvider,
                    apiKeyOverride: trimmedKey
                )
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    isProbingQuota = false
                    if let bucket = snapshot.primaryBucket {
                        let pct = bucket.remainingPercent
                        quotaProbePercent = pct
                        if let pct {
                            quotaProbeResult = "\(Int(pct.rounded()))% remaining \(bucket.label.isEmpty ? "" : "(\(bucket.label))")"
                        } else {
                            quotaProbeResult = bucket.remainingText
                        }
                    } else {
                        quotaProbeResult = "No quota data returned"
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    isProbingQuota = false
                    quotaProbeResult = nil
                }
            }
        }
    }

    private func providerSlotQuotaProvider(for providerID: String) -> AgentProvider? {
        switch providerID.lowercased() {
        case "minimax": return .minimax
        case "zai": return .zai
        default: return nil
        }
    }

    // MARK: - Step 3: Choose Strategy

    @ViewBuilder
    private var strategySelectionStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("How should this plan be used?")
                .font(DesignSystem.Typography.body)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Text("This controls when OpenBurnBar picks this plan for requests.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            VStack(spacing: DesignSystem.Spacing.sm) {
                ForEach(ProviderPlanStrategy.allCases) { strategy in
                    strategyOption(strategy)
                }
            }
        }
    }

    @ViewBuilder
    private func strategyOption(_ strategy: ProviderPlanStrategy) -> some View {
        let isSelected = selectedStrategy == strategy

        Button {
            selectedStrategy = strategy
        } label: {
            HStack(spacing: DesignSystem.Spacing.md) {
                Image(systemName: strategy.iconName)
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? DesignSystem.Colors.blaze : DesignSystem.Colors.textMuted)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(strategy.displayName)
                        .font(DesignSystem.Typography.body)
                        .fontWeight(.medium)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(strategy.description)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DesignSystem.Colors.blaze)
                }
            }
            .padding(DesignSystem.Spacing.md)
            .background(isSelected ? DesignSystem.Colors.blaze.opacity(0.1) : DesignSystem.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(isSelected ? DesignSystem.Colors.blaze : DesignSystem.Colors.border, lineWidth: isSelected ? 1.5 : 0.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 4: Confirm

    @ViewBuilder
    private var confirmStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            Text("Review your new plan")
                .font(DesignSystem.Typography.title)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            // Summary card
            GlassCard {
                VStack(spacing: DesignSystem.Spacing.md) {
                    // Provider header
                    HStack(spacing: DesignSystem.Spacing.md) {
                        if let provider = selectedProvider {
                            CatalogProviderLogoView(brand: provider.brand, size: 28)
                            Text(provider.displayName)
                                .font(DesignSystem.Typography.headline)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                        }
                        Spacer()
                    }

                    Divider().background(DesignSystem.Colors.border)

                    // Plan details
                    reviewRow("Label", value: planLabel.trimmingCharacters(in: .whitespacesAndNewlines))

                    Divider().background(DesignSystem.Colors.border)

                    reviewRow("API key", value: maskedKey)

                    Divider().background(DesignSystem.Colors.border)

                    // Quota preview
                    HStack {
                        Text("Quota")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                        Spacer()
                        if let result = quotaProbeResult {
                            Text(result)
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                        } else {
                            Text("Will check after saving")
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                        }
                    }
                    .padding(DesignSystem.Spacing.md)

                    Divider().background(DesignSystem.Colors.border)

                    // Strategy
                    HStack {
                        Text("Strategy")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                        Spacer()
                        strategyBadge(selectedStrategy)
                    }
                    .padding(DesignSystem.Spacing.md)
                }
            }

            // Save error
            if let error = saveError {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(DesignSystem.Colors.error)
                    Text(error)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.error)
                }
            }

            Text("You can change the strategy or disable this plan at any time from provider settings.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }

    @ViewBuilder
    private func reviewRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Spacer()
            Text(value)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .textSelection(.enabled)
        }
        .padding(DesignSystem.Spacing.md)
    }

    @ViewBuilder
    private func strategyBadge(_ strategy: ProviderPlanStrategy) -> some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: strategy.iconName)
                .font(.system(size: 10))
            Text(strategy.displayName)
                .font(DesignSystem.Typography.caption)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(DesignSystem.Colors.blaze.opacity(0.12))
        .foregroundStyle(DesignSystem.Colors.blaze)
        .clipShape(Capsule())
    }

    private var maskedKey: String {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 8 {
            return String(repeating: "•", count: trimmed.count)
        }
        let prefix = trimmed.prefix(4)
        let suffix = trimmed.suffix(4)
        return "\(prefix)••••\(suffix)"
    }

    // MARK: - Navigation

    @ViewBuilder
    private var wizardNavigation: some View {
        if currentStep == .dashboard {
            // Dashboard: just a close button
            HStack {
                Spacer()
                Button("Done") { onDismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignSystem.Colors.blaze)
            }
            .padding(DesignSystem.Spacing.lg)
        } else {
            // Add flow: Back / Cancel / Next-or-Save
            HStack {
                Button("Back") {
                    navigateBack()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Cancel") {
                    navigateToStep(.dashboard)
                }
                .buttonStyle(.bordered)
                .foregroundStyle(DesignSystem.Colors.textMuted)

                if currentStep == .confirm {
                    Button(isSaving ? "Saving..." : "Save Plan") {
                        savePlan()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignSystem.Colors.blaze)
                    .disabled(isSaving)
                } else {
                    Button("Next") {
                        navigateForward()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignSystem.Colors.blaze)
                    .disabled(!canProceedFromCurrentStep)
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }

    private var canProceedFromCurrentStep: Bool {
        switch currentStep {
        case .dashboard:
            return false
        case .provider:
            return canProceedFromProvider
        case .apiKey:
            return canProceedFromAPIKey
        case .strategy:
            return true
        case .confirm:
            return false
        }
    }

    // MARK: - Step Properties

    private var stepTitle: String {
        switch currentStep {
        case .dashboard:
            if let provider = activeProvider {
                return "\(provider.displayName) Plans"
            }
            return "Manage Plans"
        case .provider: return "Pick Provider"
        case .apiKey: return "Enter API Key"
        case .strategy: return "Choose Strategy"
        case .confirm: return "Review & Save"
        }
    }

    private var stepDescription: String {
        switch currentStep {
        case .dashboard: return "View, manage, and add plans for this provider"
        case .provider: return "Select which provider this plan is for"
        case .apiKey: return "Add a label and paste the API key"
        case .strategy: return "Control when OpenBurnBar uses this plan"
        case .confirm: return "Verify everything looks right before saving"
        }
    }

    // MARK: - Navigation Actions

    private func startAddFlow(providerID: String) {
        selectedProviderID = providerID
        planLabel = ""
        apiKeyInput = ""
        showAPIKey = false
        keyValidationMessage = nil
        quotaProbeResult = nil
        quotaProbePercent = nil
        selectedStrategy = .auto
        saveError = nil

        if needsProviderPick {
            navigateToStep(.provider)
        } else {
            // Skip provider pick, go straight to API key
            navigateToStep(.apiKey)
        }
    }

    private func navigateForward() {
        guard let next = ProviderPlanWizardStep(rawValue: currentStep.rawValue + 1) else { return }
        navigationDirection = .trailing
        withAnimation(.easeInOut(duration: 0.25)) {
            currentStep = next
        }
    }

    private func navigateBack() {
        // When in the add flow and provider pick was skipped, back goes to dashboard
        if currentStep == .apiKey && !needsProviderPick {
            navigateToStep(.dashboard)
            return
        }
        guard let prev = ProviderPlanWizardStep(rawValue: currentStep.rawValue - 1) else { return }
        navigationDirection = .leading
        withAnimation(.easeInOut(duration: 0.25)) {
            currentStep = prev
        }
    }

    private func navigateToStep(_ step: ProviderPlanWizardStep) {
        navigationDirection = step.rawValue > currentStep.rawValue ? .trailing : .leading
        withAnimation(.easeInOut(duration: 0.25)) {
            currentStep = step
        }
    }

    // MARK: - Delete Slot

    private func deleteSlot(_ target: SlotDeleteTarget) {
        Task {
            await daemonManager.removeProviderCredentialSlot(
                providerID: target.providerID,
                slotID: target.slotID
            )
            slotToDelete = nil
        }
    }

    // MARK: - Save

    private func savePlan() {
        guard let providerID = selectedProviderID ?? activeProviderID else { return }

        let label = planLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, !apiKey.isEmpty else { return }

        isSaving = true
        saveError = nil

        Task {
            // Add the slot
            await daemonManager.addProviderCredentialSlot(
                providerID: providerID,
                label: label,
                apiKey: apiKey
            )

            // Apply strategy
            switch selectedStrategy {
            case .auto:
                break
            case .preferred:
                if let updatedConfig = daemonManager.providerConfigurations
                    .first(where: { $0.providerID == providerID }),
                   let newSlot = updatedConfig.credentialSlots.last {
                    await daemonManager.setPreferredProviderCredentialSlot(
                        providerID: providerID,
                        slotID: newSlot.slotID
                    )
                }
            case .backup:
                if let updatedConfig = daemonManager.providerConfigurations
                    .first(where: { $0.providerID == providerID }),
                   let newSlot = updatedConfig.credentialSlots.last {
                    await daemonManager.updateProviderCredentialSlot(
                        providerID: providerID,
                        slotID: newSlot.slotID,
                        isEnabled: false
                    )
                }
            }

            // Refresh quotas
            await daemonManager.refreshProviderCredentialSlotQuotas(providerID: providerID)

            await MainActor.run {
                isSaving = false
                // Return to dashboard instead of dismissing
                activeProviderID = providerID
                navigateToStep(.dashboard)
            }
        }
    }
}

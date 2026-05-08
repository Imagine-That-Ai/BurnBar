import AppKit
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
        case .auto: return "Auto rotate"
        case .preferred: return "Always preferred"
        case .backup: return "Backup only"
        }
    }

    var iconName: String {
        switch self {
        case .auto: return "arrow.triangle.2.circlepath"
        case .preferred: return "star.fill"
        case .backup: return "shield.lefthalf.filled"
        }
    }

    var summary: String {
        switch self {
        case .auto: return "Rotate fairly across plans"
        case .preferred: return "Use this plan first, fall back on failure"
        case .backup: return "Stay disabled until other plans fail"
        }
    }
}

// MARK: - Wizard Steps

private enum ProviderPlanWizardStep: Int, CaseIterable {
    case dashboard
    case provider
    case auth
    case credential
    case strategy
    case confirm

    var stepIndex: Int? {
        switch self {
        case .dashboard: return nil
        case .provider: return 1
        case .auth: return 2
        case .credential: return 3
        case .strategy: return 4
        case .confirm: return 5
        }
    }

    var shortTitle: String {
        switch self {
        case .dashboard: return "Plans"
        case .provider: return "Provider"
        case .auth: return "Method"
        case .credential: return "Credential"
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

    // Dashboard state
    @State private var activeProviderID: String?

    // Provider step state
    @State private var selectedProviderID: String?
    @State private var providerSearchQuery: String = ""

    // Auth method step state
    @State private var selectedAuthMethodID: String?

    // Credential step state
    @State private var planLabel = ""
    @State private var apiKeyInput = ""
    @State private var showAPIKey = false
    @State private var isProbingQuota = false
    @State private var quotaProbeResult: String?
    @State private var quotaProbePercent: Double?
    @State private var quotaProbeError: String?
    @State private var quotaProbeTask: Task<Void, Never>?

    // Strategy step state
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

    // MARK: - Lookups

    private var eligibleProviders: [OpenBurnBarDaemonProviderConfiguration] {
        let sorted = daemonManager.providerConfigurations.sorted { lhs, rhs in
            let lhsHasRouting = lhs.hasRoutingCapability
            let rhsHasRouting = rhs.hasRoutingCapability
            if lhsHasRouting != rhsHasRouting { return lhsHasRouting && !rhsHasRouting }
            if lhs.credentialSlots.count != rhs.credentialSlots.count {
                return lhs.credentialSlots.count > rhs.credentialSlots.count
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        return sorted
    }

    private var filteredProviders: [OpenBurnBarDaemonProviderConfiguration] {
        let query = providerSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return eligibleProviders }
        return eligibleProviders.filter { config in
            config.displayName.lowercased().contains(query)
                || config.providerID.lowercased().contains(query)
                || (descriptor(for: config.providerID).aliasProviderIDs.contains { $0.contains(query) })
        }
    }

    private var routingProviders: [OpenBurnBarDaemonProviderConfiguration] {
        filteredProviders.filter { $0.hasRoutingCapability }
    }

    private var trackingProviders: [OpenBurnBarDaemonProviderConfiguration] {
        filteredProviders.filter { !$0.hasRoutingCapability }
    }

    private var activeProvider: OpenBurnBarDaemonProviderConfiguration? {
        guard let id = activeProviderID else { return nil }
        return daemonManager.providerConfigurations.first { $0.providerID == id }
    }

    private var selectedProvider: OpenBurnBarDaemonProviderConfiguration? {
        guard let id = selectedProviderID else { return nil }
        return eligibleProviders.first { $0.providerID == id }
    }

    private var selectedDescriptor: BurnBarProviderAuthDescriptor? {
        guard let id = selectedProviderID else { return nil }
        return descriptor(for: id)
    }

    private var selectedAuthMethod: BurnBarProviderAuthMethod? {
        guard let descriptor = selectedDescriptor else { return nil }
        if let id = selectedAuthMethodID, let method = descriptor.method(id: id) {
            return method
        }
        return descriptor.primaryMethod
    }

    private func descriptor(for providerID: String) -> BurnBarProviderAuthDescriptor {
        let displayName = daemonManager.providerConfigurations
            .first { $0.providerID == providerID }?.displayName ?? providerID.capitalized
        let supportsProxy = daemonManager.providerConfigurations
            .first { $0.providerID == providerID }?.hasRoutingCapability ?? true
        return BurnBarProviderAuthRegistry.descriptorOrFallback(
            forCatalogProviderID: providerID,
            displayName: displayName,
            supportsProxyRouting: supportsProxy
        )
    }

    private func quotaProbeProvider(for providerID: String) -> AgentProvider? {
        AgentProvider.fromCatalogProviderID(providerID)
    }

    private var canProceedFromProvider: Bool { selectedProviderID != nil }
    private var canProceedFromAuth: Bool { selectedAuthMethod != nil }
    private var canProceedFromCredential: Bool {
        let trimmedLabel = planLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedLabel.isEmpty && !trimmedKey.isEmpty
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            wizardHeader

            Divider().background(DesignSystem.Colors.border)

            ScrollView {
                stepContent
                    .padding(.horizontal, DesignSystem.Spacing.lg)
                    .padding(.top, DesignSystem.Spacing.lg)
                    .padding(.bottom, DesignSystem.Spacing.xl)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .transition(stepTransition)
                    .id(currentStep)
            }

            Divider().background(DesignSystem.Colors.border)

            wizardNavigation
        }
        .frame(width: 600)
        .frame(minHeight: 580)
        .background(DesignSystem.Colors.background)
        .onAppear { primeWizardOnAppear() }
        .onDisappear { quotaProbeTask?.cancel() }
        .alert("Delete plan?", isPresented: Binding(
            get: { slotToDelete != nil },
            set: { if !$0 { slotToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { slotToDelete = nil }
            Button("Delete", role: .destructive) {
                if let target = slotToDelete { deleteSlot(target) }
            }
        } message: {
            Text("This permanently removes the plan \"\(slotToDelete?.slotLabel ?? "")\" and its credentials.")
        }
    }

    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    private func primeWizardOnAppear() {
        if let initialID = initialProviderID {
            activeProviderID = initialID
        } else if eligibleProviders.count == 1 {
            activeProviderID = eligibleProviders.first?.providerID
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var wizardHeader: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
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
                        .frame(width: 28, height: 28)
                        .background(
                            Circle().fill(DesignSystem.Colors.surfaceElevated)
                        )
                        .overlay(
                            Circle().stroke(DesignSystem.Colors.border, lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)

                Spacer()

                if currentStep != .dashboard {
                    progressTrack
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.top, DesignSystem.Spacing.md)

            VStack(alignment: .leading, spacing: 2) {
                Text(stepTitle)
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text(stepDescription)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
        }
        .padding(.bottom, DesignSystem.Spacing.md)
    }

    private var addFlowSteps: [ProviderPlanWizardStep] {
        [.provider, .auth, .credential, .strategy, .confirm]
    }

    @ViewBuilder
    private var progressTrack: some View {
        HStack(spacing: 0) {
            ForEach(Array(addFlowSteps.enumerated()), id: \.element.rawValue) { index, step in
                progressNode(step)
                if index < addFlowSteps.count - 1 {
                    progressConnector(after: step)
                }
            }
        }
    }

    @ViewBuilder
    private func progressNode(_ step: ProviderPlanWizardStep) -> some View {
        let isCurrent = step == currentStep
        let isPast = step.rawValue < currentStep.rawValue
        let accent = stepAccentGradient

        ZStack {
            Circle()
                .fill(isPast || isCurrent ? AnyShapeStyle(accent) : AnyShapeStyle(DesignSystem.Colors.surfaceElevated))
                .frame(width: 22, height: 22)
                .overlay(
                    Circle().stroke(
                        isCurrent ? DesignSystem.Colors.blaze : DesignSystem.Colors.border,
                        lineWidth: isCurrent ? 1.5 : 0.5
                    )
                )

            if isPast {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.white)
            } else if let index = step.stepIndex {
                Text("\(index)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isCurrent ? .white : DesignSystem.Colors.textSecondary)
            }
        }
        .accessibilityLabel("Step \(step.stepIndex.map(String.init) ?? "") \(step.shortTitle)")
    }

    @ViewBuilder
    private func progressConnector(after step: ProviderPlanWizardStep) -> some View {
        let isCompleted = step.rawValue < currentStep.rawValue
        Rectangle()
            .fill(isCompleted ? AnyShapeStyle(stepAccentGradient) : AnyShapeStyle(DesignSystem.Colors.border))
            .frame(width: 26, height: 2)
            .padding(.horizontal, 2)
    }

    private var stepAccentGradient: LinearGradient {
        if let provider = selectedProvider {
            let primary = ProviderBrand.colorForProviderID(provider.providerID)
            return LinearGradient(
                colors: [primary.opacity(0.95), DesignSystem.Colors.blaze.opacity(0.95)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        return LinearGradient(
            colors: [DesignSystem.Colors.blaze, DesignSystem.Colors.blaze.opacity(0.7)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Step Content

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .dashboard: dashboardStep
        case .provider: providerSelectionStep
        case .auth: authMethodStep
        case .credential: credentialEntryStep
        case .strategy: strategySelectionStep
        case .confirm: confirmStep
        }
    }

    // MARK: - Dashboard Step

    @ViewBuilder
    private var dashboardStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            if eligibleProviders.isEmpty {
                emptyDaemonNotice
            } else if let provider = activeProvider {
                providerHero(provider)
                providerSlotList(provider)
                addPlanCTA(providerID: provider.providerID)
            } else {
                Text("Select a provider to manage its plans, or add a new account.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                Button {
                    selectedProviderID = nil
                    selectedAuthMethodID = nil
                    navigateToStep(.provider)
                } label: {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Add a Provider Account")
                            .font(DesignSystem.Typography.body)
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DesignSystem.Spacing.sm + 2)
                    .background(stepAccentGradient)
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var emptyDaemonNotice: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "exclamationmark.bubble")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(DesignSystem.Colors.warning)

            Text("Daemon not ready")
                .font(DesignSystem.Typography.headline)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Text("OpenBurnBar's daemon hasn't returned a provider list yet. Make sure it's installed and running.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(DesignSystem.Spacing.xl)
        .background(DesignSystem.Colors.surface.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func providerHero(_ provider: OpenBurnBarDaemonProviderConfiguration) -> some View {
        let descriptor = self.descriptor(for: provider.providerID)
        let primary = ProviderBrand.colorForProviderID(provider.providerID)
        let gradient = LinearGradient(
            colors: [primary.opacity(0.32), primary.opacity(0.08)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(spacing: DesignSystem.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(gradient)
                        .frame(width: 56, height: 56)
                    CatalogProviderLogoView(brand: provider.brand, size: 36)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(provider.displayName)
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                    Text(descriptor.summary)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(2)
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

            HStack(spacing: 6) {
                if descriptor.supportsProxyRouting && provider.hasRoutingCapability {
                    capabilityChip(label: "Routed proxy", system: "arrow.triangle.swap", tint: DesignSystem.Colors.blaze)
                }
                if descriptor.supportsQuotaRefresh {
                    capabilityChip(label: "Live quota", system: "gauge.with.needle", tint: DesignSystem.Colors.success)
                }
                if !descriptor.supportsProxyRouting && !provider.hasRoutingCapability {
                    capabilityChip(label: "Tracking only", system: "chart.bar.doc.horizontal", tint: DesignSystem.Colors.textMuted)
                }
                Spacer()
                Text(provider.baseURL.isEmpty ? "Daemon-managed" : provider.baseURL)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .fill(DesignSystem.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [primary.opacity(0.6), primary.opacity(0.0)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
    }

    @ViewBuilder
    private func capabilityChip(label: String, system: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: system).font(.system(size: 9, weight: .semibold))
            Text(label).font(DesignSystem.Typography.tiny).fontWeight(.medium)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(tint.opacity(0.14))
        .foregroundStyle(tint)
        .clipShape(Capsule())
    }

    @ViewBuilder
    private func providerSlotList(_ provider: OpenBurnBarDaemonProviderConfiguration) -> some View {
        if provider.credentialSlots.isEmpty {
            VStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "tray")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Text("No accounts yet")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Text("Add a credential to start using this provider through OpenBurnBar.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(DesignSystem.Spacing.xl)
            .background(DesignSystem.Colors.surfaceElevated.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous))
        } else {
            VStack(spacing: DesignSystem.Spacing.sm) {
                ForEach(provider.credentialSlots) { slot in
                    planCard(slot, provider: provider)
                }
            }
        }
    }

    @ViewBuilder
    private func planCard(_ slot: OpenBurnBarDaemonProviderConfiguration.CredentialSlot, provider: OpenBurnBarDaemonProviderConfiguration) -> some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Circle()
                    .fill(slotStatusColor(for: slot.status))
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle()
                            .stroke(slotStatusColor(for: slot.status).opacity(0.35), lineWidth: 4)
                            .frame(width: 16, height: 16)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(slot.label)
                            .font(DesignSystem.Typography.body)
                            .fontWeight(.medium)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)

                        if provider.preferredCredentialSlotID == slot.slotID {
                            HStack(spacing: 3) {
                                Image(systemName: "star.fill").font(.system(size: 9))
                                Text("Preferred").font(DesignSystem.Typography.tiny)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(DesignSystem.Colors.blaze.opacity(0.14))
                            .foregroundStyle(DesignSystem.Colors.blaze)
                            .clipShape(Capsule())
                        }

                        if !slot.isEnabled {
                            Text("Disabled")
                                .font(DesignSystem.Typography.tiny)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(DesignSystem.Colors.textMuted.opacity(0.12))
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                .clipShape(Capsule())
                        }
                    }
                    slotStatusLine(slot)
                }

                Spacer()

                slotActionRow(slot, provider: provider)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
    }

    @ViewBuilder
    private func slotStatusLine(_ slot: OpenBurnBarDaemonProviderConfiguration.CredentialSlot) -> some View {
        if let percent = slot.lastQuotaRemainingPercent {
            HStack(spacing: 4) {
                Text("\(Int(percent.rounded()))% remaining")
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(percent > 20 ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.warning)
                if let resets = slot.lastQuotaResetsAt {
                    Text("· resets \(resets.formatted(date: .abbreviated, time: .shortened))")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
        } else if slot.status == .missingSecret {
            Text("Missing credential")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.error)
        } else {
            Text("Quota will refresh after first use")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }

    @ViewBuilder
    private func slotActionRow(_ slot: OpenBurnBarDaemonProviderConfiguration.CredentialSlot, provider: OpenBurnBarDaemonProviderConfiguration) -> some View {
        HStack(spacing: 4) {
            if provider.preferredCredentialSlotID != slot.slotID && slot.isEnabled {
                slotButton("star", help: "Mark preferred") {
                    Task {
                        await daemonManager.setPreferredProviderCredentialSlot(
                            providerID: provider.providerID,
                            slotID: slot.slotID
                        )
                    }
                }
            }

            slotButton(slot.isEnabled ? "pause.circle" : "play.circle",
                       help: slot.isEnabled ? "Pause" : "Resume") {
                Task {
                    await daemonManager.updateProviderCredentialSlot(
                        providerID: provider.providerID,
                        slotID: slot.slotID,
                        isEnabled: !slot.isEnabled
                    )
                }
            }

            slotButton("arrow.clockwise", help: "Refresh quota") {
                Task {
                    await daemonManager.refreshProviderCredentialSlotQuotas(
                        providerID: provider.providerID
                    )
                }
            }

            slotButton("trash", help: "Delete plan", tint: DesignSystem.Colors.error) {
                slotToDelete = SlotDeleteTarget(
                    providerID: provider.providerID,
                    slotID: slot.slotID,
                    slotLabel: slot.label
                )
            }
        }
    }

    @ViewBuilder
    private func slotButton(_ symbol: String, help: String, tint: Color = DesignSystem.Colors.textSecondary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(DesignSystem.Colors.surfaceElevated)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private func addPlanCTA(providerID: String) -> some View {
        Button {
            startAddFlow(providerID: providerID)
        } label: {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text("Add another account")
                    .font(DesignSystem.Typography.body)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignSystem.Spacing.sm + 2)
            .background(stepAccentGradient)
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

    // MARK: - Provider Step

    @ViewBuilder
    private var providerSelectionStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            providerSearchField

            if filteredProviders.isEmpty {
                emptySearchNotice
            } else {
                if !routingProviders.isEmpty {
                    sectionHeader("Routed proxy", subtitle: "Connect once and proxy traffic round-robins across plans.")
                    providerGrid(routingProviders)
                }

                if !trackingProviders.isEmpty {
                    sectionHeader("Quota & tracking", subtitle: "Connect for live quota and usage tracking.", topPadding: routingProviders.isEmpty ? 0 : DesignSystem.Spacing.lg)
                    providerGrid(trackingProviders)
                }
            }
        }
    }

    @ViewBuilder
    private var providerSearchField: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textMuted)
            TextField("Search providers", text: $providerSearchQuery)
                .textFieldStyle(.plain)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            if !providerSearchQuery.isEmpty {
                Button { providerSearchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm + 2)
        .background(DesignSystem.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
    }

    @ViewBuilder
    private var emptySearchNotice: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text("No providers match \"\(providerSearchQuery)\"")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(DesignSystem.Spacing.xl)
    }

    @ViewBuilder
    private func sectionHeader(_ title: String, subtitle: String? = nil, topPadding: CGFloat = 0) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            if let subtitle {
                Text(subtitle)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
        .padding(.top, topPadding)
    }

    @ViewBuilder
    private func providerGrid(_ providers: [OpenBurnBarDaemonProviderConfiguration]) -> some View {
        let columns = [
            GridItem(.flexible(), spacing: DesignSystem.Spacing.sm),
            GridItem(.flexible(), spacing: DesignSystem.Spacing.sm)
        ]
        LazyVGrid(columns: columns, spacing: DesignSystem.Spacing.sm) {
            ForEach(providers) { provider in
                providerTile(provider)
            }
        }
    }

    @ViewBuilder
    private func providerTile(_ config: OpenBurnBarDaemonProviderConfiguration) -> some View {
        let isSelected = selectedProviderID == config.providerID
        let descriptor = self.descriptor(for: config.providerID)
        let primary = ProviderBrand.colorForProviderID(config.providerID)

        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                selectedProviderID = config.providerID
                selectedAuthMethodID = descriptor.primaryMethod.id
            }
        } label: {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(LinearGradient(
                                colors: [primary.opacity(0.32), primary.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                            .frame(width: 40, height: 40)
                        CatalogProviderLogoView(brand: config.brand, size: 26)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(config.displayName)
                            .font(DesignSystem.Typography.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        if config.credentialSlots.isEmpty {
                            Text("Not connected")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                        } else {
                            Text("\(config.credentialSlots.count) plan\(config.credentialSlots.count == 1 ? "" : "s")")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        }
                    }
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(primary)
                            .transition(.scale.combined(with: .opacity))
                    }
                }

                Text(descriptor.summary)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 4) {
                    if descriptor.supportsProxyRouting {
                        miniChip("Routing", system: "arrow.triangle.swap", tint: DesignSystem.Colors.blaze)
                    }
                    if descriptor.supportsQuotaRefresh {
                        miniChip("Quota", system: "gauge.with.needle", tint: DesignSystem.Colors.success)
                    }
                    Spacer()
                }
            }
            .padding(DesignSystem.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(isSelected ? primary.opacity(0.10) : DesignSystem.Colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: isSelected
                                ? [primary, primary.opacity(0.6)]
                                : [DesignSystem.Colors.border, DesignSystem.Colors.border.opacity(0.5)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: isSelected ? 1.5 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isSelected)
    }

    @ViewBuilder
    private func miniChip(_ label: String, system: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: system).font(.system(size: 8, weight: .semibold))
            Text(label).font(.system(size: 9, weight: .semibold))
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(tint.opacity(0.14))
        .foregroundStyle(tint)
        .clipShape(Capsule())
    }

    // MARK: - Auth Method Step

    @ViewBuilder
    private var authMethodStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            if let provider = selectedProvider {
                providerStripHeader(provider)
            }

            if let descriptor = selectedDescriptor {
                Text("Choose how you'll authenticate")
                    .font(DesignSystem.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text(descriptor.summary)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .padding(.bottom, DesignSystem.Spacing.xs)

                VStack(spacing: DesignSystem.Spacing.sm) {
                    ForEach(descriptor.methods) { method in
                        authMethodCard(method)
                    }
                }

                if let proxy = descriptor.proxyHint {
                    miniHintCard(symbol: "arrow.triangle.swap", text: proxy)
                }
                if let quota = descriptor.quotaHint {
                    miniHintCard(symbol: "gauge.with.needle", text: quota)
                }
            }
        }
    }

    @ViewBuilder
    private func providerStripHeader(_ provider: OpenBurnBarDaemonProviderConfiguration) -> some View {
        let primary = ProviderBrand.colorForProviderID(provider.providerID)
        HStack(spacing: DesignSystem.Spacing.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(
                        colors: [primary.opacity(0.4), primary.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 32, height: 32)
                CatalogProviderLogoView(brand: provider.brand, size: 22)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.displayName)
                    .font(DesignSystem.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(descriptor(for: provider.providerID).displayName)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            Spacer()
            Button {
                withAnimation { selectedProviderID = nil }
                navigateToStep(.provider)
            } label: {
                Text("Change")
                    .font(DesignSystem.Typography.tiny)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.blaze)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(DesignSystem.Colors.blaze.opacity(0.12))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, DesignSystem.Spacing.xs)
    }

    @ViewBuilder
    private func authMethodCard(_ method: BurnBarProviderAuthMethod) -> some View {
        let isSelected = selectedAuthMethodID == method.id
        let primary: Color = {
            if let id = selectedProviderID {
                return ProviderBrand.colorForProviderID(id)
            }
            return DesignSystem.Colors.blaze
        }()

        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                selectedAuthMethodID = method.id
                apiKeyInput = ""
                quotaProbeResult = nil
                quotaProbeError = nil
            }
        } label: {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(
                            colors: isSelected
                                ? [primary, primary.opacity(0.6)]
                                : [DesignSystem.Colors.surfaceElevated, DesignSystem.Colors.surfaceElevated],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 44, height: 44)
                    Image(systemName: method.kind.symbolName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : DesignSystem.Colors.textSecondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(method.displayName)
                        .font(DesignSystem.Typography.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                    Text(method.summary)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(2)

                    HStack(spacing: 4) {
                        if method.unlocksProxyRouting {
                            miniChip("Unlocks routing", system: "arrow.triangle.swap", tint: DesignSystem.Colors.blaze)
                        }
                        if method.unlocksQuotaRefresh {
                            miniChip("Live quota", system: "gauge.with.needle", tint: DesignSystem.Colors.success)
                        }
                        if !method.unlocksProxyRouting && !method.unlocksQuotaRefresh {
                            miniChip("Tracking only", system: "chart.bar.doc.horizontal", tint: DesignSystem.Colors.textMuted)
                        }
                    }
                }
                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(primary)
                }
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(isSelected ? primary.opacity(0.08) : DesignSystem.Colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .strokeBorder(
                        isSelected ? primary : DesignSystem.Colors.border,
                        lineWidth: isSelected ? 1.5 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isSelected)
    }

    @ViewBuilder
    private func miniHintCard(symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .padding(.top, 1)
            Text(text)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(DesignSystem.Colors.surfaceElevated.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
    }

    // MARK: - Credential Step

    @ViewBuilder
    private var credentialEntryStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            if let provider = selectedProvider {
                providerStripHeader(provider)
            }

            if let method = selectedAuthMethod {
                methodHeroCard(method)
                planLabelField
                credentialField(method)
                liveValidationView(method)
                liveQuotaProbeView()
            }
        }
    }

    @ViewBuilder
    private func methodHeroCard(_ method: BurnBarProviderAuthMethod) -> some View {
        let primary: Color = selectedProviderID
            .map { ProviderBrand.colorForProviderID($0) } ?? DesignSystem.Colors.blaze

        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [primary, primary.opacity(0.6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 32, height: 32)
                    Image(systemName: method.kind.symbolName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text(method.displayName)
                    .font(DesignSystem.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer()
                if let descriptor = selectedDescriptor, descriptor.methods.count > 1 {
                    Button {
                        navigateToStep(.auth)
                    } label: {
                        Text("Change method")
                            .font(DesignSystem.Typography.tiny)
                            .fontWeight(.semibold)
                            .foregroundStyle(DesignSystem.Colors.blaze)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(method.helperText)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let url = method.dashboardURL.flatMap(URL.init(string:)) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 10, weight: .semibold))
                        Text(method.dashboardLabel ?? "Open dashboard")
                            .font(DesignSystem.Typography.tiny)
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(primary.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
    }

    @ViewBuilder
    private var planLabelField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Plan label")
                .font(DesignSystem.Typography.tiny)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            TextField("Personal, Work, Team A…", text: $planLabel)
                .textFieldStyle(.plain)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, DesignSystem.Spacing.sm + 2)
                .background(DesignSystem.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
        }
    }

    @ViewBuilder
    private func credentialField(_ method: BurnBarProviderAuthMethod) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(method.kind == .sessionToken ? "Session token" : (method.kind == .cookie ? "Cookie payload" : "Credential"))
                    .font(DesignSystem.Typography.tiny)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Spacer()
                Button {
                    if let pasted = NSPasteboard.general.string(forType: .string) {
                        apiKeyInput = pasted
                        scheduleQuotaProbe()
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Paste")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(DesignSystem.Colors.surfaceElevated)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                Button {
                    withAnimation(.snappy) { showAPIKey.toggle() }
                } label: {
                    Image(systemName: showAPIKey ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 0) {
                Group {
                    if showAPIKey {
                        TextField(method.placeholder, text: $apiKeyInput)
                            .textFieldStyle(.plain)
                            .font(DesignSystem.Typography.monoSmall)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .onChange(of: apiKeyInput) { _, _ in scheduleQuotaProbe() }
                    } else {
                        SecureField(method.placeholder, text: $apiKeyInput)
                            .textFieldStyle(.plain)
                            .font(DesignSystem.Typography.monoSmall)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .onChange(of: apiKeyInput) { _, _ in scheduleQuotaProbe() }
                    }
                }
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, DesignSystem.Spacing.sm + 2)
            }
            .background(DesignSystem.Colors.surface)
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .strokeBorder(
                        method.validate(apiKeyInput).isWarning ? DesignSystem.Colors.warning :
                            (method.validate(apiKeyInput).isOK ? DesignSystem.Colors.success : DesignSystem.Colors.border),
                        lineWidth: method.validate(apiKeyInput).message == nil ? 0.5 : 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
            .animation(.snappy, value: apiKeyInput)
        }
    }

    @ViewBuilder
    private func liveValidationView(_ method: BurnBarProviderAuthMethod) -> some View {
        let validation = method.validate(apiKeyInput)
        if let message = validation.message {
            HStack(spacing: 4) {
                Image(systemName: validation.isWarning ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(message)
                    .font(DesignSystem.Typography.tiny)
            }
            .foregroundStyle(validation.isWarning ? DesignSystem.Colors.warning : DesignSystem.Colors.success)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background((validation.isWarning ? DesignSystem.Colors.warning : DesignSystem.Colors.success).opacity(0.10))
            .clipShape(Capsule())
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func liveQuotaProbeView() -> some View {
        if isProbingQuota {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Probing live quota…")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(DesignSystem.Colors.surfaceElevated.opacity(0.6))
            .clipShape(Capsule())
        } else if let result = quotaProbeResult {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.needle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.success)
                Text(result)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(DesignSystem.Colors.success.opacity(0.12))
            .clipShape(Capsule())
        } else if let error = quotaProbeError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.bubble.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.warning)
                Text(error)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(DesignSystem.Colors.warning.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: - Strategy Step

    @ViewBuilder
    private var strategySelectionStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            if let provider = selectedProvider {
                providerStripHeader(provider)
            }

            Text("How should this account be used?")
                .font(DesignSystem.Typography.body)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Text("OpenBurnBar fails over deterministically when a plan hits its quota or returns an auth error.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            VStack(spacing: DesignSystem.Spacing.sm) {
                ForEach(ProviderPlanStrategy.allCases) { strategy in
                    strategyCard(strategy)
                }
            }
        }
    }

    @ViewBuilder
    private func strategyCard(_ strategy: ProviderPlanStrategy) -> some View {
        let isSelected = selectedStrategy == strategy
        let primary: Color = selectedProviderID
            .map { ProviderBrand.colorForProviderID($0) } ?? DesignSystem.Colors.blaze

        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                selectedStrategy = strategy
            }
        } label: {
            HStack(spacing: DesignSystem.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(
                            colors: isSelected
                                ? [primary, primary.opacity(0.6)]
                                : [DesignSystem.Colors.surfaceElevated, DesignSystem.Colors.surfaceElevated],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 48, height: 48)
                    Image(systemName: strategy.iconName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : DesignSystem.Colors.textSecondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(strategy.displayName)
                        .font(DesignSystem.Typography.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(strategy.summary)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }

                Spacer()

                strategyDiagram(for: strategy, primary: primary, selected: isSelected)
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(isSelected ? primary.opacity(0.08) : DesignSystem.Colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .strokeBorder(
                        isSelected ? primary : DesignSystem.Colors.border,
                        lineWidth: isSelected ? 1.5 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isSelected)
    }

    @ViewBuilder
    private func strategyDiagram(for strategy: ProviderPlanStrategy, primary: Color, selected: Bool) -> some View {
        switch strategy {
        case .auto:
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(selected ? primary.opacity(0.85 - Double(index) * 0.2) : DesignSystem.Colors.textMuted.opacity(0.4))
                        .frame(width: 8, height: 16)
                }
            }
        case .preferred:
            HStack(spacing: 3) {
                Capsule().fill(selected ? primary : DesignSystem.Colors.textMuted.opacity(0.4)).frame(width: 12, height: 18)
                Capsule().fill(DesignSystem.Colors.textMuted.opacity(0.3)).frame(width: 8, height: 12)
                Capsule().fill(DesignSystem.Colors.textMuted.opacity(0.3)).frame(width: 8, height: 12)
            }
        case .backup:
            HStack(spacing: 3) {
                Capsule().fill(DesignSystem.Colors.textMuted.opacity(0.3)).frame(width: 8, height: 14)
                Capsule().fill(DesignSystem.Colors.textMuted.opacity(0.3)).frame(width: 8, height: 14)
                Capsule().fill(selected ? primary.opacity(0.7) : DesignSystem.Colors.textMuted.opacity(0.4)).frame(width: 8, height: 14)
            }
        }
    }

    // MARK: - Confirm Step

    @ViewBuilder
    private var confirmStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            if let provider = selectedProvider {
                confirmHeroCard(provider)
            }

            confirmDetailRows

            if let error = saveError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(DesignSystem.Colors.error)
                    Text(error)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.error)
                }
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, DesignSystem.Spacing.sm)
                .background(DesignSystem.Colors.error.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
            }

            Text("OpenBurnBar stores your credentials in the macOS Keychain and the daemon socket. Connect once, used everywhere.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }

    @ViewBuilder
    private func confirmHeroCard(_ provider: OpenBurnBarDaemonProviderConfiguration) -> some View {
        let primary = ProviderBrand.colorForProviderID(provider.providerID)
        let descriptor = self.descriptor(for: provider.providerID)

        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(
                            colors: [primary, primary.opacity(0.55)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 64, height: 64)
                        .shadow(color: primary.opacity(0.4), radius: 12, x: 0, y: 4)
                    CatalogProviderLogoView(brand: provider.brand, size: 40)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(provider.displayName)
                        .font(DesignSystem.Typography.title)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(planLabel.isEmpty ? "Untitled plan" : planLabel)
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    if let method = selectedAuthMethod {
                        HStack(spacing: 4) {
                            Image(systemName: method.kind.symbolName).font(.system(size: 9, weight: .semibold))
                            Text(method.displayName).font(DesignSystem.Typography.tiny).fontWeight(.semibold)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(primary.opacity(0.18))
                        .foregroundStyle(primary)
                        .clipShape(Capsule())
                    }
                }
                Spacer()
            }

            Text(descriptor.summary)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .padding(DesignSystem.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .fill(DesignSystem.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [primary.opacity(0.6), primary.opacity(0.0)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
    }

    @ViewBuilder
    private var confirmDetailRows: some View {
        VStack(spacing: 0) {
            confirmRow(symbol: "key.fill", label: "Credential", value: maskedKey)
            divider
            confirmRow(symbol: "tag.fill", label: "Label", value: planLabel.trimmingCharacters(in: .whitespacesAndNewlines))
            divider
            confirmRow(symbol: selectedStrategy.iconName, label: "Strategy", value: selectedStrategy.displayName)
            divider
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "gauge.with.needle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .frame(width: 18)
                Text("Live quota")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Spacer()
                if let result = quotaProbeResult {
                    Text(result)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.success)
                } else if isProbingQuota {
                    ProgressView().controlSize(.mini)
                } else if let method = selectedAuthMethod, !method.unlocksQuotaRefresh {
                    Text("Tracking only")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                } else {
                    Text("Will probe after save")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
            .padding(DesignSystem.Spacing.md)
        }
        .background(DesignSystem.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5)
        )
    }

    private var divider: some View {
        Rectangle()
            .fill(DesignSystem.Colors.border)
            .frame(height: 0.5)
    }

    @ViewBuilder
    private func confirmRow(symbol: String, label: String, value: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .frame(width: 18)
            Text(label)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Spacer()
            Text(value.isEmpty ? "—" : value)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .textSelection(.enabled)
        }
        .padding(DesignSystem.Spacing.md)
    }

    private var maskedKey: String {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 8 { return String(repeating: "•", count: max(trimmed.count, 4)) }
        let prefix = trimmed.prefix(4)
        let suffix = trimmed.suffix(4)
        return "\(prefix)\(String(repeating: "•", count: 6))\(suffix)"
    }

    // MARK: - Navigation Bar

    @ViewBuilder
    private var wizardNavigation: some View {
        if currentStep == .dashboard {
            HStack {
                Spacer()
                Button("Done") { onDismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignSystem.Colors.blaze)
            }
            .padding(DesignSystem.Spacing.lg)
        } else {
            HStack {
                Button {
                    navigateBack()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("Back").font(DesignSystem.Typography.body)
                    }
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Cancel") { navigateToStep(.dashboard) }
                    .buttonStyle(.bordered)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                if currentStep == .confirm {
                    Button {
                        savePlan()
                    } label: {
                        HStack(spacing: 6) {
                            if isSaving {
                                ProgressView().controlSize(.mini)
                                Text("Saving…").font(DesignSystem.Typography.body).fontWeight(.semibold)
                            } else {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12, weight: .bold))
                                Text("Save & Connect").font(DesignSystem.Typography.body).fontWeight(.semibold)
                            }
                        }
                        .padding(.horizontal, DesignSystem.Spacing.sm)
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignSystem.Colors.blaze)
                    .disabled(isSaving)
                } else {
                    Button {
                        navigateForward()
                    } label: {
                        HStack(spacing: 4) {
                            Text("Next").font(DesignSystem.Typography.body)
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        }
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
        case .dashboard: return false
        case .provider: return canProceedFromProvider
        case .auth: return canProceedFromAuth
        case .credential: return canProceedFromCredential
        case .strategy: return true
        case .confirm: return false
        }
    }

    // MARK: - Step Title / Description

    private var stepTitle: String {
        switch currentStep {
        case .dashboard:
            if let provider = activeProvider { return "\(provider.displayName) Accounts" }
            return "Provider Accounts"
        case .provider: return "Pick a provider"
        case .auth: return "Choose how to connect"
        case .credential: return "Add your credential"
        case .strategy: return "Routing strategy"
        case .confirm: return "Review & connect"
        }
    }

    private var stepDescription: String {
        switch currentStep {
        case .dashboard: return "Manage existing accounts or add a new one. Quotas refresh in the background."
        case .provider: return "Pick the provider to connect. Routing-capable providers proxy traffic; tracking providers report usage."
        case .auth: return "Some providers support multiple auth methods — pick the one that fits your account."
        case .credential: return "Paste your credential. We probe it live so you know it works before you save."
        case .strategy: return "Decide whether this account joins rotation, takes priority, or stays as a backup."
        case .confirm: return "Last look. Connect once and it'll power proxy traffic, quota, and reporting."
        }
    }

    // MARK: - Navigation Actions

    private func startAddFlow(providerID: String) {
        let descriptor = self.descriptor(for: providerID)
        selectedProviderID = providerID
        selectedAuthMethodID = descriptor.primaryMethod.id
        planLabel = ""
        apiKeyInput = ""
        showAPIKey = false
        quotaProbeResult = nil
        quotaProbeError = nil
        quotaProbePercent = nil
        selectedStrategy = .auto
        saveError = nil

        if descriptor.methods.count > 1 {
            navigateToStep(.auth)
        } else {
            navigateToStep(.credential)
        }
    }

    private func navigateForward() {
        let nextStep: ProviderPlanWizardStep
        switch currentStep {
        case .provider:
            let descriptor = selectedDescriptor ?? BurnBarProviderAuthRegistry.defaultDescriptor(providerID: "", displayName: "")
            nextStep = descriptor.methods.count > 1 ? .auth : .credential
            if descriptor.methods.count == 1 {
                selectedAuthMethodID = descriptor.primaryMethod.id
            }
        case .auth:
            nextStep = .credential
        case .credential:
            nextStep = .strategy
        case .strategy:
            nextStep = .confirm
        case .dashboard, .confirm:
            return
        }

        primeStepIfNeeded(nextStep)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            currentStep = nextStep
        }
    }

    private func primeStepIfNeeded(_ step: ProviderPlanWizardStep) {
        if step == .credential, planLabel.isEmpty {
            let provider = selectedProvider ?? activeProvider
            if let provider {
                let count = provider.credentialSlots.count
                planLabel = count == 0 ? "Default" : "Plan \(count + 1)"
            }
        }
    }

    private func navigateBack() {
        let previous: ProviderPlanWizardStep
        switch currentStep {
        case .auth: previous = .provider
        case .credential:
            previous = (selectedDescriptor?.methods.count ?? 0) > 1 ? .auth : .provider
        case .strategy: previous = .credential
        case .confirm: previous = .strategy
        case .provider, .dashboard: return
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            currentStep = previous
        }
    }

    private func navigateToStep(_ step: ProviderPlanWizardStep) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            currentStep = step
        }
    }

    // MARK: - Quota Probe

    private func scheduleQuotaProbe() {
        quotaProbeTask?.cancel()
        quotaProbeResult = nil
        quotaProbeError = nil
        quotaProbePercent = nil

        let trimmedKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty,
              let providerID = selectedProviderID,
              let method = selectedAuthMethod,
              method.unlocksQuotaRefresh,
              let quotaProvider = quotaProbeProvider(for: providerID) else {
            return
        }

        quotaProbeTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }

            await MainActor.run { isProbingQuota = true }

            do {
                let snapshot = try await ProviderQuotaService.shared.fetchSnapshot(
                    for: quotaProvider,
                    apiKeyOverride: trimmedKey
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    isProbingQuota = false
                    if let bucket = snapshot.primaryDisplayableBucket {
                        let pct = bucket.remainingPercent
                        quotaProbePercent = pct
                        if let pct {
                            let label = bucket.label.isEmpty ? "" : " (\(bucket.label))"
                            quotaProbeResult = "\(Int(pct.rounded()))% remaining\(label)"
                        } else {
                            quotaProbeResult = bucket.remainingText
                        }
                    } else if snapshot.confidence == .unavailable {
                        quotaProbeError = snapshot.statusMessage ?? "Live quota probe didn't return data."
                    } else {
                        quotaProbeResult = "Connected — quota will populate after first use."
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    isProbingQuota = false
                    quotaProbeError = "Probe failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Save & Delete

    private func savePlan() {
        guard let providerID = selectedProviderID ?? activeProviderID,
              let method = selectedAuthMethod else { return }

        let label = planLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, !apiKey.isEmpty else { return }

        isSaving = true
        saveError = nil

        Task {
            await daemonManager.addProviderCredentialSlot(
                providerID: providerID,
                label: label,
                apiKey: apiKey
            )

            if let mirrorAccount = method.storage.mirrorAccountIdentifier {
                await MainActor.run {
                    do {
                        try ProviderAPIKeyStore.shared.setAPIKey(apiKey, for: mirrorAccount)
                    } catch {
                        AppLogger.dataStore.silentFailure(
                            "ProviderPlanWizardView: failed to mirror credential to keychain",
                            error: error
                        )
                    }
                }
            }

            switch selectedStrategy {
            case .auto:
                break
            case .preferred:
                if let updated = daemonManager.providerConfigurations
                    .first(where: { $0.providerID == providerID }),
                   let newSlot = updated.credentialSlots.last {
                    await daemonManager.setPreferredProviderCredentialSlot(
                        providerID: providerID,
                        slotID: newSlot.slotID
                    )
                }
            case .backup:
                if let updated = daemonManager.providerConfigurations
                    .first(where: { $0.providerID == providerID }),
                   let newSlot = updated.credentialSlots.last {
                    await daemonManager.updateProviderCredentialSlot(
                        providerID: providerID,
                        slotID: newSlot.slotID,
                        isEnabled: false
                    )
                }
            }

            await daemonManager.refreshProviderCredentialSlotQuotas(providerID: providerID)

            await MainActor.run {
                isSaving = false
                activeProviderID = providerID
                navigateToStep(.dashboard)
            }
        }
    }

    private func deleteSlot(_ target: SlotDeleteTarget) {
        Task {
            await daemonManager.removeProviderCredentialSlot(
                providerID: target.providerID,
                slotID: target.slotID
            )
            await MainActor.run { slotToDelete = nil }
        }
    }
}

// MARK: - Provider Configuration Helpers

private extension OpenBurnBarDaemonProviderConfiguration {
    var hasRoutingCapability: Bool {
        let providerID = self.providerID.lowercased()
        switch providerID {
        case "minimax", "zai", "z-ai", "ollama", "mlx",
             "openai", "xai", "deepseek", "mistral", "alibaba", "qwen", "meta":
            return true
        default:
            // Honor catalog routing capability when available.
            if let catalog = BurnBarCatalogLoader.bundledCatalog.provider(id: self.providerID) {
                return catalog.capabilities.contains(.routing)
            }
            return false
        }
    }
}

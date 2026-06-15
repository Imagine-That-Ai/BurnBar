import AppKit
import SwiftUI
import OpenBurnBarCore

// MARK: - Plan Strategy

// Navigation bar, step title/description, and navigation actions.
// Extracted from ProviderPlanWizardView.swift (god-type decomposition) — same module, same isolation, verbatim.

extension ProviderPlanWizardView {

    var divider: some View {
        Rectangle()
            .fill(DesignSystem.Colors.border)
            .frame(height: 0.5)
    }

    @ViewBuilder
    func confirmRow(symbol: String, label: String, value: String) -> some View {
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

    var maskedKey: String {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 8 { return String(repeating: "•", count: max(trimmed.count, 4)) }
        let prefix = trimmed.prefix(4)
        let suffix = trimmed.suffix(4)
        return "\(prefix)\(String(repeating: "•", count: 6))\(suffix)"
    }

    @ViewBuilder
    var wizardNavigation: some View {
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

    var canProceedFromCurrentStep: Bool {
        switch currentStep {
        case .dashboard: return false
        case .provider: return canProceedFromProvider
        case .auth: return canProceedFromAuth
        case .credential: return canProceedFromCredential
        case .strategy: return true
        case .confirm: return false
        }
    }

    var stepTitle: String {
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

    var stepDescription: String {
        switch currentStep {
        case .dashboard: return "Manage existing accounts or add a new one. Quotas refresh in the background."
        case .provider: return "Pick the provider to connect. Routing-capable providers proxy traffic; tracking providers report usage."
        case .auth: return "Some providers support multiple auth methods — pick the one that fits your account."
        case .credential: return "Paste your credential. We probe it live so you know it works before you save."
        case .strategy: return "Decide whether this account joins rotation, takes priority, or stays as a backup."
        case .confirm: return "Last look. Connect once and it'll power proxy traffic, quota, and reporting."
        }
    }

    func startAddFlow(providerID: String) {
        let descriptor = self.descriptor(for: providerID)
        selectedProviderID = providerID
        selectedAuthMethodID = descriptor.primaryMethod.id
        planLabel = ""
        apiKeyInput = ""
        credentialStorageOverride = nil
        credentialStorageOverrideVisibleToken = nil
        editingCredentialSlot = nil
        showAPIKey = false
        quotaProbeResult = nil
        quotaProbeError = nil
        quotaProbePercent = nil
        externalAuthInfo = nil
        externalAuthMessage = nil
        externalAccountActionMessage = nil
        isOpeningExternalLogin = false
        isAddingExternalAccount = false
        selectedStrategy = .auto
        saveError = nil
        localMimoRegion = daemonManager.settingsManager.mimoTokenPlanRegion
        localMimoTier = daemonManager.settingsManager.mimoTokenPlanTier ?? .standard
        localMimoBillingCycle = daemonManager.settingsManager.mimoTokenPlanBillingCycle

        if descriptor.methods.count > 1 {
            navigateToStep(.auth)
        } else {
            navigateToStep(.credential)
        }
    }

    func navigateForward() {
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
            if let method = selectedAuthMethod, !method.storage.usesDaemonSlot {
                if method.usesExternalLogin {
                    activeProviderID = selectedProviderID ?? activeProviderID
                    nextStep = .dashboard
                } else {
                    nextStep = .confirm
                }
            } else {
                nextStep = .strategy
            }
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
}

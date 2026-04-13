import SwiftUI
import OpenBurnBarCore

struct ProvidersSettingsView: View {
    @Bindable var settingsManager: SettingsManager
    @Bindable var daemonManager: OpenBurnBarDaemonManager

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

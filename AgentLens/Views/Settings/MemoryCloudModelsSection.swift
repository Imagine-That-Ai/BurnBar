import OpenBurnBarKernel
import SwiftUI

// MARK: - Memory Pro: cloud models for memory (Settings → Privacy)

/// Opt-in switch, provider consent rows with their retention posture, the
/// no-retention-only guard, a daily cap, and a status line that says who
/// receives what. Pro only: below the tier the content sits behind
/// `LockedFeatureVeil` and the Data Vault unlock sheet (the catalog's
/// agent-memory feature, `cloud_pro`).
struct MemoryCloudModelsSection: View {
    @Bindable var settingsManager: SettingsManager
    @ObservedObject private var entitlement = MacCloudEntitlementStore.shared
    @State private var showConsentSheet = false
    @State private var showUnlockSheet = false
    @State private var availability = MemoryCloudProviderAvailability.Snapshot()

    private static let gatedFeature = GatedFeature.gatedFeature(.dataVault)

    private var isUnlocked: Bool {
        entitlement.cloudTier.satisfies(Self.gatedFeature.requiredTier)
    }

    /// Enabling for the first time routes through the consent sheet, which
    /// writes the settings itself; later flips write directly.
    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { settingsManager.memoryCloudModelsOptIn },
            set: { isOn in
                if isOn, !settingsManager.memoryCloudModelsConsentShown {
                    showConsentSheet = true
                    return
                }
                settingsManager.memoryCloudModelsOptIn = isOn
                track("memory_cloud_models", .bool(isOn))
            }
        )
    }

    var body: some View {
        Group {
            if isUnlocked {
                content
            } else {
                LockedFeatureVeil(
                    headline: "Cloud models for memory",
                    detail: "Pro. Frontier models on your own subscription or keys; BurnBar never receives your memories.",
                    ctaLabel: "See Pro",
                    icon: "brain",
                    action: { showUnlockSheet = true },
                    background: { content.disabled(true) }
                )
            }
        }
        .settingsAnchor(SettingsAnchor.indexingMemoryCloudModels)
        .sheet(isPresented: $showConsentSheet) {
            MemoryCloudModelsConsentSheet(settingsManager: settingsManager) {
                showConsentSheet = false
            }
        }
        .sheet(isPresented: $showUnlockSheet) {
            FeatureUnlockSheet(feature: Self.gatedFeature)
        }
        .task { await refreshAvailability() }
        .onChange(of: settingsManager.cliAssistantAllowed) { _, _ in
            Task { await refreshAvailability() }
        }
        .onChange(of: settingsManager.memoryCloudModelsRequireNoRetention) { _, newValue in
            track("memory_cloud_no_retention_only", .bool(newValue))
        }
        .onChange(of: settingsManager.memoryCloudModelsDailyCapUSD) { _, newValue in
            track("memory_cloud_daily_cap_usd", .string(String(format: "%.2f", newValue)))
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            SettingsToggle(
                title: "Cloud models for memory",
                subtitle: "Pro. Uses your own subscription or keys. BurnBar never receives your memories.",
                isOn: toggleBinding
            )

            if !settingsManager.memoryCloudModelsRemoteConfigEnabled {
                notice("Cloud models for memory are temporarily disabled by your admin. Local memory is unaffected.")
            }

            if settingsManager.memoryCloudModelsOptIn {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    ForEach(MemoryCloudProviderID.allCases) { provider in
                        providerRow(provider)
                    }
                }

                SettingsToggle(
                    title: "Only providers that promise no retention",
                    subtitle: "When on, the daemon refuses routes whose provider may keep your text.",
                    isOn: $settingsManager.memoryCloudModelsRequireNoRetention
                )

                HStack {
                    Text("Daily cap")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Spacer()
                    Stepper(
                        String(format: "$%.2f / day", settingsManager.memoryCloudModelsDailyCapUSD),
                        value: $settingsManager.memoryCloudModelsDailyCapUSD,
                        in: 0.5...50.0,
                        step: 0.5
                    )
                    .frame(maxWidth: 220)
                }

                Text(statusText)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func providerRow(_ provider: MemoryCloudProviderID) -> some View {
        let reason = availability.reason(for: provider)
        return VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: providerBinding(provider)) {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Text(provider.displayName)
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    retentionChip(provider)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(reason != nil)

            Text(reason ?? provider.requirementDescription)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(reason == nil ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.warning)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
        }
    }

    private func providerBinding(_ provider: MemoryCloudProviderID) -> Binding<Bool> {
        Binding(
            get: { settingsManager.memoryCloudModelsConsentedProviders.contains(provider) },
            set: { isOn in
                var consented = settingsManager.memoryCloudModelsConsentedProviders
                if isOn {
                    if !consented.contains(provider) { consented.append(provider) }
                } else {
                    consented.removeAll { $0 == provider }
                }
                settingsManager.memoryCloudModelsConsentedProviders = consented
                track("memory_cloud_provider_\(provider.rawValue)", .bool(isOn))
            }
        )
    }

    private func retentionChip(_ provider: MemoryCloudProviderID) -> some View {
        let tint: Color = switch provider.retention {
        case .deny: DesignSystem.Colors.success
        case .localQuota: DesignSystem.Colors.whimsy
        case .providerPolicy: DesignSystem.Colors.warning
        }
        return Text(provider.retentionLabel)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14))
            .foregroundStyle(tint)
            .clipShape(Capsule())
    }

    private var statusText: String {
        let consented = settingsManager.memoryCloudModelsConsentedProviders
        let providers = consented.isEmpty ? "none yet" : consented.map(\.displayName).joined(separator: ", ")
        let retention = consented.isEmpty
            ? "—"
            : Array(Set(consented.map(\.retentionLabel))).sorted().joined(separator: ", ")
        return "Blind: BurnBar never receives memory data. Providers: \(providers). Retention: \(retention)."
    }

    private func notice(_ text: String) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(DesignSystem.Colors.warning)
                .padding(.top, 2)
            Text(text)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, DesignSystem.Spacing.xs)
        .background(DesignSystem.Colors.warning.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
    }

    private func track(_ key: String, _ value: AnalyticsValue) {
        Analytics.shared.track(.settingsChanged, ["setting_key": .string(key), "new_value": value])
    }

    private func refreshAvailability() async {
        availability = await MemoryCloudProviderAvailability.current(
            settingsManager: settingsManager,
            daemonManager: .shared
        )
    }
}

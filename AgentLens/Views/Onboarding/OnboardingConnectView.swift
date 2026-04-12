import SwiftUI

struct OnboardingConnectView: View {
    let selectedProviders: Set<AgentProvider>
    let settingsManager: SettingsManager

    private var detection: [AgentProvider: Bool] {
        settingsManager.detectAvailableProviders()
    }

    private var readyProviders: [AgentProvider] {
        selectedProviders.sorted { $0.displayName < $1.displayName }
            .filter { detection[$0] == true }
    }

    private var needsAttentionProviders: [AgentProvider] {
        selectedProviders.sorted { $0.displayName < $1.displayName }
            .filter { detection[$0] != true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Connection status")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("OpenBurnBar reads agent logs from your local filesystem. Here's what it can see for your selected agents.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    if !readyProviders.isEmpty {
                        providerSection(title: "Ready", providers: readyProviders, ready: true)
                    }

                    if !needsAttentionProviders.isEmpty {
                        providerSection(title: "Needs attention", providers: needsAttentionProviders, ready: false)
                    }
                }
            }

            if needsAttentionProviders.isEmpty {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DesignSystem.Colors.success)
                    Text("All selected agents have logs on this Mac.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
            } else {
                Text("Missing paths are fine \u{2014} those agents may store logs elsewhere, or you haven't used them on this Mac yet. You can configure paths later in Settings.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func providerSection(title: String, providers: [AgentProvider], ready: Bool) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text(title)
                .font(DesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            VStack(spacing: DesignSystem.Spacing.xs) {
                ForEach(providers) { provider in
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(ready ? DesignSystem.Colors.success : DesignSystem.Colors.warning)

                        ProviderLogoView(provider: provider, size: 16, useFallbackColor: true)

                        Text(provider.displayName)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)

                        Spacer()

                        Text(provider.logDirectory)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.vertical, DesignSystem.Spacing.xs)
                    .padding(.horizontal, DesignSystem.Spacing.sm)
                    .background {
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                            .fill(DesignSystem.Colors.surface)
                    }
                }
            }
        }
    }
}

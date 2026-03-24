import SwiftUI

struct OnboardingView: View {
    let dataStore: DataStore
    var aggregator: UsageAggregator?
    let settingsManager: SettingsManager
    let onDismiss: () -> Void
    let onOpenSettings: () -> Void

    enum Step {
        case detect
        case scanning
        case celebrate
    }

    @State private var step: Step = .detect
    @AppStorage("hasOnboarded") private var hasOnboarded = false

    private var detection: [AgentProvider: Bool] {
        settingsManager.detectAvailableProviders()
    }

    private var anyDetected: Bool {
        detection.values.contains(true)
    }

    private var allFailed: Bool {
        guard let agg = aggregator else { return false }
        let relevant = agg.parserHealth.filter { $0.key.supportLevel != .unsupported }
        guard !relevant.isEmpty else { return false }
        return relevant.values.allSatisfy {
            if case .failed = $0 { return true }
            return false
        }
    }

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            switch step {
            case .detect:
                detectStep
            case .scanning:
                scanningStep
            case .celebrate:
                celebrateStep
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(width: 340)
        .background(DesignSystem.Colors.background)
        .onChange(of: aggregator?.isRefreshing) { _, new in
            guard step == .scanning, new == false else { return }
            withAnimation(DesignSystem.Animation.standard) {
                step = .celebrate
            }
        }
    }

    private var detectStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(spacing: DesignSystem.Spacing.md) {
                AppLogoView(size: 44)
                Text("Welcome to BurnBar")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }

            Text("We look for agent logs in default folders. Here's what we can see on this Mac:")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    ForEach(AgentProvider.allCases) { provider in
                        HStack {
                            Image(systemName: (detection[provider] == true) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle((detection[provider] == true) ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted)
                            Text(provider.displayName)
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                            Spacer()
                        }
                    }
                }
            }
            .frame(maxHeight: 220)

            if !anyDetected {
                Text("Check Settings to configure log paths if you store logs elsewhere.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.warning)
            }

            HStack {
                Button("Skip") {
                    hasOnboarded = true
                    onDismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

                Spacer()

                if !anyDetected {
                    Button("Settings") {
                        onOpenSettings()
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button(anyDetected ? "Scan" : "Try scan anyway") {
                    withAnimation(DesignSystem.Animation.standard) { step = .scanning }
                    Task { await aggregator?.refreshAll() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var scanningStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("Scanning logs…")
                .font(DesignSystem.Typography.headline)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            if allFailed {
                Text("We couldn’t read some log locations. Grant file access or adjust paths in Settings.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.warning)
            }

            ForEach(AgentProvider.allCases) { provider in
                HStack {
                    parserHealthView(for: provider)
                    Text(provider.displayName)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Spacer()
                }
            }

            if aggregator?.isRefreshing == false {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func parserHealthView(for provider: AgentProvider) -> some View {
        let health = aggregator?.parserHealth[provider]
        switch health {
        case .healthy(let n):
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(DesignSystem.Colors.success)
                .help("\(n) sessions")
        case .degraded(let n, let error):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DesignSystem.Colors.warning)
                .help("\(n) sessions parsed with warnings: \(error)")
        case .empty:
            Image(systemName: "minus.circle")
                .foregroundStyle(DesignSystem.Colors.textMuted)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(DesignSystem.Colors.error)
        case .notConfigured, .none:
            Image(systemName: "circle")
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }

    private var celebrateStep: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(DesignSystem.Colors.success)

            let n = dataStore.usages.count
            let providers = Set(dataStore.usages.map(\.provider)).count
            Text("Found \(n) session\(n == 1 ? "" : "s") across \(providers) provider\(providers == 1 ? "" : "s"). You're all set.")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .multilineTextAlignment(.center)

            Button("Let's go") {
                hasOnboarded = true
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
    }
}

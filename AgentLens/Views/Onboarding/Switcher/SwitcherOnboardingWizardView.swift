import SwiftUI
import OpenBurnBarCore

// MARK: - Wizard Step

enum SwitcherOnboardingStep: Int, CaseIterable {
    case welcome   // Welcome + background scan
    case scanAdd   // Identity cards with one-click add
    case done      // Success with verification

    var progressFraction: Double {
        Double(rawValue) / Double(Self.allCases.count - 1)
    }

    var stepLabel: String {
        switch self {
        case .welcome: return "Welcome"
        case .scanAdd: return "Add"
        case .done: return "Done"
        }
    }
}

// MARK: - Main Wizard View

struct SwitcherOnboardingWizardView: View {
    let dataStore: DataStore
    let settingsManager: SettingsManager
    let onDismiss: () -> Void
    let onOpenSettings: () -> Void

    @AppStorage("hasSwitcherOnboarded") private var hasSwitcherOnboarded = false

    @State private var currentStep: SwitcherOnboardingStep = .welcome
    @State private var navigationDirection: Edge = .trailing
    @StateObject private var discoveryService = SwitcherDiscoveryService()

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            progressBar
            stepContent
                .padding(DesignSystem.Spacing.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(width: 520, height: 620)
        .background(DesignSystem.Colors.background)
        .preferredColorScheme(settingsManager.preferredSwiftUIColorScheme)
        .onAppear {
            Task {
                await discoveryService.scan(dataStore: dataStore)
            }
        }
        .onChange(of: discoveryService.isScanning) { _, isScanning in
            guard !isScanning, currentStep == .welcome else { return }

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !discoveryService.isScanning, currentStep == .welcome else { return }
                navigateForward()
            }
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
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

            HStack(spacing: DesignSystem.Spacing.xxs) {
                ForEach(SwitcherOnboardingStep.allCases, id: \.rawValue) { step in
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
    }

    private func stepColor(for step: SwitcherOnboardingStep) -> Color {
        if step.rawValue < currentStep.rawValue {
            return DesignSystem.Colors.success
        } else if step == currentStep {
            return DesignSystem.Colors.amber
        } else {
            return DesignSystem.Colors.border
        }
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(DesignSystem.Colors.borderSubtle)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(DesignSystem.Colors.primaryGradient)
                    .frame(width: geo.size.width * currentStep.progressFraction)
                    .animation(DesignSystem.Animation.gentle, value: currentStep)
            }
        }
        .frame(height: 3)
    }

    // MARK: - Step Content

    @ViewBuilder
    private var stepContent: some View {
        Group {
            switch currentStep {
            case .welcome:
                SwitcherOnboardingWelcomeStep(
                    discoveryService: discoveryService
                )
            case .scanAdd:
                SwitcherOnboardingScanAddStep(
                    discoveryService: discoveryService,
                    dataStore: dataStore
                )
            case .done:
                SwitcherOnboardingDoneStep(
                    addedCount: discoveryService.discoveredIdentities.filter { $0.isAdded }.count,
                    verifiedCount: discoveryService.discoveredIdentities.filter { $0.isVerified }.count,
                    identities: discoveryService.discoveredIdentities.filter { $0.isAdded },
                    onOpenSettings: {
                        finalize()
                        onOpenSettings()
                    },
                    onDismiss: {
                        finalize()
                        onDismiss()
                    }
                )
            }
        }
        .transition(.asymmetric(
            insertion: .move(edge: navigationDirection).combined(with: .opacity),
            removal: .move(edge: navigationDirection == .trailing ? .leading : .trailing).combined(with: .opacity)
        ))
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        if currentStep != .done {
            HStack {
                if currentStep != .welcome {
                    Button("Back") {
                        navigateBack()
                    }
                    .buttonStyle(.plain)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                }

                Spacer()

                Button("Skip") {
                    finalize()
                    onDismiss()
                }
                .buttonStyle(.plain)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)

                Button(continueLabel) {
                    navigateForward()
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.amber)
                .font(DesignSystem.Typography.caption)
                .disabled(!canContinue)
            }
            .padding(.horizontal, DesignSystem.Spacing.xl)
            .padding(.bottom, DesignSystem.Spacing.lg)
        }
    }

    private var continueLabel: String {
        switch currentStep {
        case .welcome:
            return discoveryService.isScanning ? "Scanning..." : "Continue"
        case .scanAdd:
            let added = discoveryService.discoveredIdentities.filter { $0.isAdded }.count
            return added > 0 ? "Continue with \(added) profile(s)" : "Add at least one profile"
        case .done:
            return ""
        }
    }

    private var canContinue: Bool {
        switch currentStep {
        case .welcome:
            return !discoveryService.isScanning
        case .scanAdd:
            return discoveryService.discoveredIdentities.contains(where: { $0.isAdded })
        case .done:
            return true
        }
    }

    // MARK: - Navigation

    private func navigateForward() {
        guard let next = SwitcherOnboardingStep(rawValue: currentStep.rawValue + 1) else { return }
        navigationDirection = .trailing
        withAnimation(DesignSystem.Animation.gentle) {
            currentStep = next
        }
    }

    private func navigateBack() {
        guard let prev = SwitcherOnboardingStep(rawValue: currentStep.rawValue - 1) else { return }
        navigationDirection = .leading
        withAnimation(DesignSystem.Animation.gentle) {
            currentStep = prev
        }
    }

    // MARK: - Finalize

    private func finalize() {
        settingsManager.switcherOnboardingCompleted = true
        hasSwitcherOnboarded = true
    }
}

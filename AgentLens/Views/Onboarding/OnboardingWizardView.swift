import SwiftUI

// MARK: - Wizard Step

enum OnboardingWizardStep: Int, CaseIterable {
    case providers
    case connect
    case scan
    case tour
    case chatEngine
    case complete

    var progressFraction: Double {
        Double(rawValue) / Double(Self.allCases.count - 1)
    }
}

// MARK: - Wizard View

struct OnboardingWizardView: View {
    let dataStore: DataStore
    var aggregator: UsageAggregator?
    let settingsManager: SettingsManager
    var chatController: ChatSessionController?
    let onDismiss: () -> Void
    let onOpenDashboard: () -> Void

    @AppStorage("hasOnboarded") private var hasOnboarded = false

    @State private var currentStep: OnboardingWizardStep = .providers
    @State private var selectedProviders: Set<AgentProvider> = []
    @State private var enabledBackends: Set<ChatBackendID> = []
    @State private var defaultEngine: ChatBackendID = .codex
    @State private var tourPage: Int = 0
    @State private var navigationDirection: Edge = .trailing

    var body: some View {
        VStack(spacing: 0) {
            progressBar
            stepContent
                .padding(DesignSystem.Spacing.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(width: 520, height: 620)
        .background(DesignSystem.Colors.background)
        .openBurnBarPreferredColorScheme(settingsManager.preferredSwiftUIColorScheme)
        .onAppear {
            // Pre-select detected providers
            let detection = settingsManager.detectAvailableProviders()
            for (provider, found) in detection where found {
                selectedProviders.insert(provider)
            }
            // Pre-load chat backend state
            let existing = settingsManager.enabledChatBackends
            if !existing.isEmpty {
                enabledBackends = Set(existing)
            }
            if let current = chatController?.chatBackend {
                defaultEngine = current
            }
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
            case .providers:
                OnboardingProviderCloudView(
                    selectedProviders: $selectedProviders,
                    detectedProviders: settingsManager.detectAvailableProviders()
                )
            case .connect:
                OnboardingConnectView(
                    selectedProviders: selectedProviders,
                    settingsManager: settingsManager
                )
            case .scan:
                OnboardingScanView(
                    selectedProviders: selectedProviders,
                    aggregator: aggregator
                )
            case .tour:
                OnboardingTourView(currentPage: $tourPage)
            case .chatEngine:
                OnboardingChatEngineView(
                    enabledBackends: $enabledBackends,
                    defaultEngine: $defaultEngine,
                    settingsManager: settingsManager,
                    chatController: chatController
                )
            case .complete:
                OnboardingCompleteView(
                    dataStore: dataStore,
                    selectedProviders: selectedProviders,
                    onOpenDashboard: {
                        finalize()
                        onOpenDashboard()
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
        if currentStep != .complete {
            HStack {
                if currentStep != .providers {
                    Button("Back") {
                        navigateBack()
                    }
                    .buttonStyle(.plain)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                }

                Spacer()

                if currentStep != .scan {
                    Button("Skip") {
                        finalize()
                        onDismiss()
                    }
                    .buttonStyle(.plain)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Button(continueLabel) {
                    navigateForward()
                }
                .buttonStyle(.borderedProminent)
                .font(DesignSystem.Typography.caption)
                .disabled(!canContinue)
            }
            .padding(.horizontal, DesignSystem.Spacing.xl)
            .padding(.bottom, DesignSystem.Spacing.lg)
        }
    }

    private var continueLabel: String {
        switch currentStep {
        case .providers: return "Continue"
        case .connect: return "Scan"
        case .scan: return aggregator?.isRefreshing == true ? "Scanning\u{2026}" : "Continue"
        case .tour: return tourPage < 3 ? "Next" : "Continue"
        case .chatEngine: return "Finish"
        case .complete: return ""
        }
    }

    private var canContinue: Bool {
        switch currentStep {
        case .providers: return !selectedProviders.isEmpty
        case .scan: return aggregator?.isRefreshing != true
        case .tour: return true
        case .chatEngine: return true
        case .connect: return true
        case .complete: return true
        }
    }

    // MARK: - Navigation

    private func navigateForward() {
        // Tour step has sub-pagination
        if currentStep == .tour, tourPage < 3 {
            withAnimation(DesignSystem.Animation.standard) {
                tourPage += 1
            }
            return
        }

        guard let nextIndex = OnboardingWizardStep(rawValue: currentStep.rawValue + 1) else { return }
        navigationDirection = .trailing
        withAnimation(DesignSystem.Animation.gentle) {
            currentStep = nextIndex
        }
    }

    private func navigateBack() {
        // Tour step has sub-pagination
        if currentStep == .tour, tourPage > 0 {
            withAnimation(DesignSystem.Animation.standard) {
                tourPage -= 1
            }
            return
        }

        guard let prevIndex = OnboardingWizardStep(rawValue: currentStep.rawValue - 1) else { return }
        navigationDirection = .leading
        withAnimation(DesignSystem.Animation.gentle) {
            currentStep = prevIndex
        }
    }

    private func finalize() {
        // Persist selected providers
        settingsManager.selectedOnboardingProviders = selectedProviders

        // Persist chat engine choices
        let ordered = ChatBackendID.allCases.filter { enabledBackends.contains($0) }
        if !ordered.isEmpty {
            settingsManager.setEnabledChatBackends(ordered)
            let start = ordered.contains(defaultEngine) ? defaultEngine : ordered[0]
            chatController?.chatBackend = start
        }
        settingsManager.chatBackendOnboardingCompleted = true
        hasOnboarded = true
    }
}

import SwiftUI
import OpenBurnBarCore

// MARK: - iPad Onboarding Wizard (Placeholder)

/// Full onboarding wizard for iPad. Skips provider scan (no log access).
/// Steps: Welcome → Cloud Connect → Hermes Setup → Complete.
struct iPadOnboardingWizardView: View {
    @Binding var isPresented: Bool
    @State private var currentStep: OnboardingStep = .welcome
    @State private var authStore = AuthStore()

    enum OnboardingStep: CaseIterable {
        case welcome
        case cloudConnect
        case hermesSetup
        case complete

        var index: Int {
            OnboardingStep.allCases.firstIndex(of: self) ?? 0
        }
    }

    var body: some View {
        ZStack {
            MobileTheme.Colors.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                stepContent
                    .padding(.horizontal, MobileTheme.Spacing.xxxl)
                Spacer()
                bottomControls
                    .padding(.horizontal, MobileTheme.Spacing.xxl)
                    .padding(.bottom, MobileTheme.Spacing.xxl)
            }
        }
    }

    // MARK: - Step Content

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .welcome:
            welcomeStep
        case .cloudConnect:
            cloudConnectStep
        case .hermesSetup:
            hermesSetupStep
        case .complete:
            completeStep
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: MobileTheme.Spacing.xl) {
            ZStack {
                Circle()
                    .fill(MobileTheme.primaryGradient)
                    .frame(width: 120, height: 120)
                Image(systemName: "flame.fill")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(.white)
            }
            .staggeredEntrance(delay: 0)

            Text("Welcome to OpenBurnBar")
                .font(MobileTheme.Typography.display)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .multilineTextAlignment(.center)
                .staggeredEntrance(delay: 0.05)

            Text("Your AI coding agent burn tracker, now on iPad.")
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .staggeredEntrance(delay: 0.10)
        }
    }

    private var cloudConnectStep: some View {
        VStack(spacing: MobileTheme.Spacing.xl) {
            ZStack {
                Circle()
                    .fill(MobileTheme.whimsyGradient)
                    .frame(width: 80, height: 80)
                Image(systemName: "icloud.and.arrow.up.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .staggeredEntrance(delay: 0)

            Text("Connect to the Cloud")
                .font(MobileTheme.Typography.title)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .staggeredEntrance(delay: 0.05)

            if authStore.state.isSignedIn {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(MobileTheme.Colors.success)
                    Text("Connected as \(authStore.currentIdentity?.email ?? "User")")
                        .font(MobileTheme.Typography.body)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                }
                .staggeredEntrance(delay: 0.10)
            } else {
                Text("Sign in to sync your burn data from your Mac.")
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .staggeredEntrance(delay: 0.10)
            }
        }
    }

    private var hermesSetupStep: some View {
        VStack(spacing: MobileTheme.Spacing.xl) {
            ZStack {
                Circle()
                    .fill(MobileTheme.mercuryGradient)
                    .frame(width: 80, height: 80)
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .staggeredEntrance(delay: 0)

            Text("Meet Hermes")
                .font(MobileTheme.Typography.title)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .staggeredEntrance(delay: 0.05)

            Text("Hermes is your AI assistant for burn analysis. It runs on your Mac. On iPad, connect to your Mac's Hermes instance at localhost:8642 when on the same Wi-Fi network.")
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .staggeredEntrance(delay: 0.10)

            HStack(spacing: MobileTheme.Spacing.lg) {
                Image(systemName: "macpro.gen3")
                    .font(.system(size: 32))
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                Image(systemName: "wifi")
                    .font(.system(size: 20))
                    .foregroundStyle(MobileTheme.Colors.accent)
                Image(systemName: "ipad.landscape")
                    .font(.system(size: 32))
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
            .staggeredEntrance(delay: 0.15)
        }
    }

    private var completeStep: some View {
        VStack(spacing: MobileTheme.Spacing.xl) {
            ZStack {
                Circle()
                    .fill(MobileTheme.Colors.success.opacity(0.15))
                    .frame(width: 100, height: 100)
                Image(systemName: "checkmark")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(MobileTheme.Colors.success)
            }
            .scaleEffect(1.0)
            .staggeredEntrance(delay: 0)

            Text("You're all set!")
                .font(MobileTheme.Typography.display)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .staggeredEntrance(delay: 0.05)

            Text("Your Mac will sync usage data here automatically.")
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .staggeredEntrance(delay: 0.10)
        }
    }

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        VStack(spacing: MobileTheme.Spacing.lg) {
            // Progress dots
            HStack(spacing: 8) {
                ForEach(0..<OnboardingStep.allCases.count, id: \.self) { index in
                    Circle()
                        .fill(index == currentStep.index ? MobileTheme.ember : MobileTheme.Colors.border)
                        .frame(width: 8, height: 8)
                        .animation(.spring(duration: 0.3), value: currentStep.index)
                }
            }

            // Buttons
            HStack(spacing: MobileTheme.Spacing.md) {
                if currentStep != .complete {
                    Button("Skip for now") {
                        isPresented = false
                    }
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                }

                Spacer()

                if currentStep != .welcome {
                    Button("Back") {
                        if let previous = OnboardingStep.allCases[safe: currentStep.index - 1] {
                            withAnimation(MobileTheme.Animation.standard) {
                                currentStep = previous
                            }
                        }
                    }
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                }

                Button(action: advanceStep) {
                    Text(buttonTitle)
                        .font(MobileTheme.Typography.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, MobileTheme.Spacing.xl)
                        .padding(.vertical, MobileTheme.Spacing.md)
                        .background(
                            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                                .fill(MobileTheme.primaryGradient)
                        )
                }
                .disabled(currentStep == .cloudConnect && !authStore.state.isSignedIn)
            }
        }
    }

    private var buttonTitle: String {
        switch currentStep {
        case .welcome: return "Get Started"
        case .cloudConnect: return "Continue"
        case .hermesSetup: return "Continue"
        case .complete: return "Open Dashboard"
        }
    }

    private func advanceStep() {
        if currentStep == .complete {
            isPresented = false
            return
        }
        if let next = OnboardingStep.allCases[safe: currentStep.index + 1] {
            withAnimation(MobileTheme.Animation.standard) {
                currentStep = next
            }
        }
    }
}

// MARK: - Array Safe Index

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

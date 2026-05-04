import SwiftUI
import OpenBurnBarCore

// MARK: - iPad Onboarding Wizard

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
            EmberSurfaceBackground()

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
        case .welcome: welcomeStep
        case .cloudConnect: cloudConnectStep
        case .hermesSetup: hermesSetupStep
        case .complete: completeStep
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: MobileTheme.Spacing.xl) {
            ZStack {
                Circle()
                    .fill(MobileTheme.primaryGradient)
                    .frame(width: 120, height: 120)
                    .blur(radius: 30)
                    .opacity(0.5)

                Image(systemName: "flame.fill")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(MobileTheme.primaryGradient)
                    .symbolEffect(.bounce, options: .repeating)
            }
            .frame(height: 140)

            Text("Welcome to OpenBurnBar")
                .font(MobileTheme.Typography.display)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .multilineTextAlignment(.center)

            Text("Track, budget, and optimize your AI agent spend across every provider.")
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var cloudConnectStep: some View {
        VStack(spacing: MobileTheme.Spacing.xl) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.2))
                    .frame(width: 120, height: 120)
                    .blur(radius: 30)

                Image(systemName: "cloud.fill")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(.blue)
                    .symbolEffect(.variableColor, options: .repeating)
            }
            .frame(height: 140)

            Text("Connect Your Cloud")
                .font(MobileTheme.Typography.display)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .multilineTextAlignment(.center)

            Text("Sync usage data across devices with end-to-end encryption.")
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var hermesSetupStep: some View {
        VStack(spacing: MobileTheme.Spacing.xl) {
            ZStack {
                Circle()
                    .fill(MobileTheme.mercuryGradient)
                    .frame(width: 120, height: 120)
                    .blur(radius: 30)
                    .opacity(0.4)

                Text("☿")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(MobileTheme.hermesAureate)
                    .symbolEffect(.pulse, options: .repeating)
            }
            .frame(height: 140)

            Text("Meet Hermes")
                .font(MobileTheme.Typography.display)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .multilineTextAlignment(.center)

            Text("Your AI assistant for navigating spend, quotas, and insights.")
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var completeStep: some View {
        VStack(spacing: MobileTheme.Spacing.xl) {
            ZStack {
                Circle()
                    .fill(MobileTheme.Colors.success.opacity(0.2))
                    .frame(width: 120, height: 120)
                    .blur(radius: 30)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(MobileTheme.Colors.success)
                    .symbolEffect(.bounce)
            }
            .frame(height: 140)

            Text("You're All Set")
                .font(MobileTheme.Typography.display)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .multilineTextAlignment(.center)

            Text("OpenBurnBar is ready to help you burn smarter.")
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        VStack(spacing: MobileTheme.Spacing.lg) {
            // Progress capsule
            progressCapsule

            HStack {
                if currentStep != .welcome {
                    Button("Back") {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            if let prev = OnboardingStep.allCases.dropLast(currentStep.index).last {
                                currentStep = prev
                            }
                        }
                    }
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                }

                Spacer()

                Button(action: nextAction) {
                    Text(currentStep == .complete ? "Get Started" : "Next")
                        .font(MobileTheme.Typography.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, MobileTheme.Spacing.xl)
                        .padding(.vertical, MobileTheme.Spacing.md)
                        .background(
                            Capsule()
                                .fill(MobileTheme.primaryGradient)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var progressCapsule: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(MobileTheme.Colors.surfaceElevated)
                    .frame(height: 4)

                Capsule()
                    .fill(MobileTheme.primaryGradient)
                    .frame(
                        width: geo.size.width * progressFraction,
                        height: 4
                    )
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: currentStep)
            }
        }
        .frame(height: 4)
    }

    private var progressFraction: CGFloat {
        let index = CGFloat(currentStep.index)
        let total = CGFloat(OnboardingStep.allCases.count - 1)
        guard total > 0 else { return 1 }
        return index / total
    }

    private func nextAction() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            if currentStep == .complete {
                isPresented = false
            } else if let next = OnboardingStep.allCases.dropFirst(currentStep.index + 1).first {
                currentStep = next
            }
        }
    }
}

#Preview {
    iPadOnboardingWizardView(isPresented: .constant(true))
}

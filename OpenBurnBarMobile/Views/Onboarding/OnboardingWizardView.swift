import SwiftUI
import OpenBurnBarCore

/// First-run provider-connection wizard.
///
/// Replaces the previous placeholder (welcome / cloud / hermes / done). Walks
/// new users from sign-in to their first connected provider account in five
/// stages:
///
///     welcome → pick → connect (per provider) → review → done
///
/// The same `OnboardingProviderConnectStep` component is reused inside the
/// renovated manual `AddProviderConnectionView` so the experience is identical
/// at first-run and post-onboarding.
struct OnboardingWizardView: View {
    @Binding var isPresented: Bool

    @State private var stage: Stage = .welcome
    @State private var selectedProviders: [AgentProvider] = []
    @State private var queueIndex: Int = 0
    @State private var connectedAccounts: [ProviderAccountDoc] = []

    @State private var connectionStore = ProviderConnectionStore()
    @State private var hasLoaded = false

    enum Stage: Hashable {
        case welcome
        case pick
        case connect
        case review
        case done
    }

    var body: some View {
        ZStack {
            EmberSurfaceBackground().ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                stageContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, contentHorizontalPadding)
                    .padding(.top, MobileTheme.Spacing.lg)

                if stage != .connect {
                    bottomControls
                        .padding(.horizontal, MobileTheme.Spacing.xl)
                        .padding(.bottom, MobileTheme.Spacing.xl)
                }
            }
        }
        .task {
            // Load existing accounts once so the picker can dim already-connected
            // providers and the review step shows the full picture.
            if !hasLoaded {
                hasLoaded = true
                await connectionStore.load()
            }
        }
    }

    @Environment(\.horizontalSizeClass) private var hSizeClass

    private var contentHorizontalPadding: CGFloat {
        // iPad gets generous gutters; iPhone hugs the edges.
        hSizeClass == .regular ? MobileTheme.Spacing.xxxl : MobileTheme.Spacing.lg
    }

    // MARK: - Top bar (progress + skip)

    private var topBar: some View {
        VStack(spacing: MobileTheme.Spacing.sm) {
            HStack {
                topBarBackButton
                Spacer()
                if stage != .done && stage != .welcome {
                    Button("Skip") { complete() }
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
            }
            .padding(.horizontal, MobileTheme.Spacing.lg)
            .padding(.top, MobileTheme.Spacing.md)

            progressCapsule
                .padding(.horizontal, MobileTheme.Spacing.lg)
        }
    }

    /// Back chevron in the top bar. Visible on every stage except `welcome`
    /// (the wizard's starting point) and `done` (terminal celebration).
    /// `connect` goes one provider back if possible, otherwise to `pick`.
    @ViewBuilder
    private var topBarBackButton: some View {
        switch stage {
        case .pick:
            backChevron(label: "Back to welcome") { advance(to: .welcome) }
        case .connect:
            backChevron(label: "Back") {
                if queueIndex > 0 {
                    withAnimation(MobileTheme.Animation.gentle) { queueIndex -= 1 }
                    Haptics.selection()
                } else {
                    advance(to: .pick)
                }
            }
        case .review:
            backChevron(label: "Back to providers") {
                if !selectedProviders.isEmpty {
                    queueIndex = max(0, selectedProviders.count - 1)
                    advance(to: .connect)
                } else {
                    advance(to: .pick)
                }
            }
        case .welcome, .done:
            EmptyView()
        }
    }

    private func backChevron(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .frame(width: 36, height: 36)
                .background(
                    Circle().fill(MobileTheme.Colors.surface.opacity(0.55))
                )
                .overlay(
                    Circle().stroke(MobileTheme.Colors.border.opacity(0.5), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var progressCapsule: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(MobileTheme.Colors.surfaceElevated)
                    .frame(height: 4)
                Capsule()
                    .fill(MobileTheme.primaryGradient)
                    .frame(width: geo.size.width * progressFraction, height: 4)
                    .animation(MobileTheme.Animation.gentle, value: stage)
            }
        }
        .frame(height: 4)
    }

    private var progressFraction: CGFloat {
        switch stage {
        case .welcome: return 0.05
        case .pick:    return 0.25
        case .connect:
            guard !selectedProviders.isEmpty else { return 0.5 }
            let perProvider = 0.5 / CGFloat(selectedProviders.count)
            let connected = CGFloat(min(queueIndex, selectedProviders.count))
            return 0.25 + connected * perProvider
        case .review:  return 0.85
        case .done:    return 1.0
        }
    }

    // MARK: - Stage content

    @ViewBuilder
    private var stageContent: some View {
        switch stage {
        case .welcome: welcomeStage
        case .pick:
            OnboardingProviderPicker(
                selected: Binding(
                    get: { Set(selectedProviders) },
                    set: { newValue in
                        // Keep the user's stable order — append new picks to the
                        // tail, drop unpicks. This way the wizard walks providers
                        // in the order the user tapped them.
                        let added = newValue.subtracting(selectedProviders)
                        let kept = selectedProviders.filter { newValue.contains($0) }
                        selectedProviders = kept + Array(added).sorted { $0.displayName < $1.displayName }
                    }
                ),
                alreadyConnected: alreadyConnectedSet
            )
        case .connect:
            connectStage
        case .review:
            OnboardingReviewStep(
                connectedAccounts: combinedAccounts,
                onRefreshAll: refreshAllConnectedAccounts,
                onContinue: { advance(to: .done) }
            )
        case .done:
            completeStage
        }
    }

    private var welcomeStage: some View {
        VStack(spacing: MobileTheme.Spacing.xl) {
            Spacer()
            ZStack {
                Circle()
                    .fill(MobileTheme.primaryGradient)
                    .frame(width: 120, height: 120)
                    .blur(radius: 30)
                    .opacity(0.55)
                Image(systemName: "flame.fill")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(MobileTheme.primaryGradient)
                    .symbolEffect(.bounce, options: .repeating)
            }
            .frame(height: 140)

            VStack(spacing: MobileTheme.Spacing.md) {
                Text("Welcome to OpenBurnBar")
                    .font(MobileTheme.Typography.display)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                Text("Let's connect your first provider so we can show real numbers — quota, spend, and headroom.")
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, MobileTheme.Spacing.lg)
            }
            Spacer()
        }
    }

    private var completeStage: some View {
        VStack(spacing: MobileTheme.Spacing.xl) {
            Spacer()
            ZStack {
                Circle()
                    .fill(MobileTheme.Colors.success.opacity(0.18))
                    .frame(width: 120, height: 120)
                    .blur(radius: 30)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(MobileTheme.Colors.success)
                    .symbolEffect(.bounce)
            }
            .frame(height: 140)

            Text("You're all set")
                .font(MobileTheme.Typography.display)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .multilineTextAlignment(.center)

            if !connectedAccounts.isEmpty {
                Text("\(connectedAccounts.count) account\(connectedAccounts.count == 1 ? "" : "s") connected. OpenBurnBar will keep them in sync.")
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, MobileTheme.Spacing.lg)
            } else {
                Text("Ready when you are. Add a provider any time from the Account tab.")
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, MobileTheme.Spacing.lg)
            }
            Spacer()
        }
        .onAppear { Haptics.success() }
    }

    @ViewBuilder
    private var connectStage: some View {
        if let provider = selectedProviders[safe: queueIndex] {
            OnboardingProviderConnectStep(
                provider: provider,
                queuePosition: .init(current: queueIndex + 1, total: selectedProviders.count),
                onConnected: { account in
                    handleConnected(account)
                },
                onSkip: {
                    handleSkippedProvider()
                }
            )
            .id(provider.id) // reset internal state when the provider changes
        } else {
            // We've finished the queue; advance to review.
            Color.clear.onAppear { advance(to: .review) }
        }
    }

    // MARK: - Bottom controls (welcome / pick / review / done only)

    @ViewBuilder
    private var bottomControls: some View {
        HStack(spacing: MobileTheme.Spacing.md) {
            backButton
            Spacer()
            primaryButton
        }
    }

    @ViewBuilder
    private var backButton: some View {
        switch stage {
        case .pick:
            Button("Back") { advance(to: .welcome) }
                .foregroundStyle(MobileTheme.Colors.textSecondary)
        case .review:
            Button("Add another") { advance(to: .pick) }
                .foregroundStyle(MobileTheme.Colors.textSecondary)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch stage {
        case .welcome:
            wizardPrimaryButton(title: "Get started") { advance(to: .pick) }
        case .pick:
            wizardPrimaryButton(
                title: selectedProviders.isEmpty ? "Skip for now" : "Continue",
                isEnabled: true
            ) {
                if selectedProviders.isEmpty {
                    advance(to: .review)
                } else {
                    queueIndex = 0
                    advance(to: .connect)
                }
            }
        case .review:
            wizardPrimaryButton(title: "Finish") { advance(to: .done) }
        case .done:
            wizardPrimaryButton(title: "Get started") { complete() }
        case .connect:
            EmptyView() // connect step has its own action bar
        }
    }

    private func wizardPrimaryButton(
        title: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, MobileTheme.Spacing.xl)
                .padding(.vertical, MobileTheme.Spacing.md)
                .background(
                    Capsule()
                        .fill(isEnabled ? AnyShapeStyle(MobileTheme.primaryGradient) : AnyShapeStyle(MobileTheme.Colors.textMuted.opacity(0.4)))
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    // MARK: - Stage transitions

    private func advance(to next: Stage) {
        Haptics.selection()
        withAnimation(MobileTheme.Animation.gentle) {
            stage = next
        }
    }

    private func complete() {
        Haptics.success()
        withAnimation(MobileTheme.Animation.gentle) {
            isPresented = false
        }
    }

    private func handleConnected(_ account: ProviderAccountDoc) {
        connectedAccounts.append(account)
        advanceQueue()
    }

    private func handleSkippedProvider() {
        advanceQueue()
    }

    private func advanceQueue() {
        if queueIndex + 1 < selectedProviders.count {
            withAnimation(MobileTheme.Animation.gentle) {
                queueIndex += 1
            }
        } else {
            advance(to: .review)
        }
    }

    // MARK: - Helpers

    private var alreadyConnectedSet: Set<ProviderID> {
        Set(connectionStore.accounts
            .filter { $0.status != .deleted }
            .map(\.providerID))
    }

    /// All accounts surfaced on the review screen — the ones the wizard just
    /// created plus any pre-existing ones (e.g. when the user re-runs the
    /// wizard on a re-installed device).
    private var combinedAccounts: [ProviderAccountDoc] {
        let wizardIDs = Set(connectedAccounts.map(\.id))
        let extras = connectionStore.accounts.filter { !wizardIDs.contains($0.id) && $0.status != .deleted }
        return connectedAccounts + extras
    }

    private func refreshAllConnectedAccounts() async {
        for account in combinedAccounts {
            await connectionStore.refresh(account: account)
        }
    }
}

// MARK: - Safe-index helper

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

#Preview {
    OnboardingWizardView(isPresented: .constant(true))
}

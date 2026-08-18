import SwiftUI
import OpenBurnBarKernel

// MARK: - First Run Reveal
//
// One window. It opens itself, holds something true, and closes. There is no
// Continue button anywhere in it, because there is nothing for the user to
// decide — the app already knows the answer and is simply showing them.
//
// What this screen deliberately does NOT do, and every one of these was in the
// build it replaces: greet the user, explain itself, offer a tour, ask for an
// account, ask for a permission, ask them to pick a pet, or promote the app to
// a Dock-icon regular app they then have to dismiss.

struct FirstRunReveal: View {
    @Bindable var model: FirstRunRevealModel
    /// Detected agents shown as rows during the scan. Real detection results.
    let detectedProviders: [DetectedProvider]
    var onOpenQuotaWorkspace: () -> Void = {}
    /// Opens the alerts surface. Deliberately NOT named "arm alert": there is no
    /// quota-percentage alert engine in the product yet, so the button routes to
    /// the setup surface and says so, rather than leaving the user believing an
    /// alert is armed that would never fire.
    var onSetUpAlerts: () -> Void = {}
    var onShowPathAudit: () -> Void = {}
    var onWatchForFirstSession: () -> Void = {}
    var onDismiss: () -> Void = {}

    struct DetectedProvider: Identifiable, Equatable {
        enum State: Equatable { case queued, parsing, resolved, blocked }
        let displayName: String
        let path: String
        var state: State
        var id: String { displayName }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            switch model.phase {
            case .scanning(let fraction):
                scanning(fraction: fraction)
            case .quota(let window, let supporting):
                quotaHero(window: window, supporting: supporting)
            case .spend(let hero):
                spendHero(hero)
            case .empty(let searchedPathCount):
                FirstRunEmptyReveal(
                    searchedPathCount: searchedPathCount,
                    onWatchForIt: { onWatchForFirstSession(); onDismiss() },
                    onShowPathAudit: onShowPathAudit
                )
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(width: 340)
        .animation(reduceMotion ? nil : DesignSystem.Animation.gentle, value: model.phase)
    }

    // MARK: S1a — scanning

    private func scanning(fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("Reading what's already here.")
                .font(DesignSystem.Typography.title)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            // Real parse progress from the watermark governor, not a fake
            // timer. A progress bar that lies about work is the first small
            // dishonesty a product tells, and this one refuses to tell it.
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(DesignSystem.Colors.borderSubtle)
                    Capsule()
                        .fill(DesignSystem.Colors.blaze)
                        .frame(width: max(2, geometry.size.width * fraction))
                }
            }
            .frame(height: 1.5)

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                ForEach(detectedProviders) { provider in
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Circle()
                            .fill(dotTint(for: provider.state))
                            .frame(width: 6, height: 6)
                        Text(provider.displayName)
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Spacer(minLength: DesignSystem.Spacing.sm)
                        Text(provider.state == .parsing ? "scanning…" : provider.path)
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity)
                    )
                }
            }

            Text("No account. No API key. Nothing left this Mac.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }

    private func dotTint(for state: DetectedProvider.State) -> Color {
        switch state {
        case .resolved: DesignSystem.Colors.success
        case .parsing: DesignSystem.Colors.amber
        case .queued: DesignSystem.Colors.textMuted
        case .blocked: DesignSystem.Colors.ember
        }
    }

    // MARK: The reveal — quota hero

    private func quotaHero(window: TightestQuotaWindow, supporting: [FirstRunRevealModel.SupportingRow]) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            eyebrow("YOUR TIGHTEST WINDOW", live: true)

            FirstRunTightestWindowCard(window: window)

            if supporting.isEmpty == false {
                hairline
                VStack(spacing: DesignSystem.Spacing.sm) {
                    ForEach(supporting) { row in
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            Text(row.providerDisplayName)
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: DesignSystem.Spacing.sm)
                            // A provider with no real percentage renders a
                            // word, never a number. `QuotaRefreshActor` refuses
                            // to fabricate a bucket; this refuses to draw one.
                            Text(row.remainingPercent.map { "\(Int($0.rounded(.down)))%" } ?? "pool")
                                .font(DesignSystem.Typography.monoSmall)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                            Text(row.detail)
                                .font(DesignSystem.Typography.monoTiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                .frame(width: 54, alignment: .trailing)
                        }
                    }
                }
            }

            hairline
            actions(seeAllTitle: "See all windows →")
        }
    }

    // MARK: The reveal — spend hero (the honest cold-install first beat)

    private func spendHero(_ hero: FirstRunRevealModel.SpendHero) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            eyebrow("WHAT YOU'VE BURNED", live: false)

            HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
                Text(hero.monthToDateUSD, format: .currency(code: "USD"))
                    .font(DesignSystem.Typography.display)
                    .monospacedDigit()
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("this month")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }

            Text(agentSentence(hero))
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if hero.expectsQuotaSignalSoon {
                hairline
                // Beat two, promised honestly. The percentage genuinely is not
                // knowable yet on a cold install — no credentials means no plan
                // cap to divide by — and `ClaudeQuotaAdapter` has already
                // installed the statusline bridge silently, so it arrives on
                // its own the next time an agent runs. Saying so turns a
                // missing number into an appointment.
                Text("Percentages land the next time one of these runs. Nothing to set up.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            hairline
            actions(seeAllTitle: "See the breakdown →")
        }
    }

    private func agentSentence(_ hero: FirstRunRevealModel.SpendHero) -> String {
        let agents = hero.providerDisplayNames.count
        let agentText = agents == 1 ? "1 agent" : "\(agents) agents"
        let sessionText = hero.sessionCount == 1 ? "1 session" : "\(hero.sessionCount.formatted()) sessions"
        return "\(agentText) · \(sessionText) · read from this Mac"
    }

    // MARK: Shared chrome

    private func eyebrow(_ text: String, live: Bool) -> some View {
        HStack {
            Text(text)
                .font(DesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .tracking(1.4)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Spacer()
            if live {
                HStack(spacing: 5) {
                    Circle()
                        .fill(DesignSystem.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("LIVE")
                        .font(DesignSystem.Typography.tiny)
                        .fontWeight(.semibold)
                        .tracking(0.8)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(DesignSystem.Colors.borderSubtle)
            .frame(height: 1)
    }

    private func actions(seeAllTitle: String) -> some View {
        HStack {
            // The only decision this screen ever asks for. It is an explicit
            // SETUP flow, not a promise: "Tell me at 80%" implied an armed alert,
            // and nothing in the product would ever have fired it.
            Button("Set up alerts →") { onSetUpAlerts() }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.blaze)
                .controlSize(.small)

            Spacer()

            Button(seeAllTitle) { onOpenQuotaWorkspace(); onDismiss() }
                .buttonStyle(.plain)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
    }
}

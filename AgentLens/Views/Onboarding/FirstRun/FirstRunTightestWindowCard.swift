import SwiftUI
import OpenBurnBarKernel
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Tightest Window Card
//
// The aha, rendered. A gauge lands on a real number and a clock says when it
// comes back — the one sentence no vendor is allowed to show, arriving without
// a single question having been asked.
//
// The motion is doing real work, not decoration. A ring that snapped to 38%
// would read as a static chart; a ring that sweeps up, slightly overshoots and
// settles reads as an INSTRUMENT taking a measurement, which is what earns the
// user's belief that the number came from their disk rather than from a
// designer. That is the whole budget: one 0.9s beat, one haptic, then stillness
// forever. Everything after this screen is quiet.

struct FirstRunTightestWindowCard: View {
    let window: TightestQuotaWindow
    /// Plays the landing beat once. False when the card is re-shown later (S2
    /// reuses this card, and a gauge that re-measures on every visit is a toy).
    var playsLandingBeat: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep: Double = 0
    @State private var countUpValue: Double = 0
    @State private var didPlayBeat = false

    /// The spec's settle: `spring(response: 0.55, dampingFraction: 0.78)`.
    /// Under-damped on purpose — the overshoot is the needle, and a critically
    /// damped spring here loses the instrument feeling entirely.
    private static let posterSettle = Animation.spring(response: 0.55, dampingFraction: 0.78)
    private static let ringDiameter: CGFloat = 76
    private static let ringWidth: CGFloat = 7

    var body: some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.lg) {
            gauge
            VStack(alignment: .leading, spacing: 1) {
                Text(window.providerDisplayName)
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)

                Text(planLine)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)

                if let resetLine {
                    Text(resetLine)
                        .font(DesignSystem.Typography.monoSmall)
                        .fontWeight(.semibold)
                        .foregroundStyle(resetTint)
                        .lineLimit(1)
                        .padding(.top, DesignSystem.Spacing.xxs)
                }
            }
            Spacer(minLength: 0)
        }
        .onAppear(perform: playBeatIfNeeded)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySentence)
    }

    // MARK: Gauge

    private var gauge: some View {
        ZStack {
            Circle()
                .stroke(DesignSystem.Colors.border, lineWidth: Self.ringWidth)

            Circle()
                .trim(from: 0, to: sweep)
                .stroke(
                    pressureTint,
                    style: StrokeStyle(lineWidth: Self.ringWidth, lineCap: .round)
                )
                // Start at twelve o'clock: a gauge that begins at three reads
                // as a pie chart, and a pie chart is not an instrument.
                .rotationEffect(.degrees(-90))

            VStack(spacing: 0) {
                Text("\(Int(countUpValue.rounded(.down)))%")
                    .font(DesignSystem.Typography.mono)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                if window.isEstimated {
                    // The fidelity dagger. `docs/PROVIDERS.md` promises the UI
                    // never presents an estimate as exact; this is that promise
                    // rendered, and it must never be silently dropped.
                    Text("†")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
        }
        .frame(width: Self.ringDiameter, height: Self.ringDiameter)
        .help(window.isEstimated
              ? "Estimated from pacing — no official meter exists for this plan."
              : "Reported by \(window.providerDisplayName).")
    }

    // MARK: Motion

    private func playBeatIfNeeded() {
        guard didPlayBeat == false else { return }
        didPlayBeat = true

        let target = window.remainingPercent / 100
        guard playsLandingBeat, reduceMotion == false else {
            sweep = target
            countUpValue = window.remainingPercent
            return
        }

        withAnimation(Self.posterSettle) { sweep = target }

        // The digits chase the needle rather than sharing its spring: a
        // count-up that overshoots would print an impossible percentage for a
        // few frames, and this screen's entire job is to never show a number
        // that isn't true.
        withAnimation(.easeOut(duration: 0.55).delay(0.18)) {
            countUpValue = window.remainingPercent
        }

        #if canImport(AppKit)
        // Exactly one haptic in the entire first run, at the moment the needle
        // settles. A second one anywhere would make this one mean nothing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        #endif
    }

    // MARK: Derived copy

    private var planLine: String {
        [window.accountLabel, window.windowLabel]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var resetLine: String? {
        guard let resetsAt = window.resetsAt else { return nil }
        let interval = resetsAt.timeIntervalSinceNow
        guard interval > 0 else { return "resetting now" }
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        return hours > 0 ? "resets in \(hours)h \(minutes)m" : "resets in \(minutes)m"
    }

    /// Amber once the reset is close enough that it changes what you'd start.
    private var resetTint: Color {
        guard let resetsAt = window.resetsAt else { return DesignSystem.Colors.textSecondary }
        return resetsAt.timeIntervalSinceNow < 4 * 3600
            ? DesignSystem.Colors.amber
            : DesignSystem.Colors.textSecondary
    }

    private var pressureTint: Color {
        switch window.pressure {
        case .comfortable: DesignSystem.Colors.success
        case .tightening: DesignSystem.Colors.amber
        case .critical: DesignSystem.Colors.ember
        }
    }

    private var accessibilitySentence: String {
        var sentence = "\(window.providerDisplayName), \(window.displayPercent) percent of your \(window.windowLabel) remaining"
        if let resetLine { sentence += ", \(resetLine)" }
        if window.isEstimated { sentence += ", estimated" }
        return sentence
    }
}

#Preview("Tightest window — comfortable") {
    FirstRunTightestWindowCard(
        window: TightestQuotaWindow(
            providerDisplayName: "Claude Code",
            windowLabel: "weekly",
            remainingPercent: 62,
            resetsAt: Date().addingTimeInterval(9 * 3600),
            isEstimated: false,
            comparedProviderCount: 4
        )
    )
    .padding()
    .frame(width: 340)
}

#Preview("Tightest window — critical, estimated") {
    FirstRunTightestWindowCard(
        window: TightestQuotaWindow(
            providerDisplayName: "Antigravity",
            accountLabel: "Max",
            windowLabel: "5-hour window",
            remainingPercent: 9,
            resetsAt: Date().addingTimeInterval(41 * 60),
            isEstimated: true,
            comparedProviderCount: 3
        )
    )
    .padding()
    .frame(width: 340)
}

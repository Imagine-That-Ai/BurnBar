import SwiftUI

// MARK: - Insight Auto Rotator
//
// Bottom strip on Trend Atlas. Pulls from `TrendInsightEngine` and rotates
// every 6 seconds with a cross-fade. Pauses while user is interacting with
// the parent card. Always shows at least one fallback insight.

struct InsightAutoRotator: View {
    let insights: [TrendInsight]
    var rotationSeconds: Double = 6
    var isPaused: Bool = false

    @State private var index: Int = 0
    @State private var timer: Timer?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var current: TrendInsight? {
        guard !insights.isEmpty else { return nil }
        return insights[index % insights.count]
    }

    var body: some View {
        HStack(spacing: MobileTheme.Spacing.sm) {
            if let current {
                Image(systemName: current.symbolName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(toneColor(current.tone))
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(current.title)
                        .font(MobileTheme.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .lineLimit(1)
                    Text(current.detail)
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 6)

                if insights.count > 1 {
                    HStack(spacing: 3) {
                        ForEach(0..<insights.count, id: \.self) { i in
                            Circle()
                                .fill(i == index ? toneColor(current.tone) : MobileTheme.Colors.border.opacity(0.5))
                                .frame(width: 4, height: 4)
                        }
                    }
                    .accessibilityHidden(true)
                }
            } else {
                Text("No insights yet")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(MobileTheme.Colors.surface.opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(MobileTheme.Colors.borderSubtle.opacity(0.5), lineWidth: 0.5)
        )
        .id(current?.id ?? "empty")
        .transition(.opacity.combined(with: .move(edge: .leading)))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: index)
        .onAppear { restartTimer() }
        .onDisappear { stopTimer() }
        .onChange(of: insights) { _, _ in restartTimer() }
        .onChange(of: isPaused) { _, paused in
            if paused { stopTimer() } else { restartTimer() }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Timer

    private func restartTimer() {
        stopTimer()
        guard !isPaused, insights.count > 1, !reduceMotion else { return }
        timer = Timer.scheduledTimer(withTimeInterval: rotationSeconds, repeats: true) { _ in
            Task { @MainActor in
                index = (index + 1) % max(1, insights.count)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func toneColor(_ tone: TrendInsight.Tone) -> Color {
        switch tone {
        case .positive: return MobileTheme.success
        case .warning:  return MobileTheme.warning
        case .neutral:  return MobileTheme.hermesAureate
        }
    }
}

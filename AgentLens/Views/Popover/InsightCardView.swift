import SwiftUI

struct InsightCardView: View {
    let insights: [Insight]
    let freshness: InsightRollupFreshness
    let freshnessMessage: String?
    /// While hovering, hold the carousel on the index at hover start (must not mutate state during `TimelineView` body).
    @State private var pausedIndex: Int?
    /// Set by chevron taps; cleared after 15s to resume auto-rotation.
    @State private var manualIndex: Int?
    /// Cancellation token for the auto-resume dispatch.
    @State private var resumeWorkItem: DispatchWorkItem?
    /// Hovered carousel chevron slot (-1 left, 1 right) for the hover tint.
    @State private var hoveredChevron: Int?

    init(
        insights: [Insight],
        freshness: InsightRollupFreshness = .fresh,
        freshnessMessage: String? = nil
    ) {
        self.insights = insights
        self.freshness = freshness
        self.freshnessMessage = freshnessMessage
    }

    var body: some View {
        VStack(spacing: 0) {
            if insights.isEmpty == false {
                if insights.count == 1 {
                    cardContent(for: insights[0], displayIndex: 0)
                } else {
                    TimelineView(.periodic(from: .now, by: 8)) { ctx in
                        let idx = resolvedIndex(for: ctx.date)
                        cardContent(for: insights[idx], displayIndex: idx)
                            .id(idx)
                            .transition(.opacity.animation(.easeInOut(duration: 0.4)))
                    }
                    .onHover { hovering in
                        if hovering {
                            pausedIndex = rotatingIndex(at: Date(), count: insights.count)
                        } else {
                            pausedIndex = nil
                        }
                    }
                }
            }

            if let statusText {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: statusIcon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(statusColor)
                    Text(statusText)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.bottom, DesignSystem.Spacing.sm)
            }
        }
    }

    private func rotatingIndex(at date: Date, count: Int) -> Int {
        let seconds = Int(date.timeIntervalSince1970)
        return (seconds / 8) % max(count, 1)
    }

    /// Manual override wins over hover-pause so clicking chevrons works while hovering.
    private func resolvedIndex(for date: Date) -> Int {
        if let manualIndex {
            return manualIndex % max(insights.count, 1)
        }
        if let pausedIndex { return pausedIndex }
        return rotatingIndex(at: date, count: insights.count)
    }

    private func navigateManual(by delta: Int, from current: Int) {
        let count = insights.count
        guard count > 0 else { return }
        let next = ((current + delta) % count + count) % count
        manualIndex = next

        // Cancel any previous auto-resume and schedule a new one
        resumeWorkItem?.cancel()
        let work = DispatchWorkItem { manualIndex = nil }
        resumeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }

    @ViewBuilder
    private func cardContent(for insight: Insight, displayIndex: Int) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: insight.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(sentimentColor(insight.sentiment))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(insight.headline)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                if let detail = insight.detail {
                    Text(detail)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(1)
                }
            }
            Spacer()

            if insights.count > 1 {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Button {
                        navigateManual(by: -1, from: displayIndex)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(hoveredChevron == -1 ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.textMuted)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveredChevron = $0 ? -1 : nil }
                    .animation(DesignSystem.Animation.hover, value: hoveredChevron)

                    HStack(spacing: 3) {
                        ForEach(0..<insights.count, id: \.self) { i in
                            Circle()
                                .fill(i == displayIndex ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.textMuted.opacity(0.4))
                                .frame(width: 4, height: 4)
                        }
                    }

                    Button {
                        navigateManual(by: 1, from: displayIndex)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(hoveredChevron == 1 ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.textMuted)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveredChevron = $0 ? 1 : nil }
                    .animation(DesignSystem.Animation.hover, value: hoveredChevron)
                }
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .popoverTooltip(insight.headline + (insight.detail.map { " — " + $0 } ?? ""))
    }

    private func sentimentColor(_ s: Sentiment) -> Color {
        switch s {
        case .positive: return DesignSystem.Colors.success
        case .negative: return DesignSystem.Colors.warning
        case .neutral: return DesignSystem.Colors.textSecondary
        }
    }

    private var statusText: String? {
        switch freshness {
        case .fresh:
            return nil
        case .stale:
            return freshnessMessage ?? "Workflow insights are stale."
        case .rebuilding:
            return freshnessMessage ?? "Workflow insights are rebuilding."
        case .unavailable:
            return freshnessMessage ?? "Workflow insights are unavailable."
        }
    }

    private var statusIcon: String {
        switch freshness {
        case .fresh:
            return "checkmark.circle.fill"
        case .stale:
            return "clock.badge.exclamationmark.fill"
        case .rebuilding:
            return "arrow.triangle.2.circlepath.circle.fill"
        case .unavailable:
            return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch freshness {
        case .fresh:
            return DesignSystem.Colors.success
        case .stale, .rebuilding:
            return DesignSystem.Colors.warning
        case .unavailable:
            return DesignSystem.Colors.error
        }
    }
}

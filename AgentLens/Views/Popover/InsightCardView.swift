import SwiftUI

struct InsightCardView: View {
    let insights: [Insight]
    /// While hovering, hold the carousel on the index at hover start (must not mutate state during `TimelineView` body).
    @State private var pausedIndex: Int?

    var body: some View {
        if insights.isEmpty {
            EmptyView()
        } else if insights.count == 1 {
            cardContent(for: insights[0], displayIndex: 0)
        } else {
            TimelineView(.periodic(from: .now, by: 8)) { ctx in
                let idx = currentIndex(for: ctx.date)
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

    private func rotatingIndex(at date: Date, count: Int) -> Int {
        let seconds = Int(date.timeIntervalSince1970)
        return (seconds / 8) % max(count, 1)
    }

    private func currentIndex(for date: Date) -> Int {
        if let pausedIndex { return pausedIndex }
        return rotatingIndex(at: date, count: insights.count)
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
                HStack(spacing: 3) {
                    ForEach(0..<insights.count, id: \.self) { i in
                        Circle()
                            .fill(i == displayIndex ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.textMuted.opacity(0.4))
                            .frame(width: 4, height: 4)
                    }
                }
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.sm)
    }

    private func sentimentColor(_ s: Sentiment) -> Color {
        switch s {
        case .positive: return DesignSystem.Colors.success
        case .negative: return DesignSystem.Colors.warning
        case .neutral: return DesignSystem.Colors.textSecondary
        }
    }
}

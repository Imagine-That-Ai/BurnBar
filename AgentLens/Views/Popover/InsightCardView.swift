import SwiftUI

struct InsightCardView: View {
    let insights: [Insight]
    @State private var currentIndex = 0
    @State private var isHovered = false

    var body: some View {
        if insights.isEmpty {
            EmptyView()
        } else if insights.count == 1 {
            cardContent(for: insights[0])
        } else {
            TimelineView(.periodic(from: .now, by: 8)) { ctx in
                let _ = advance(at: ctx.date)
                cardContent(for: insights[currentIndex])
                    .id(currentIndex)
                    .transition(.opacity.animation(.easeInOut(duration: 0.4)))
            }
            .onHover { isHovered = $0 }
        }
    }

    private func advance(at date: Date) -> Int {
        guard !isHovered else { return currentIndex }
        let seconds = Int(date.timeIntervalSince1970)
        let idx = (seconds / 8) % insights.count
        if idx != currentIndex { currentIndex = idx }
        return currentIndex
    }

    @ViewBuilder
    private func cardContent(for insight: Insight) -> some View {
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
                            .fill(i == currentIndex ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.textMuted.opacity(0.4))
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

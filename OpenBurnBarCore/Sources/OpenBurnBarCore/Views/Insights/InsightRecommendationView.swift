import SwiftUI

public struct InsightRecommendationView: View {
    public let data: InsightWidgetData.Recommendation
    public let onCitationTapped: ((InsightCitation) -> Void)?
    public init(data: InsightWidgetData.Recommendation,
                onCitationTapped: ((InsightCitation) -> Void)? = nil) {
        self.data = data
        self.onCitationTapped = onCitationTapped
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xs) {
            HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.xs) {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(UnifiedDesignSystem.Colors.amber)
                VStack(alignment: .leading, spacing: 2) {
                    Text(data.headline)
                        .font(UnifiedDesignSystem.Typography.title)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                    HStack(spacing: 4) {
                        confidencePill
                        if let impact = data.estimatedImpact, !impact.isEmpty {
                            Text("· \(impact)")
                                .font(UnifiedDesignSystem.Typography.caption)
                                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                        }
                    }
                }
            }
            if !data.rationale.isEmpty {
                Text(data.rationale)
                    .font(UnifiedDesignSystem.Typography.body)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !data.action.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.right.circle.fill")
                        .foregroundStyle(UnifiedDesignSystem.Colors.ember)
                    Text(data.action)
                        .font(UnifiedDesignSystem.Typography.body)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                        .fontWeight(.semibold)
                }
                .padding(UnifiedDesignSystem.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md)
                        .fill(UnifiedDesignSystem.Colors.ember.opacity(0.08))
                )
            }
            if !data.citations.isEmpty {
                InsightCitationsRow(citations: data.citations, onTap: onCitationTapped)
            }
        }
    }

    private var confidencePill: some View {
        let label: String
        let color: Color
        switch data.confidence {
        case .low: label = "low confidence"; color = UnifiedDesignSystem.Colors.textMuted
        case .medium: label = "medium confidence"; color = UnifiedDesignSystem.Colors.amber
        case .high: label = "high confidence"; color = UnifiedDesignSystem.Colors.success
        }
        return Text(label)
            .font(UnifiedDesignSystem.Typography.tiny)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
            .foregroundStyle(color)
    }
}

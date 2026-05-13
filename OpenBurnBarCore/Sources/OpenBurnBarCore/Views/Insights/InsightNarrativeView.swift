import SwiftUI

public struct InsightNarrativeView: View {
    public let data: InsightWidgetData.Narrative
    public let onCitationTapped: ((InsightCitation) -> Void)?
    public init(data: InsightWidgetData.Narrative,
                onCitationTapped: ((InsightCitation) -> Void)? = nil) {
        self.data = data
        self.onCitationTapped = onCitationTapped
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xs) {
            HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.xs) {
                Image(systemName: "text.quote")
                    .foregroundStyle(InsightFormatting.tone(data.tone))
                Text(data.headline)
                    .font(UnifiedDesignSystem.Typography.title)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
            }
            if !data.body.isEmpty {
                Text(data.body)
                    .font(UnifiedDesignSystem.Typography.body)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !data.bullets.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(data.bullets, id: \.self) { bullet in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•")
                                .foregroundStyle(InsightFormatting.tone(data.tone))
                            Text(bullet)
                                .font(UnifiedDesignSystem.Typography.caption)
                                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if !data.citations.isEmpty {
                InsightCitationsRow(citations: data.citations, onTap: onCitationTapped)
                    .padding(.top, 2)
            }
        }
    }
}

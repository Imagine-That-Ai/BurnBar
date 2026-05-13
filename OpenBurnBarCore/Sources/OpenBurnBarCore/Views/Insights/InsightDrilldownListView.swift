import SwiftUI

public struct InsightDrilldownListView: View {
    public let data: InsightWidgetData.Drilldown
    public let onCitationTapped: ((InsightCitation) -> Void)?
    public init(data: InsightWidgetData.Drilldown,
                onCitationTapped: ((InsightCitation) -> Void)? = nil) {
        self.data = data
        self.onCitationTapped = onCitationTapped
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(data.rows) { row in
                Button {
                    onCitationTapped?(row.citation)
                } label: {
                    rowView(row)
                }
                .buttonStyle(.plain)
                Divider().opacity(0.4)
            }
        }
    }

    private func rowView(_ row: InsightWidgetData.Drilldown.Row) -> some View {
        HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(UnifiedDesignSystem.Typography.body)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let subtitle = row.subtitle {
                        Text(subtitle)
                            .font(UnifiedDesignSystem.Typography.tiny)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                    }
                    Text(row.occurredAt, format: .relative(presentation: .named))
                        .font(UnifiedDesignSystem.Typography.tiny)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                if let cost = row.costUSD {
                    Text(InsightFormatting.format(cost, as: .currency))
                        .font(UnifiedDesignSystem.Typography.caption)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                }
                if let tokens = row.tokens {
                    Text(InsightFormatting.tokensFormatter(Double(tokens)))
                        .font(UnifiedDesignSystem.Typography.tiny)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

import SwiftUI

public struct InsightASCIIView: View {
    public let data: InsightWidgetData.ASCIICard
    public init(data: InsightWidgetData.ASCIICard) { self.data = data }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(data.headline.uppercased())
                .font(UnifiedDesignSystem.Typography.monoSmall)
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            Text(data.monoBody)
                .font(UnifiedDesignSystem.Typography.mono)
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(UnifiedDesignSystem.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.sm)
                        .fill(UnifiedDesignSystem.Colors.surface)
                )
            if let caption = data.caption, !caption.isEmpty {
                Text(caption)
                    .font(UnifiedDesignSystem.Typography.tiny)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            }
        }
    }
}

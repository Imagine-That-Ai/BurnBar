import SwiftUI

public struct InsightQuotaPulseView: View {
    public let data: InsightWidgetData.QuotaState
    public init(data: InsightWidgetData.QuotaState) { self.data = data }

    public var body: some View {
        LazyVGrid(columns: [
            GridItem(.adaptive(minimum: 130, maximum: 180), spacing: UnifiedDesignSystem.Spacing.sm)
        ], spacing: UnifiedDesignSystem.Spacing.sm) {
            ForEach(data.buckets) { bucket in
                bucketCard(bucket)
            }
        }
    }

    private func bucketCard(_ bucket: InsightWidgetData.QuotaState.Bucket) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: bucket.symbolName)
                    .foregroundStyle(color(for: bucket.fraction))
                Text(bucket.providerLabel)
                    .font(UnifiedDesignSystem.Typography.caption)
                    .lineLimit(1)
            }
            Text(bucket.bucketName)
                .font(UnifiedDesignSystem.Typography.tiny)
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            ProgressView(value: bucket.fraction)
                .tint(color(for: bucket.fraction))
            if let resetsAt = bucket.resetsAt {
                Text("Resets " + resetsAt.formatted(.relative(presentation: .named)))
                    .font(UnifiedDesignSystem.Typography.tiny)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            }
        }
        .padding(UnifiedDesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md)
                .fill(UnifiedDesignSystem.Colors.surface)
        )
    }

    private func color(for fraction: Double) -> Color {
        switch fraction {
        case ..<0.5: return UnifiedDesignSystem.Colors.success
        case ..<0.85: return UnifiedDesignSystem.Colors.amber
        default: return UnifiedDesignSystem.Colors.error
        }
    }
}

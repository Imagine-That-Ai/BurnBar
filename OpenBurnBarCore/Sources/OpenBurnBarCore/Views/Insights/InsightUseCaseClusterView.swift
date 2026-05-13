import SwiftUI

public struct InsightUseCaseClusterView: View {
    public let data: InsightWidgetData.UseCaseCluster
    public init(data: InsightWidgetData.UseCaseCluster) { self.data = data }

    public var body: some View {
        let total = max(1, data.clusters.reduce(0) { $0 + $1.size })
        FlowLayout(spacing: 6) {
            ForEach(data.clusters) { cluster in
                chip(cluster: cluster, total: total)
            }
        }
    }

    private func chip(cluster: InsightWidgetData.UseCaseCluster.Cluster, total: Int) -> some View {
        let fraction = Double(cluster.size) / Double(total)
        let color = InsightFormatting.color(forHex: cluster.colorHex)
            ?? InsightFormatting.color(forSeriesID: cluster.id)
        return HStack(spacing: 4) {
            Text(cluster.label)
                .font(UnifiedDesignSystem.Typography.caption)
            Text("\(cluster.size)")
                .font(UnifiedDesignSystem.Typography.tiny)
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4 + CGFloat(fraction * 4))
        .background(
            Capsule()
                .fill(color.opacity(0.15 + fraction * 0.35))
        )
        .foregroundStyle(color)
    }
}

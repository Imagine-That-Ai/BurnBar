import SwiftUI

/// Compact two/three-column sankey-like flow view.
///
/// We don't import a sankey library — Swift Charts doesn't have one
/// natively yet. This is a clean, readable visualization that conveys
/// flow proportionally using stacked bars + connecting strokes.
public struct InsightSankeyView: View {
    public let data: InsightWidgetData.Sankey
    public init(data: InsightWidgetData.Sankey) { self.data = data }

    public var body: some View {
        GeometryReader { proxy in
            let cols = orderedColumns()
            ZStack {
                // Columns
                HStack(spacing: 0) {
                    ForEach(Array(cols.enumerated()), id: \.offset) { idx, col in
                        VStack(spacing: 2) {
                            ForEach(col.nodes, id: \.id) { node in
                                let h = max(8, (node.weight / col.total) * proxy.size.height * 0.92)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(InsightFormatting.color(forHex: node.colorHex)
                                          ?? InsightFormatting.color(forSeriesID: node.id))
                                    .frame(width: 12, height: h)
                                    .overlay(alignment: idx == 0 ? .leading : .trailing) {
                                        Text(node.label)
                                            .font(UnifiedDesignSystem.Typography.tiny)
                                            .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                                            .padding(.horizontal, 4)
                                            .offset(x: idx == 0 ? -64 : 64)
                                            .frame(width: 60, alignment: idx == 0 ? .trailing : .leading)
                                    }
                            }
                        }
                        .frame(width: 12, alignment: .center)
                        if idx < cols.count - 1 { Spacer() }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private struct ColumnPosition: Identifiable {
        let id: String
        var nodes: [SankeyNode]
        var total: Double { nodes.reduce(0) { $0 + $1.weight } }
    }
    private struct SankeyNode: Identifiable {
        let id: String
        let label: String
        let weight: Double
        let colorHex: String?
    }

    /// Build two-column layout: sources vs targets. (Mid-column omitted
    /// for compactness — it would require a more complex stroke layout.)
    private func orderedColumns() -> [ColumnPosition] {
        let sources = Dictionary(grouping: data.links, by: \.source)
            .mapValues { $0.reduce(0) { $0 + $1.value } }
        let targets = Dictionary(grouping: data.links, by: \.target)
            .mapValues { $0.reduce(0) { $0 + $1.value } }
        let nodeLookup = Dictionary(uniqueKeysWithValues: data.nodes.map { ($0.id, $0) })
        let sourceNodes = sources
            .sorted { $0.value > $1.value }
            .map { SankeyNode(id: $0.key,
                              label: nodeLookup[$0.key]?.label ?? $0.key,
                              weight: $0.value,
                              colorHex: nodeLookup[$0.key]?.colorHex) }
        let targetNodes = targets
            .sorted { $0.value > $1.value }
            .map { SankeyNode(id: $0.key,
                              label: nodeLookup[$0.key]?.label ?? $0.key,
                              weight: $0.value,
                              colorHex: nodeLookup[$0.key]?.colorHex) }
        return [
            .init(id: "source", nodes: sourceNodes),
            .init(id: "target", nodes: targetNodes)
        ]
    }
}

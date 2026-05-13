import SwiftUI

public struct InsightAnomalyTableView: View {
    public let data: InsightWidgetData.AnomalyTable
    public let onCitationTapped: ((InsightCitation) -> Void)?
    public init(data: InsightWidgetData.AnomalyTable,
                onCitationTapped: ((InsightCitation) -> Void)? = nil) {
        self.data = data
        self.onCitationTapped = onCitationTapped
    }

    public var body: some View {
        VStack(spacing: 0) {
            if data.rows.isEmpty {
                InsightEmptyBodyView(message: "No anomalies in this window.")
            } else {
                ForEach(data.rows) { row in
                    rowView(row).padding(.vertical, 6)
                    Divider().opacity(0.4)
                }
            }
        }
    }

    private func rowView(_ row: InsightWidgetData.AnomalyTable.Row) -> some View {
        HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.sm) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(UnifiedDesignSystem.Colors.warning)
                    Text(row.label)
                        .font(UnifiedDesignSystem.Typography.caption)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                }
                if let detail = row.detail {
                    Text(detail)
                        .font(UnifiedDesignSystem.Typography.tiny)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                }
                if !row.citations.isEmpty {
                    InsightCitationsRow(citations: row.citations, onTap: onCitationTapped)
                }
            }
            Spacer(minLength: 4)
            Text(String(format: "z = %.2f", row.score))
                .font(UnifiedDesignSystem.Typography.tiny)
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
        }
    }
}

struct InsightCitationsRow: View {
    let citations: [InsightCitation]
    let onTap: ((InsightCitation) -> Void)?
    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(citations) { c in
                Button {
                    onTap?(c)
                } label: {
                    Text(c.label)
                        .font(UnifiedDesignSystem.Typography.tiny)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(UnifiedDesignSystem.Colors.whimsy.opacity(0.12)))
                        .foregroundStyle(UnifiedDesignSystem.Colors.whimsy)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Minimal wrap-around layout for citation chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let positions = positions(in: width, subviews: subviews)
        let maxY = positions.map(\.y).max() ?? 0
        let maxHeight = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: width, height: maxY + maxHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let positions = positions(in: bounds.width, subviews: subviews)
        for (idx, position) in positions.enumerated() {
            subviews[idx].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                                anchor: .topLeading, proposal: .unspecified)
        }
    }
    private func positions(in width: CGFloat, subviews: Subviews) -> [CGPoint] {
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, !positions.isEmpty {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return positions
    }
}

import SwiftUI

/// Wrapping flow layout — items flow left-to-right, wrapping to the next row.
/// Used for the provider cloud in onboarding.
struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = DesignSystem.Spacing.sm
    var verticalSpacing: CGFloat = DesignSystem.Spacing.sm

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        guard !rows.isEmpty else { return .zero }

        let height = rows.enumerated().reduce(CGFloat.zero) { acc, pair in
            let rowHeight = pair.element.map(\.size.height).max() ?? 0
            return acc + rowHeight + (pair.offset > 0 ? verticalSpacing : 0)
        }
        let width = proposal.width ?? rows.map { row in
            row.enumerated().reduce(CGFloat.zero) { acc, pair in
                acc + pair.element.size.width + (pair.offset > 0 ? horizontalSpacing : 0)
            }
        }.max() ?? 0

        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY

        for row in rows {
            let rowHeight = row.map(\.size.height).max() ?? 0
            // Center the row horizontally
            let rowWidth = row.enumerated().reduce(CGFloat.zero) { acc, pair in
                acc + pair.element.size.width + (pair.offset > 0 ? horizontalSpacing : 0)
            }
            // Clamp the centering offset to be non-negative so a row wider than
            // the available bounds (e.g. a single over-wide chip) starts at the
            // left edge instead of being centered off-screen and clipped.
            var x = bounds.minX + max(0, (bounds.width - rowWidth) / 2)

            for item in row {
                let yOffset = (rowHeight - item.size.height) / 2
                item.subview.place(
                    at: CGPoint(x: x, y: y + yOffset),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + horizontalSpacing
            }
            y += rowHeight + verticalSpacing
        }
    }

    private struct LayoutItem {
        let subview: LayoutSubview
        let size: CGSize
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutItem]] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[LayoutItem]] = [[]]
        var currentRowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: nil, height: nil))
            let itemWidth = size.width + (rows[rows.count - 1].isEmpty ? 0 : horizontalSpacing)

            if currentRowWidth + itemWidth > maxWidth, !rows[rows.count - 1].isEmpty {
                rows.append([])
                currentRowWidth = 0
            }

            rows[rows.count - 1].append(LayoutItem(subview: subview, size: size))
            currentRowWidth += (rows[rows.count - 1].count == 1 ? 0 : horizontalSpacing) + size.width
        }

        return rows
    }
}

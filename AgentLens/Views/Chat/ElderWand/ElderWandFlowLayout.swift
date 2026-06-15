import SwiftUI

// MARK: - Elder Wand Flow Layout
//
// A left-aligned wrapping layout for the model chip clouds in The Elder Wand
// configurator. Chips flow left-to-right and wrap onto a new row when the
// next chip would overflow the proposed width.
//
// Named `ElderWandFlowLayout` (not `FlowLayout`) on purpose: AgentLens already
// declares a top-level `struct FlowLayout: Layout` (Views/Onboarding) which is
// center-aligned and tuned for the onboarding provider cloud. Two top-level
// `FlowLayout`s in the same module is a redeclaration error, and the
// onboarding one centers rows — wrong for a left-reading picker — so this is a
// distinct, leading-aligned layout. (The plan's "make a fresh macOS one" is
// honored; only the symbol name differs to dodge the collision.)

/// Left-aligned wrapping flow layout. Subviews flow horizontally and wrap to a
/// new row when the next subview would exceed the proposed width. Rows are
/// vertically centered against the tallest item in the row.
struct ElderWandFlowLayout: Layout {
    var horizontalSpacing: CGFloat = DesignSystem.Spacing.sm
    var verticalSpacing: CGFloat = DesignSystem.Spacing.sm

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(maxWidth: proposal.width ?? .infinity, subviews: subviews)
        guard !rows.isEmpty else { return .zero }

        let height = rows.enumerated().reduce(CGFloat.zero) { partial, pair in
            let rowHeight = pair.element.map(\.size.height).max() ?? 0
            return partial + rowHeight + (pair.offset > 0 ? verticalSpacing : 0)
        }

        // When width is unconstrained, the natural width is the widest row.
        let width = proposal.width ?? rows.map { row in
            row.enumerated().reduce(CGFloat.zero) { partial, pair in
                partial + pair.element.size.width + (pair.offset > 0 ? horizontalSpacing : 0)
            }
        }.max() ?? 0

        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY

        for row in rows {
            let rowHeight = row.map(\.size.height).max() ?? 0
            var x = bounds.minX
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

    // MARK: - Row computation

    private struct LayoutItem {
        let subview: LayoutSubview
        let size: CGSize
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [[LayoutItem]] {
        var rows: [[LayoutItem]] = [[]]
        var currentRowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: nil, height: nil))
            let isRowEmpty = rows[rows.count - 1].isEmpty
            let projectedWidth = size.width + (isRowEmpty ? 0 : horizontalSpacing)

            if !isRowEmpty, currentRowWidth + projectedWidth > maxWidth {
                rows.append([])
                currentRowWidth = 0
            }

            let nowEmpty = rows[rows.count - 1].isEmpty
            rows[rows.count - 1].append(LayoutItem(subview: subview, size: size))
            currentRowWidth += size.width + (nowEmpty ? 0 : horizontalSpacing)
        }

        return rows.filter { !$0.isEmpty }
    }
}

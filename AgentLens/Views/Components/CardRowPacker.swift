import Foundation

// MARK: - Card Row Packer
//
// The row-packing rule shared by every span-aware card grid in the app.
//
// It was previously a private static on `ChartsReorderableGrid`, hard-typed to
// `[ChartCardConfig]` and hard-coded to two columns. The Control Deck needs the
// identical rule at two, three, and four columns, so the rule moves here as a
// pure function over spans and both grids call it. Nothing about the Charts
// page changes: `CardRowPacker.rows(spans:columns:)` at `columns: 2` reproduces
// the previous algorithm exactly, index for index.
//
// Pure, `Sendable`, and Foundation-only so it is unit-testable without a view
// (`CardRowPackerTests`).

enum CardRowPacker {

    /// Greedy left-to-right packing: each card takes `span` columns (clamped to
    /// `1...columns`); a card that does not fit in the current row starts a new
    /// one. Order is never reshuffled to improve the fit — the user's order is
    /// the contract, and a packer that reorders would make drag-to-reorder lie.
    ///
    /// - Returns: rows of indices into `spans`, in the original order.
    static func rows(spans: [Int], columns: Int) -> [[Int]] {
        let columnCount = max(1, columns)
        var rows: [[Int]] = []
        var current: [Int] = []
        var used = 0

        for (index, rawSpan) in spans.enumerated() {
            let span = min(columnCount, max(1, rawSpan))
            if used + span > columnCount, !current.isEmpty {
                rows.append(current)
                current = []
                used = 0
            }
            current.append(index)
            used += span
        }

        if !current.isEmpty {
            rows.append(current)
        }
        return rows
    }

    /// Width of a card spanning `span` columns, given the content width the row
    /// has to spend and the gutter between columns.
    ///
    /// Explicit widths, not `layoutPriority`: an `HStack` of children that all
    /// carry `.frame(maxWidth: .infinity)` divides space *equally* whatever
    /// their priority, so a span-2 card would silently render the same width as
    /// its span-1 neighbour and the whole span system would be decorative.
    static func width(span: Int, columns: Int, contentWidth: CGFloat, gutter: CGFloat) -> CGFloat {
        let columnCount = max(1, columns)
        let clampedSpan = CGFloat(min(columnCount, max(1, span)))
        let unit = (contentWidth - gutter * CGFloat(columnCount - 1)) / CGFloat(columnCount)
        return max(1, unit * clampedSpan + gutter * (clampedSpan - 1))
    }
}

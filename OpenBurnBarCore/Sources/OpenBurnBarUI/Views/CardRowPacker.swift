import CoreGraphics
import OpenBurnBarRecap

// MARK: - Card Row Packer
//
// The row-packing rule shared by every span-aware card grid in the app.
//
// It began as a private static on `ChartsReorderableGrid`, hard-coded to two
// columns, then moved to `AgentLens/Views/Components` when the Control Deck
// needed it at two, three, and four columns. It lives here now because the
// monthly recap deck needs the identical rule on both macOS and iOS, and a
// packer that exists once cannot drift between platforms. `AgentLens` keeps a
// type alias so its existing call sites are untouched.
//
// Pure, `Sendable`, and dependency-free so it stays unit-testable without a view.

public enum CardRowPacker {

    /// Greedy left-to-right packing: each card takes `span` columns (clamped to
    /// `1...columns`); a card that does not fit in the current row starts a new
    /// one. Order is never reshuffled to improve the fit — the given order is
    /// the contract, and a packer that reordered would make drag-to-reorder lie.
    ///
    /// - Returns: rows of indices into `spans`, in the original order.
    public static func rows(spans: [Int], columns: Int) -> [[Int]] {
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
    public static func width(
        span: Int,
        columns: Int,
        contentWidth: CGFloat,
        gutter: CGFloat
    ) -> CGFloat {
        let columnCount = max(1, columns)
        let clampedSpan = CGFloat(min(columnCount, max(1, span)))
        let unit = (contentWidth - gutter * CGFloat(columnCount - 1)) / CGFloat(columnCount)
        return max(1, unit * clampedSpan + gutter * (clampedSpan - 1))
    }
}

import Foundation

/// A deterministic, columnar grid layout for the widgets on a canvas.
///
/// macOS uses 12 columns; iPad projects to 6; iPhone to 2. The
/// projection is a pure function so the same canvas always reflows the
/// same way regardless of which device opens it.
public struct InsightLayout: Codable, Hashable, Sendable {
    /// Intended column count for the authoring platform.
    public var columnCount: Int
    /// Pt height of a single row.
    public var rowHeight: Double
    /// Pt gap between cells.
    public var gap: Double
    /// Widget-id → cell placement.
    public var placements: [UUID: CellPlacement]
    /// Monotonic counter bumped on every mutation; used to merge concurrent
    /// edits from another device (last-revision-wins).
    public var revision: Int

    public init(
        columnCount: Int = 12,
        rowHeight: Double = 96,
        gap: Double = 12,
        placements: [UUID: CellPlacement] = [:],
        revision: Int = 0
    ) {
        self.columnCount = max(1, columnCount)
        self.rowHeight = max(32, rowHeight)
        self.gap = max(0, gap)
        self.placements = placements
        self.revision = revision
    }

    /// Single widget placement.
    public struct CellPlacement: Codable, Hashable, Sendable {
        /// 0-indexed column.
        public var column: Int
        /// 0-indexed row.
        public var row: Int
        /// 1…columnCount.
        public var colSpan: Int
        /// ≥ 1.
        public var rowSpan: Int

        public init(column: Int, row: Int, colSpan: Int, rowSpan: Int) {
            self.column = max(0, column)
            self.row = max(0, row)
            self.colSpan = max(1, colSpan)
            self.rowSpan = max(1, rowSpan)
        }
    }

    /// Insert a new widget at the first free cell large enough to fit
    /// `defaultSpan`. Bumps `revision`.
    public mutating func placeNew(widgetID: UUID, defaultSpan: (columns: Int, rows: Int)) {
        let cols = min(max(1, defaultSpan.columns), columnCount)
        let rows = max(1, defaultSpan.rows)
        let occupancy = makeOccupancyGrid()
        let (c, r) = firstFreeCell(occupancy: occupancy, colSpan: cols, rowSpan: rows)
        placements[widgetID] = CellPlacement(column: c, row: r, colSpan: cols, rowSpan: rows)
        revision &+= 1
    }

    /// Move a widget to a new origin (column, row), clamping the spans so
    /// it stays inside the column count. Bumps `revision`.
    public mutating func move(widgetID: UUID, toColumn column: Int, toRow row: Int) {
        guard var current = placements[widgetID] else { return }
        current.column = max(0, min(column, columnCount - current.colSpan))
        current.row = max(0, row)
        placements[widgetID] = current
        revision &+= 1
    }

    /// Resize a widget by setting new spans. Clamped to fit columnCount.
    /// Bumps `revision`.
    public mutating func resize(widgetID: UUID, colSpan: Int, rowSpan: Int) {
        guard var current = placements[widgetID] else { return }
        let newCol = max(1, min(colSpan, columnCount))
        let newRow = max(1, rowSpan)
        current.colSpan = newCol
        current.rowSpan = newRow
        current.column = min(current.column, max(0, columnCount - newCol))
        placements[widgetID] = current
        revision &+= 1
    }

    /// Remove a widget's placement.
    public mutating func remove(widgetID: UUID) {
        if placements.removeValue(forKey: widgetID) != nil {
            revision &+= 1
        }
    }

    /// Total rows currently occupied (for sizing scroll content).
    public var rowCount: Int {
        placements.values.reduce(0) { max($0, $1.row + $1.rowSpan) }
    }

    /// Project to a different column count. The projection preserves
    /// widget order (row-major) and proportionally clamps spans, never
    /// causing overlaps.
    public func projected(toColumnCount targetCols: Int) -> InsightLayout {
        let target = max(1, targetCols)
        if target == columnCount { return self }

        // Stable order: top-to-bottom, then left-to-right, then by UUID.
        let ordered = placements
            .map { ($0.key, $0.value) }
            .sorted {
                if $0.1.row != $1.1.row { return $0.1.row < $1.1.row }
                if $0.1.column != $1.1.column { return $0.1.column < $1.1.column }
                return $0.0.uuidString < $1.0.uuidString
            }

        var projected: [UUID: CellPlacement] = [:]
        var cursorCol = 0
        var cursorRow = 0
        var rowMaxHeight = 0

        for (id, p) in ordered {
            // Proportional span, rounded, clamped.
            let proportional = Double(p.colSpan) * Double(target) / Double(max(1, columnCount))
            let span = max(1, min(target, Int(proportional.rounded())))

            // Wrap to next row if we can't fit.
            if cursorCol + span > target {
                cursorRow += max(1, rowMaxHeight)
                cursorCol = 0
                rowMaxHeight = 0
            }

            projected[id] = CellPlacement(
                column: cursorCol,
                row: cursorRow,
                colSpan: span,
                rowSpan: p.rowSpan
            )
            cursorCol += span
            rowMaxHeight = max(rowMaxHeight, p.rowSpan)
        }

        return InsightLayout(
            columnCount: target,
            rowHeight: rowHeight,
            gap: gap,
            placements: projected,
            revision: revision
        )
    }

    // MARK: - Private helpers

    /// Build a sparse [row][col] occupancy grid sized to the current spread.
    private func makeOccupancyGrid() -> [[Bool]] {
        let rows = rowCount + 1
        var grid = Array(repeating: Array(repeating: false, count: columnCount), count: max(rows, 1))
        for p in placements.values {
            for r in p.row..<min(p.row + p.rowSpan, grid.count) {
                for c in p.column..<min(p.column + p.colSpan, columnCount) {
                    grid[r][c] = true
                }
            }
        }
        return grid
    }

    /// Find the first row-major free rectangle of size `colSpan × rowSpan`.
    /// If no such rectangle exists within the current grid, append the
    /// widget at row `rowCount` (i.e. directly below the existing content).
    private func firstFreeCell(occupancy: [[Bool]], colSpan: Int, rowSpan: Int) -> (Int, Int) {
        let rows = occupancy.count
        for r in 0..<rows {
            if r + rowSpan > rows { break }
            for c in 0..<columnCount {
                if c + colSpan > columnCount { break }
                if rangeIsFree(occupancy: occupancy, c: c, r: r, colSpan: colSpan, rowSpan: rowSpan) {
                    return (c, r)
                }
            }
        }
        return (0, rowCount)
    }

    private func rangeIsFree(occupancy: [[Bool]], c: Int, r: Int, colSpan: Int, rowSpan: Int) -> Bool {
        for rr in r..<(r + rowSpan) {
            for cc in c..<(c + colSpan) {
                if occupancy[rr][cc] { return false }
            }
        }
        return true
    }
}

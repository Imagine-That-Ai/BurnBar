using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Presentation.Insights;

/// <summary>
/// A single widget placement in the columnar canvas grid — port of the Swift
/// <c>InsightLayout.CellPlacement</c>. Columns/rows are 0-indexed; spans are clamped ≥ 1 on
/// construction.
/// </summary>
public sealed record CellPlacement
{
    public CellPlacement(int column, int row, int colSpan, int rowSpan)
    {
        Column = Math.Max(0, column);
        Row = Math.Max(0, row);
        ColSpan = Math.Max(1, colSpan);
        RowSpan = Math.Max(1, rowSpan);
    }

    /// <summary>0-indexed column origin.</summary>
    public int Column { get; init; }

    /// <summary>0-indexed row origin.</summary>
    public int Row { get; init; }

    /// <summary>Width in columns (1…columnCount).</summary>
    public int ColSpan { get; init; }

    /// <summary>Height in rows (≥ 1).</summary>
    public int RowSpan { get; init; }
}

/// <summary>
/// A deterministic, columnar grid layout for the widgets on a canvas — a direct port of the
/// macOS <c>InsightLayout</c> (<c>OpenBurnBarCore/.../Insights/InsightLayout.swift</c>).
///
/// macOS uses 12 columns; a narrower host projects to fewer. Both the row-major
/// first-fit packing (<see cref="PlaceNew"/>) and the reflow (<see cref="Projected"/>) are
/// pure functions, so the same canvas always lays out the same way regardless of which host
/// opens it — which is exactly why the whole file is unit-tested on the macOS authoring host.
/// </summary>
public sealed class InsightLayout
{
    public InsightLayout(
        int columnCount = 12,
        double rowHeight = 96,
        double gap = 12,
        IReadOnlyDictionary<Guid, CellPlacement>? placements = null,
        int revision = 0)
    {
        ColumnCount = Math.Max(1, columnCount);
        RowHeight = Math.Max(32, rowHeight);
        Gap = Math.Max(0, gap);
        Placements = placements is null
            ? new Dictionary<Guid, CellPlacement>()
            : new Dictionary<Guid, CellPlacement>(placements);
        Revision = revision;
    }

    /// <summary>Intended column count for the authoring platform.</summary>
    public int ColumnCount { get; }

    /// <summary>Pt height of a single row.</summary>
    public double RowHeight { get; }

    /// <summary>Pt gap between cells.</summary>
    public double Gap { get; }

    /// <summary>Widget-id → cell placement.</summary>
    public Dictionary<Guid, CellPlacement> Placements { get; }

    /// <summary>Monotonic counter bumped on every mutation (last-revision-wins merge).</summary>
    public int Revision { get; private set; }

    /// <summary>Total rows currently occupied (for sizing scroll content).</summary>
    public int RowCount => Placements.Values.Aggregate(0, (acc, p) => Math.Max(acc, p.Row + p.RowSpan));

    /// <summary>
    /// Insert a widget at the first free cell large enough to fit <paramref name="defaultSpan"/>.
    /// Bumps <see cref="Revision"/>.
    /// </summary>
    public void PlaceNew(Guid widgetId, (int Columns, int Rows) defaultSpan)
    {
        int cols = Math.Min(Math.Max(1, defaultSpan.Columns), ColumnCount);
        int rows = Math.Max(1, defaultSpan.Rows);
        bool[][] occupancy = MakeOccupancyGrid();
        (int c, int r) = FirstFreeCell(occupancy, cols, rows);
        Placements[widgetId] = new CellPlacement(c, r, cols, rows);
        Revision++;
    }

    /// <summary>Move a widget origin, clamping the column so its span stays inside the grid.</summary>
    public void Move(Guid widgetId, int toColumn, int toRow)
    {
        if (!Placements.TryGetValue(widgetId, out CellPlacement? current))
        {
            return;
        }

        int column = Math.Max(0, Math.Min(toColumn, ColumnCount - current.ColSpan));
        int row = Math.Max(0, toRow);
        Placements[widgetId] = current with { Column = column, Row = row };
        Revision++;
    }

    /// <summary>Resize a widget's spans, clamped to fit the column count.</summary>
    public void Resize(Guid widgetId, int colSpan, int rowSpan)
    {
        if (!Placements.TryGetValue(widgetId, out CellPlacement? current))
        {
            return;
        }

        int newCol = Math.Max(1, Math.Min(colSpan, ColumnCount));
        int newRow = Math.Max(1, rowSpan);
        int clampedColumn = Math.Min(current.Column, Math.Max(0, ColumnCount - newCol));
        Placements[widgetId] = current with { ColSpan = newCol, RowSpan = newRow, Column = clampedColumn };
        Revision++;
    }

    /// <summary>Remove a widget's placement (bumps revision only if one existed).</summary>
    public void Remove(Guid widgetId)
    {
        if (Placements.Remove(widgetId))
        {
            Revision++;
        }
    }

    /// <summary>
    /// Project to a different column count. Preserves widget order (row-major, then column,
    /// then id) and proportionally clamps spans, never causing overlaps. Direct port of the
    /// Swift <c>projected(toColumnCount:)</c>.
    /// </summary>
    public InsightLayout Projected(int targetColumns)
    {
        int target = Math.Max(1, targetColumns);
        if (target == ColumnCount)
        {
            return this;
        }

        List<KeyValuePair<Guid, CellPlacement>> ordered = Placements
            .OrderBy(kv => kv.Value.Row)
            .ThenBy(kv => kv.Value.Column)
            .ThenBy(kv => kv.Key.ToString(), StringComparer.Ordinal)
            .ToList();

        var projected = new Dictionary<Guid, CellPlacement>();
        int cursorCol = 0;
        int cursorRow = 0;
        int rowMaxHeight = 0;

        foreach ((Guid id, CellPlacement p) in ordered.Select(kv => (kv.Key, kv.Value)))
        {
            double proportional = p.ColSpan * (double)target / Math.Max(1, ColumnCount);
            int span = Math.Max(1, Math.Min(target, (int)Math.Round(proportional, MidpointRounding.AwayFromZero)));

            if (cursorCol + span > target)
            {
                cursorRow += Math.Max(1, rowMaxHeight);
                cursorCol = 0;
                rowMaxHeight = 0;
            }

            projected[id] = new CellPlacement(cursorCol, cursorRow, span, p.RowSpan);
            cursorCol += span;
            rowMaxHeight = Math.Max(rowMaxHeight, p.RowSpan);
        }

        return new InsightLayout(target, RowHeight, Gap, projected, Revision);
    }

    /// <summary>Deep copy (used when stamping a template into a fresh canvas).</summary>
    public InsightLayout Clone() => new(ColumnCount, RowHeight, Gap, Placements, Revision);

    // ── Private helpers ──────────────────────────────────────────────────────────

    private bool[][] MakeOccupancyGrid()
    {
        int rows = RowCount + 1;
        int rowCount = Math.Max(rows, 1);
        var grid = new bool[rowCount][];
        for (int r = 0; r < rowCount; r++)
        {
            grid[r] = new bool[ColumnCount];
        }

        foreach (CellPlacement p in Placements.Values)
        {
            for (int r = p.Row; r < Math.Min(p.Row + p.RowSpan, grid.Length); r++)
            {
                for (int c = p.Column; c < Math.Min(p.Column + p.ColSpan, ColumnCount); c++)
                {
                    grid[r][c] = true;
                }
            }
        }

        return grid;
    }

    private (int Column, int Row) FirstFreeCell(bool[][] occupancy, int colSpan, int rowSpan)
    {
        int rows = occupancy.Length;
        for (int r = 0; r < rows; r++)
        {
            if (r + rowSpan > rows)
            {
                break;
            }

            for (int c = 0; c < ColumnCount; c++)
            {
                if (c + colSpan > ColumnCount)
                {
                    break;
                }

                if (RangeIsFree(occupancy, c, r, colSpan, rowSpan))
                {
                    return (c, r);
                }
            }
        }

        return (0, RowCount);
    }

    private static bool RangeIsFree(bool[][] occupancy, int c, int r, int colSpan, int rowSpan)
    {
        for (int rr = r; rr < r + rowSpan; rr++)
        {
            for (int cc = c; cc < c + colSpan; cc++)
            {
                if (occupancy[rr][cc])
                {
                    return false;
                }
            }
        }

        return true;
    }
}

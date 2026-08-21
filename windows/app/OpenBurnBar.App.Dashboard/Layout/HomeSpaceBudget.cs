using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Dashboard.Layout;

/// <summary>
/// One region a shell asks the canvas for.
/// A slot describes appetite, never geometry: what it cannot go below, what it
/// would like, how many more rows it could honestly fill, and how willing it is
/// to absorb leftover height. The canvas decides the numbers.
/// </summary>
public sealed class HomeSlot : IEquatable<HomeSlot>
{
    /// <summary>
    /// How much more real content a slot could show if the canvas can afford it.
    /// A slot with an appetite grows by revealing rows that already exist in the data
    /// and were being truncated; a slot without one grows by stretching.
    /// </summary>
    public sealed class RowAppetite : IEquatable<RowAppetite>
    {
        public int Available { get; }
        public int Baseline { get; }
        public double Unit { get; }
        public int Ceiling { get; }

        public RowAppetite(int available, int baseline, double unit, int ceiling)
        {
            Available = Math.Max(0, available);
            Baseline = Math.Max(0, Math.Min(baseline, Math.Max(0, available)));
            Unit = Math.Max(1.0, unit);
            Ceiling = Math.Max(0, ceiling);
        }

        /// <summary>The most rows this appetite can ever resolve to.</summary>
        public int Cap => Math.Min(Available, Ceiling);

        public bool Equals(RowAppetite? other)
        {
            if (other is null) return false;
            if (ReferenceEquals(this, other)) return true;
            return Available == other.Available &&
                   Baseline == other.Baseline &&
                   Math.Abs(Unit - other.Unit) < 0.0001 &&
                   Ceiling == other.Ceiling;
        }

        public override bool Equals(object? obj) => Equals(obj as RowAppetite);

        public override int GetHashCode() => HashCode.Combine(Available, Baseline, Unit, Ceiling);
    }

    public string Id { get; }
    public int Rank { get; }
    public double Floor { get; }
    public double Ideal { get; }
    public double Stretch { get; }
    public RowAppetite? Rows { get; }
    public bool IsAmbient { get; }
    public bool Spans { get; }

    public HomeSlot(
        string id,
        int rank = 0,
        double floor = 100,
        double? ideal = null,
        double stretch = 0,
        RowAppetite? rows = null,
        bool isAmbient = false,
        bool spans = false)
    {
        Id = id ?? throw new ArgumentNullException(nameof(id));
        Rank = rank;
        Floor = Math.Max(0, floor);
        Ideal = Math.Max(Math.Max(0, floor), ideal ?? floor);
        Stretch = Math.Max(0, stretch);
        Rows = rows;
        IsAmbient = isAmbient;
        Spans = spans;
    }

    public bool Equals(HomeSlot? other)
    {
        if (other is null) return false;
        if (ReferenceEquals(this, other)) return true;
        return Id == other.Id &&
               Rank == other.Rank &&
               Math.Abs(Floor - other.Floor) < 0.0001 &&
               Math.Abs(Ideal - other.Ideal) < 0.0001 &&
               Math.Abs(Stretch - other.Stretch) < 0.0001 &&
               Equals(Rows, other.Rows) &&
               IsAmbient == other.IsAmbient &&
               Spans == other.Spans;
    }

    public override bool Equals(object? obj) => Equals(obj as HomeSlot);

    public override int GetHashCode() => HashCode.Combine(Id, Rank, Floor, Ideal, Stretch, Rows, IsAmbient, Spans);
}

/// <summary>
/// What the canvas granted, ready to be rendered without further arithmetic.
/// </summary>
public sealed class HomeSpacePlan : IEquatable<HomeSpacePlan>
{
    public sealed class Placement : IEquatable<Placement>
    {
        public string Id { get; }
        public double? Height { get; }
        public int RowCount { get; }
        public int Column { get; }
        public bool IsVisible { get; }

        public Placement(string id, double? height, int rowCount, int column, bool isVisible)
        {
            Id = id ?? throw new ArgumentNullException(nameof(id));
            Height = height;
            RowCount = rowCount;
            Column = column;
            IsVisible = isVisible;
        }

        public bool Equals(Placement? other)
        {
            if (other is null) return false;
            if (ReferenceEquals(this, other)) return true;
            bool heightEq = (!Height.HasValue && !other.Height.HasValue) ||
                            (Height.HasValue && other.Height.HasValue && Math.Abs(Height.Value - other.Height.Value) < 0.001);
            return Id == other.Id &&
                   heightEq &&
                   RowCount == other.RowCount &&
                   Column == other.Column &&
                   IsVisible == other.IsVisible;
        }

        public override bool Equals(object? obj) => Equals(obj as Placement);

        public override int GetHashCode() => HashCode.Combine(Id, Height, RowCount, Column, IsVisible);
    }

    public IReadOnlyList<Placement> Placements { get; }
    public int Columns { get; }
    public bool Overflows { get; }
    public IReadOnlyList<string> SpanningIDs { get; }

    public HomeSpacePlan(
        IReadOnlyList<Placement> placements,
        int columns,
        bool overflows,
        IReadOnlyList<string> spanningIDs)
    {
        Placements = placements ?? Array.Empty<Placement>();
        Columns = columns;
        Overflows = overflows;
        SpanningIDs = spanningIDs ?? Array.Empty<string>();
    }

    public Placement? GetPlacement(string id) =>
        Placements.FirstOrDefault(p => string.Equals(p.Id, id, StringComparison.Ordinal));

    public int RowCount(string id, int fallback = 0) =>
        GetPlacement(id)?.RowCount ?? fallback;

    public double? Height(string id) =>
        GetPlacement(id)?.Height;

    public bool IsVisible(string id) =>
        GetPlacement(id)?.IsVisible ?? true;

    public IReadOnlyList<IReadOnlyList<string>> ColumnGroups
    {
        get
        {
            if (Columns <= 0) return Array.Empty<IReadOnlyList<string>>();
            var spanningSet = new HashSet<string>(SpanningIDs, StringComparer.Ordinal);
            var groups = new List<IReadOnlyList<string>>(Columns);
            for (int col = 0; col < Columns; col++)
            {
                int c = col;
                var members = Placements
                    .Where(p => p.Column == c && p.IsVisible && !spanningSet.Contains(p.Id))
                    .Select(p => p.Id)
                    .ToList();
                groups.Add(members);
            }
            return groups;
        }
    }

    public IReadOnlyList<string> VisibleSpanningIDs =>
        SpanningIDs.Where(IsVisible).ToList();

    public static readonly HomeSpacePlan Empty = new(
        Array.Empty<Placement>(),
        columns: 1,
        overflows: false,
        Array.Empty<string>());

    public bool Equals(HomeSpacePlan? other)
    {
        if (other is null) return false;
        if (ReferenceEquals(this, other)) return true;
        if (Columns != other.Columns || Overflows != other.Overflows) return false;
        if (Placements.Count != other.Placements.Count || SpanningIDs.Count != other.SpanningIDs.Count) return false;
        for (int i = 0; i < Placements.Count; i++)
        {
            if (!Placements[i].Equals(other.Placements[i])) return false;
        }
        for (int i = 0; i < SpanningIDs.Count; i++)
        {
            if (!string.Equals(SpanningIDs[i], other.SpanningIDs[i], StringComparison.Ordinal)) return false;
        }
        return true;
    }

    public override bool Equals(object? obj) => Equals(obj as HomeSpacePlan);

    public override int GetHashCode() => HashCode.Combine(Placements.Count, Columns, Overflows, SpanningIDs.Count);
}

/// <summary>
/// Standard reading width measures (prose properties, not page caps).
/// </summary>
public static class HomeReadingMeasure
{
    public const double Headline = 620;
    public const double Body = 680;
    public const double Editorial = 760;
}

/// <summary>
/// Resolves slot appetite against a canvas via Fit, Feed, Breathe passes.
/// Pure arithmetic on values; matches macOS HomeSpaceBudget.swift.
/// </summary>
public static class HomeSpaceBudget
{
    public const double TwoColumnWidth = 1080;
    public const double ThreeColumnWidth = 1580;
    public const double ColumnDeadBand = 60;

    /// <summary>
    /// How many columns this width supports, holding the current count inside the
    /// dead band so a drag across a threshold cannot flicker.
    /// </summary>
    public static int Columns(double width, int current, int slots)
    {
        if (width <= 0)
        {
            return Math.Max(1, Math.Min(current, Math.Max(1, slots)));
        }

        int ceiling = Math.Max(1, Math.Min(3, slots));
        int target;
        if (width >= ThreeColumnWidth + ColumnDeadBand)
        {
            target = 3;
        }
        else if (width <= ThreeColumnWidth - ColumnDeadBand)
        {
            if (width >= TwoColumnWidth + ColumnDeadBand)
            {
                target = 2;
            }
            else if (width <= TwoColumnWidth - ColumnDeadBand)
            {
                target = 1;
            }
            else
            {
                target = Math.Min(Math.Max(current, 1), 2);
            }
        }
        else
        {
            target = Math.Min(Math.Max(current, 2), 3);
        }

        return Math.Min(target, ceiling);
    }

    /// <summary>
    /// Deals slots into columns, balancing by ideal height.
    /// Rank order into the currently shortest column, ties go left.
    /// </summary>
    public static Dictionary<string, int> Deal(IReadOnlyList<HomeSlot> slots, int columns)
    {
        if (columns <= 1)
        {
            return slots.ToDictionary(s => s.Id, _ => 0, StringComparer.Ordinal);
        }

        var loads = new double[columns];
        var assignment = new Dictionary<string, int>(StringComparer.Ordinal);

        foreach (HomeSlot slot in slots.OrderBy(s => s.Rank))
        {
            int target = 0;
            for (int col = 1; col < columns; col++)
            {
                if (loads[col] < loads[target] - 0.5)
                {
                    target = col;
                }
            }
            assignment[slot.Id] = target;
            loads[target] += slot.Ideal;
        }

        return assignment;
    }

    /// <summary>
    /// Resolves slots against a canvas using Fit, Feed, Breathe.
    /// </summary>
    public static HomeSpacePlan Resolve(
        double canvasWidth,
        double canvasHeight,
        IReadOnlyList<HomeSlot> slots,
        double gutter,
        int requestedColumns = 1)
    {
        if (slots == null || slots.Count == 0)
        {
            return HomeSpacePlan.Empty;
        }

        int requested = Math.Max(1, requestedColumns);
        List<HomeSlot> spanning = requested > 1
            ? slots.Where(s => s.Spans).ToList()
            : new List<HomeSlot>();
        List<HomeSlot> columnar = requested > 1
            ? slots.Where(s => !s.Spans).ToList()
            : slots.ToList();
        List<string> spanningIDs = spanning.Select(s => s.Id).ToList();

        int columnCount = Math.Max(1, Math.Min(requested, Math.Max(1, columnar.Count)));
        Dictionary<string, int> assignment = Deal(columnar, columnCount);

        if (canvasHeight <= 0)
        {
            var zeroPlacements = slots.Select(slot => new HomeSpacePlan.Placement(
                id: slot.Id,
                height: null,
                rowCount: slot.Rows?.Baseline ?? 0,
                column: assignment.TryGetValue(slot.Id, out int col) ? col : 0,
                isVisible: true
            )).ToList();

            return new HomeSpacePlan(
                placements: zeroPlacements,
                columns: columnCount,
                overflows: true,
                spanningIDs: spanningIDs);
        }

        var placements = new List<HomeSpacePlan.Placement>();
        bool anyColumnOverflows = false;

        double bandHeight = spanning.Sum(s => s.Ideal) + gutter * spanning.Count;
        double columnHeight = canvasHeight - bandHeight;

        foreach (HomeSlot slot in spanning)
        {
            placements.Add(new HomeSpacePlan.Placement(
                id: slot.Id,
                height: slot.Ideal,
                rowCount: slot.Rows?.Baseline ?? 0,
                column: 0,
                isVisible: true));
        }

        for (int col = 0; col < columnCount; col++)
        {
            int c = col;
            var members = columnar.Where(s => assignment.TryGetValue(s.Id, out int colIdx) && colIdx == c).ToList();
            if (members.Count == 0) continue;

            ColumnResult resolved = ResolveColumn(members, columnHeight, gutter);
            anyColumnOverflows = anyColumnOverflows || resolved.Overflows;
            foreach (var p in resolved.Placements)
            {
                placements.Add(new HomeSpacePlan.Placement(
                    id: p.Id,
                    height: p.Height,
                    rowCount: p.RowCount,
                    column: c,
                    isVisible: p.IsVisible));
            }
        }

        if (anyColumnOverflows)
        {
            placements = placements.Select(p => new HomeSpacePlan.Placement(
                id: p.Id,
                height: p.IsVisible ? null : 0,
                rowCount: p.RowCount,
                column: p.Column,
                isVisible: p.IsVisible)).ToList();
        }

        var order = slots.Select((s, idx) => (s.Id, idx))
                         .ToDictionary(x => x.Id, x => x.idx, StringComparer.Ordinal);
        placements.Sort((a, b) =>
        {
            int orderA = order.TryGetValue(a.Id, out int idxA) ? idxA : 0;
            int orderB = order.TryGetValue(b.Id, out int idxB) ? idxB : 0;
            return orderA.CompareTo(orderB);
        });

        return new HomeSpacePlan(
            placements: placements,
            columns: columnCount,
            overflows: anyColumnOverflows,
            spanningIDs: spanningIDs);
    }

    private sealed class ColumnResult
    {
        public IReadOnlyList<(string Id, double? Height, int RowCount, bool IsVisible)> Placements { get; }
        public bool Overflows { get; }

        public ColumnResult(
            IReadOnlyList<(string Id, double? Height, int RowCount, bool IsVisible)> placements,
            bool overflows)
        {
            Placements = placements;
            Overflows = overflows;
        }
    }

    private static ColumnResult ResolveColumn(
        IReadOnlyList<HomeSlot> slots,
        double height,
        double gutter)
    {
        var kept = slots.ToList();
        double chrome = gutter * Math.Max(0, kept.Count - 1);
        double floors = kept.Sum(s => s.Floor);

        // Fit pass — ambient furniture yields first
        while (floors + chrome > height && kept.Any(s => s.IsAmbient))
        {
            int victim = kept.FindLastIndex(s => s.IsAmbient);
            if (victim < 0) break;
            floors -= kept[victim].Floor;
            kept.RemoveAt(victim);
            chrome = gutter * Math.Max(0, kept.Count - 1);
        }

        var keptIDs = new HashSet<string>(kept.Select(s => s.Id), StringComparer.Ordinal);
        var withheld = slots.Where(s => !keptIDs.Contains(s.Id)).ToList();

        if (floors + chrome > height)
        {
            var overflowPlacements = kept.Select(s => (s.Id, (double?)null, s.Rows?.Baseline ?? 0, true))
                .Concat(withheld.Select(s => (s.Id, (double?)0.0, 0, false)))
                .ToList();
            return new ColumnResult(overflowPlacements, overflows: true);
        }

        double slack = height - floors - chrome;
        var rowCounts = kept.ToDictionary(s => s.Id, s => s.Rows?.Baseline ?? 0, StringComparer.Ordinal);

        // Feed pass — round-robin across slots in rank order
        var feeding = kept.Where(s => s.Rows != null).OrderBy(s => s.Rank).ToList();
        bool fed = true;
        while (slack > 0 && fed)
        {
            fed = false;
            foreach (HomeSlot slot in feeding)
            {
                HomeSlot.RowAppetite appetite = slot.Rows!;
                if (rowCounts.TryGetValue(slot.Id, out int current) && current < appetite.Cap)
                {
                    if (slack >= appetite.Unit)
                    {
                        rowCounts[slot.Id] = current + 1;
                        slack -= appetite.Unit;
                        fed = true;
                    }
                }
            }
        }

        // Breathe pass — leftover slack becomes space
        double totalStretch = kept.Sum(s => s.Stretch);
        double totalIdeal = kept.Sum(s => s.Ideal);

        var resultPlacements = new List<(string Id, double? Height, int RowCount, bool IsVisible)>();
        foreach (HomeSlot slot in kept)
        {
            int currentRows = rowCounts[slot.Id];
            int baseline = slot.Rows?.Baseline ?? 0;
            int bought = currentRows - baseline;
            double earned = bought * (slot.Rows?.Unit ?? 0);

            double share;
            if (totalStretch > 0)
            {
                share = slack * (slot.Stretch / totalStretch);
            }
            else if (totalIdeal > 0)
            {
                share = slack * (slot.Ideal / totalIdeal);
            }
            else
            {
                share = slack / kept.Count;
            }

            resultPlacements.Add((slot.Id, slot.Floor + earned + share, currentRows, true));
        }

        foreach (HomeSlot slot in withheld)
        {
            resultPlacements.Add((slot.Id, 0.0, 0, false));
        }

        return new ColumnResult(resultPlacements, overflows: false);
    }
}

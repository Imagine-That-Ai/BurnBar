using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Presentation.DataControlCenter;

// PORTED (faithful) from the inventory Table sort + sidebar tier grouping + sealedFraction in
// AgentLens/Views/Settings/DataControlCenter/DataControlCenterView.swift and
// AgentLens/Services/DataControlCenterViewModel.swift.
//
// The Swift Table binds `sortOrder = [KeyPathComparator(\.bytes, order: .reverse)]` and re-sorts
// via `rows.sorted(using: sortOrder)`; the sidebar filters `rows.filter { $0.tier == tier }` into
// three tier sections; `sealedFraction` is a byte-weighted (count-fallback) share of non-server-
// readable data. All of that is pure and deterministic — extracted here so the Windows DataGrid
// Sorting event, the NavigationView tier sections, and the Basin fill all read ONE tested core.

/// <summary>A sortable inventory column. Matches the Swift Table's <c>value:</c> key paths.</summary>
public enum SortColumn
{
    /// <summary>By display title (Swift: <c>value: \.title</c>).</summary>
    Domain,

    /// <summary>By encryption tier ordinal (server-readable → zero-access → end-to-end).</summary>
    Tier,

    /// <summary>By live record count (Swift: <c>value: \.count</c>).</summary>
    Records,

    /// <summary>By stored bytes (Swift: <c>value: \.bytes</c>) — the launch default, descending.</summary>
    Stored,

    /// <summary>By retention token (Swift: <c>value: \.retention</c>).</summary>
    Retention,
}

/// <summary>Ascending / descending, matching SwiftUI <c>SortOrder.forward/.reverse</c>.</summary>
public enum SortDirection
{
    Ascending,
    Descending,
}

/// <summary>A column + direction pair. Swift: one <c>KeyPathComparator</c> in <c>sortOrder</c>.</summary>
public readonly record struct SortDescriptor(SortColumn Column, SortDirection Direction)
{
    /// <summary>The Swift launch default: <c>KeyPathComparator(\.bytes, order: .reverse)</c>.</summary>
    public static SortDescriptor Default => new(SortColumn.Stored, SortDirection.Descending);

    /// <summary>Toggle direction, or reset to a column's natural first direction when switching columns.</summary>
    public SortDescriptor ToggledFor(SortColumn column)
    {
        if (column != Column)
        {
            // First click on a new column: text columns start ascending, numeric start descending
            // (the biggest footprint first — the same intent as the byte-descending default).
            var firstDirection = column is SortColumn.Records or SortColumn.Stored
                ? SortDirection.Descending
                : SortDirection.Ascending;
            return new SortDescriptor(column, firstDirection);
        }

        return new SortDescriptor(
            column,
            Direction == SortDirection.Ascending ? SortDirection.Descending : SortDirection.Ascending);
    }
}

/// <summary>Pure inventory sort + tier grouping + sealed-fraction math.</summary>
public static class DataControlSorting
{
    /// <summary>Canonical tier ordinal used for the Tier sort + the tier-ordered sidebar.</summary>
    public static int TierOrdinal(EncryptionTier tier) => tier switch
    {
        EncryptionTier.ServerReadable => 0,
        EncryptionTier.ZeroAccess => 1,
        EncryptionTier.EndToEnd => 2,
        _ => 0,
    };

    /// <summary>
    /// Stable sort of the rows by the descriptor. Ties break on registry order (the incoming
    /// sequence), mirroring SwiftUI's stable <c>sorted(using:)</c>. Never mutates the input.
    /// </summary>
    public static IReadOnlyList<DomainRow> Sort(IEnumerable<DomainRow> rows, SortDescriptor descriptor)
    {
        if (rows is null)
        {
            throw new ArgumentNullException(nameof(rows));
        }

        // Preserve incoming order for tie-breaking, then apply an ordinal-stable OrderBy. Each arm
        // folds in `ThenBy(index)` so equal keys keep registry order (stable, like Swift's sort).
        var indexed = rows.Select((row, index) => (row, index)).ToList();

        IOrderedEnumerable<(DomainRow row, int index)> primary = descriptor.Column switch
        {
            SortColumn.Domain => Ascending(descriptor)
                ? indexed.OrderBy(e => e.row.Title, StringComparer.OrdinalIgnoreCase)
                : indexed.OrderByDescending(e => e.row.Title, StringComparer.OrdinalIgnoreCase),
            SortColumn.Tier => Ascending(descriptor)
                ? indexed.OrderBy(e => TierOrdinal(e.row.Tier))
                : indexed.OrderByDescending(e => TierOrdinal(e.row.Tier)),
            SortColumn.Records => Ascending(descriptor)
                ? indexed.OrderBy(e => e.row.Count)
                : indexed.OrderByDescending(e => e.row.Count),
            SortColumn.Stored => Ascending(descriptor)
                ? indexed.OrderBy(e => e.row.Bytes)
                : indexed.OrderByDescending(e => e.row.Bytes),
            SortColumn.Retention => Ascending(descriptor)
                ? indexed.OrderBy(e => e.row.Retention, StringComparer.OrdinalIgnoreCase)
                : indexed.OrderByDescending(e => e.row.Retention, StringComparer.OrdinalIgnoreCase),
            _ => indexed.OrderBy(e => e.index),
        };

        return primary.ThenBy(e => e.index).Select(e => e.row).ToList();
    }

    /// <summary>Rows for a single tier, in registry order. Swift: <c>rows.filter { $0.tier == tier }</c>.</summary>
    public static IReadOnlyList<DomainRow> FilterByTier(IEnumerable<DomainRow> rows, EncryptionTier tier) =>
        rows.Where(r => r.Tier == tier).ToList();

    /// <summary>
    /// The tier-grouped sidebar sections in the Swift order: End-to-end, Zero-access,
    /// Server-readable. Empty tiers are omitted, exactly like the Swift <c>tierSection</c> guard.
    /// </summary>
    public static IReadOnlyList<TierSection> TierSections(IEnumerable<DomainRow> rows)
    {
        var all = rows.ToList();
        var order = new[] { EncryptionTier.EndToEnd, EncryptionTier.ZeroAccess, EncryptionTier.ServerReadable };
        return order
            .Select(tier => new TierSection(tier, all.Where(r => r.Tier == tier).ToList()))
            .Where(section => section.Rows.Count > 0)
            .ToList();
    }

    /// <summary>
    /// The Basin "substance level": the fraction of the user's data that is SEALED (zero-access +
    /// end-to-end) by byte weight, falling back to record count when no byte sources report.
    /// Clamped to 0…1. Faithful port of Swift <c>sealedFraction</c>.
    /// </summary>
    public static double SealedFraction(IEnumerable<DomainRow> rows)
    {
        var all = rows.ToList();

        long sealedBytes = all.Where(r => r.Tier != EncryptionTier.ServerReadable).Sum(r => r.Bytes);
        long totalBytes = all.Sum(r => r.Bytes);
        if (totalBytes > 0)
        {
            return Clamp01((double)sealedBytes / totalBytes);
        }

        long sealedCount = all.Where(r => r.Tier != EncryptionTier.ServerReadable).Sum(r => (long)r.Count);
        long totalCount = all.Sum(r => (long)r.Count);
        return totalCount > 0 ? Clamp01((double)sealedCount / totalCount) : 0;
    }

    private static bool Ascending(SortDescriptor descriptor) => descriptor.Direction == SortDirection.Ascending;

    private static double Clamp01(double value) => value < 0 ? 0 : value > 1 ? 1 : value;
}

/// <summary>One tier group of the sidebar (a tier + its rows in registry order).</summary>
public sealed record TierSection(EncryptionTier Tier, IReadOnlyList<DomainRow> Rows);

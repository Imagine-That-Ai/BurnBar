using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace OpenBurnBar.App.Presentation.Calendar;

/// <summary>One card's persisted state: which card, whether shown, and how wide.</summary>
public sealed record CalendarCardConfig
{
    public CalendarCardConfig(CalendarCardKind kind, bool? isVisible = null, int? span = null)
    {
        Kind = kind;
        IsVisible = isVisible ?? true;
        Span = Math.Min(3, Math.Max(1, span ?? CalendarCardKindMetadata.DefaultSpan(kind)));
    }

    public CalendarCardKind Kind { get; }

    public bool IsVisible { get; set; }

    public int Span { get; set; }

    public string Id => CalendarCardKindMetadata.Id(Kind);
}

/// <summary>
/// The full panel layout: an ordered list of card configs, persisted as JSON.
/// Port of macOS <c>CalendarPageLayout</c> (<c>CalendarPageLayout.swift</c>) with
/// the same forward-compatible contract as <c>ChartsPageLayout</c> — unknown kinds
/// are dropped, missing kinds are appended with defaults, so upgrades never
/// clobber the user's arrangement. Pure + JSON-only so the persistence behavior
/// is unit-tested on the authoring host; the WinUI layer stores the encoded
/// string through the app's settings persistence.
/// </summary>
public sealed class CalendarPageLayout : IEquatable<CalendarPageLayout>
{
    private readonly List<CalendarCardConfig> _configs;

    public CalendarPageLayout(IEnumerable<CalendarCardConfig> configs)
    {
        _configs = Reconciled((configs ?? throw new ArgumentNullException(nameof(configs))).ToList());
    }

    /// <summary>Every registered card with default visibility/span, in registry order (fresh instance per call).</summary>
    public static CalendarPageLayout Default =>
        new(CalendarCardKindMetadata.All.Select(kind => new CalendarCardConfig(kind)));

    /// <summary>All card configs in display order (visible + hidden).</summary>
    public IReadOnlyList<CalendarCardConfig> Configs => _configs;

    /// <summary>Cards the grid actually renders, in order.</summary>
    public IReadOnlyList<CalendarCardConfig> VisibleConfigs =>
        _configs.Where(config => config.IsVisible).ToArray();

    /// <summary>Hidden cards, in order (drives the "Hidden Cards" restore menu).</summary>
    public IReadOnlyList<CalendarCardConfig> HiddenConfigs =>
        _configs.Where(config => !config.IsVisible).ToArray();

    // MARK: Mutations

    /// <summary>
    /// Moves <paramref name="kind"/> so it occupies the position currently held by
    /// <paramref name="target"/> (drag-to-reorder lands on a specific card, not an
    /// abstract index).
    /// </summary>
    public void Move(CalendarCardKind kind, CalendarCardKind target)
    {
        if (kind == target)
        {
            return;
        }

        int from = _configs.FindIndex(config => config.Kind == kind);
        int to = _configs.FindIndex(config => config.Kind == target);
        if (from < 0 || to < 0)
        {
            return;
        }

        CalendarCardConfig config = _configs[from];
        _configs.RemoveAt(from);
        _configs.Insert(to, config);
    }

    public void SetVisible(CalendarCardKind kind, bool visible)
    {
        CalendarCardConfig? config = _configs.FirstOrDefault(c => c.Kind == kind);
        if (config is not null)
        {
            config.IsVisible = visible;
        }
    }

    public void SetSpan(CalendarCardKind kind, int span)
    {
        CalendarCardConfig? config = _configs.FirstOrDefault(c => c.Kind == kind);
        if (config is not null)
        {
            config.Span = Math.Min(3, Math.Max(1, span));
        }
    }

    public void Reset()
    {
        _configs.Clear();
        _configs.AddRange(CalendarCardKindMetadata.All.Select(kind => new CalendarCardConfig(kind)));
    }

    // MARK: Row packing

    /// <summary>One packed row of the 3-column analytics grid.</summary>
    public sealed record Row(string Id, IReadOnlyList<CalendarCardConfig> Configs)
    {
        /// <summary>Columns this row occupies (≤ 3).</summary>
        public int SpanSum => Configs.Sum(config => Math.Min(3, Math.Max(1, config.Span)));
    }

    /// <summary>
    /// Packs configs greedily into rows up to 3 columns wide: a card joins the
    /// current row while the span sum stays ≤ 3, otherwise it starts a new row.
    /// Port of <c>CalendarAnalyticsPanel.rows(for:)</c>.
    /// </summary>
    public static IReadOnlyList<Row> PackRows(IEnumerable<CalendarCardConfig> configs)
    {
        var rows = new List<Row>();
        var current = new List<CalendarCardConfig>();
        int currentSpan = 0;
        foreach (CalendarCardConfig config in configs)
        {
            int span = Math.Min(3, Math.Max(1, config.Span));
            if (currentSpan + span > 3 && current.Count > 0)
            {
                rows.Add(new Row(string.Join("+", current.Select(c => c.Id)), current.ToArray()));
                current.Clear();
                currentSpan = 0;
            }

            current.Add(config);
            currentSpan += span;
        }

        if (current.Count > 0)
        {
            rows.Add(new Row(string.Join("+", current.Select(c => c.Id)), current.ToArray()));
        }

        return rows;
    }

    // MARK: Persistence

    private sealed class RawConfig
    {
        [JsonPropertyName("kind")]
        public string? Kind { get; set; }

        [JsonPropertyName("isVisible")]
        public bool? IsVisible { get; set; }

        [JsonPropertyName("span")]
        public int? Span { get; set; }
    }

    /// <summary>JSON round-trip tolerant of unknown kinds. See type comment.</summary>
    public static CalendarPageLayout Decode(string? json)
    {
        if (string.IsNullOrWhiteSpace(json))
        {
            return Default;
        }

        List<RawConfig>? raw;
        try
        {
            raw = JsonSerializer.Deserialize<List<RawConfig>>(json);
        }
        catch (JsonException)
        {
            return Default;
        }

        if (raw is null)
        {
            return Default;
        }

        var known = new List<CalendarCardConfig>();
        foreach (RawConfig entry in raw)
        {
            if (CalendarCardKindMetadata.KindForId(entry.Kind) is { } kind)
            {
                known.Add(new CalendarCardConfig(kind, entry.IsVisible, entry.Span));
            }
        }

        return new CalendarPageLayout(known);
    }

    /// <summary>Encodes the layout as a JSON array matching the macOS wire shape.</summary>
    public string Encode()
    {
        var raw = _configs.Select(config => new RawConfig
        {
            Kind = CalendarCardKindMetadata.Id(config.Kind),
            IsVisible = config.IsVisible,
            Span = config.Span,
        });
        return JsonSerializer.Serialize(raw);
    }

    /// <summary>Deduplicates and appends any kinds missing so every registered card has exactly one slot.</summary>
    private static List<CalendarCardConfig> Reconciled(List<CalendarCardConfig> configs)
    {
        var seen = new HashSet<CalendarCardKind>();
        var result = new List<CalendarCardConfig>();
        foreach (CalendarCardConfig config in configs)
        {
            if (seen.Add(config.Kind))
            {
                result.Add(config);
            }
        }

        foreach (CalendarCardKind kind in CalendarCardKindMetadata.All)
        {
            if (!seen.Contains(kind))
            {
                result.Add(new CalendarCardConfig(kind));
            }
        }

        return result;
    }

    public bool Equals(CalendarPageLayout? other) =>
        other is not null
        && _configs.Count == other._configs.Count
        && _configs.Zip(other._configs).All(pair =>
            pair.First.Kind == pair.Second.Kind
            && pair.First.IsVisible == pair.Second.IsVisible
            && pair.First.Span == pair.Second.Span);

    public override bool Equals(object? obj) => Equals(obj as CalendarPageLayout);

    public override int GetHashCode() => _configs.Count;
}

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace OpenBurnBar.App.CursorConnector;

// ── Usage-log consumer ───────────────────────────────────────────────────────
//
// Faithful Windows peer of the parsing half of
// CursorConnectorManager.consumeUsageLogChunk. The Mac reads a delta of the
// usage JSONL (one JSON object per line) emitted by the proxy, and for every
// well-formed line derives a RoutedUsageEvent for the UI ticker plus a persisted
// TokenUsage row (id = deterministicUUID(request_id)). The DataStore insert +
// UI-list trimming are runtime concerns that live in the session/host; THIS
// portable core does the pure transform — line → (skip | RoutedUsageEvent) — plus
// the two deterministic helpers it needs (stable id, ISO timestamp).

/// <summary>
/// Pluggable cost calculator. Windows peer of the Mac's
/// <c>ModelPricing.lookup(model:).cost(...)</c>. The portable core does not carry
/// the pricing catalog, so cost is injected; the default is zero.
/// </summary>
public interface IUsageCostCalculator
{
    /// <summary>Cost in USD for a normalized usage record.</summary>
    double Cost(string model, NormalizedUsageEvent usage);
}

/// <summary>A cost calculator that always returns zero.</summary>
public sealed class ZeroUsageCostCalculator : IUsageCostCalculator
{
    /// <summary>Shared zero-cost instance.</summary>
    public static readonly ZeroUsageCostCalculator Instance = new();

    /// <inheritdoc />
    public double Cost(string model, NormalizedUsageEvent usage) => 0;
}

/// <summary>Parses connector usage-log JSONL deltas into routed usage events.</summary>
public sealed class UsageLogConsumer
{
    private readonly IUsageCostCalculator _costCalculator;
    private readonly IConnectorClock _clock;

    /// <summary>Creates a consumer with the given cost calculator and clock.</summary>
    public UsageLogConsumer(IUsageCostCalculator? costCalculator = null, IConnectorClock? clock = null)
    {
        _costCalculator = costCalculator ?? ZeroUsageCostCalculator.Instance;
        _clock = clock ?? SystemConnectorClock.Instance;
    }

    /// <summary>
    /// Swift <c>consumeUsageLogChunk</c> parse loop: split on newlines, skip lines
    /// that are not a JSON object carrying <c>request_id</c> + a known
    /// <c>provider</c> + <c>model</c>, and project the rest to RoutedUsageEvent in
    /// file order.
    /// </summary>
    public IReadOnlyList<RoutedUsageEvent> Consume(string text)
    {
        if (text is null)
        {
            throw new ArgumentNullException(nameof(text));
        }

        var events = new List<RoutedUsageEvent>();
        foreach (var rawLine in text.Split('\n'))
        {
            if (TryParseLine(rawLine, out var usageEvent))
            {
                events.Add(usageEvent);
            }
        }

        return events;
    }

    private bool TryParseLine(string line, out RoutedUsageEvent usageEvent)
    {
        usageEvent = default!;

        // Swift `line.split(separator: "\n")` drops empties; mirror by skipping blanks.
        if (string.IsNullOrEmpty(line))
        {
            return false;
        }

        JsonElement json;
        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(line);
        }
        catch (JsonException)
        {
            return false;
        }

        using (document)
        {
            json = document.RootElement;
            if (json.ValueKind != JsonValueKind.Object)
            {
                return false;
            }

            if (!TryGetString(json, "request_id", out _)
                || !TryGetString(json, "provider", out var providerRaw)
                || ConnectorProviderRawValue.FromRaw(providerRaw) is not { } provider
                || !TryGetString(json, "model", out var model))
            {
                return false;
            }

            var normalized = UsageEventNormalizer.Normalize(json);
            var timestamp = ParseTimestamp(json);
            var cost = _costCalculator.Cost(model, normalized);

            usageEvent = new RoutedUsageEvent(
                provider,
                model,
                normalized.PromptTokens,
                normalized.CompletionTokens,
                normalized.CacheCreationTokens,
                normalized.CacheReadTokens,
                normalized.TotalTokens,
                cost,
                timestamp);
            return true;
        }
    }

    private DateTimeOffset ParseTimestamp(JsonElement json)
    {
        // Swift: (json["timestamp"] as? String).flatMap(isoDateFormatter.date) ?? Date().
        // The Mac formatter is ISO-8601 internet-date-time WITH fractional seconds;
        // a value it can't parse falls back to "now". We accept the ISO forms
        // .NET round-trips (fractional seconds optional) and otherwise fall back.
        if (TryGetString(json, "timestamp", out var raw)
            && DateTimeOffset.TryParse(
                raw,
                CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal,
                out var parsed))
        {
            return parsed;
        }

        return _clock.UtcNow;
    }

    private static bool TryGetString(JsonElement json, string key, out string value)
    {
        if (json.TryGetProperty(key, out var element) && element.ValueKind == JsonValueKind.String)
        {
            value = element.GetString() ?? string.Empty;
            return true;
        }

        value = string.Empty;
        return false;
    }

    /// <summary>
    /// Swift <c>deterministicUUID(for:)</c> — the raw 16 MD5 bytes laid out as a
    /// canonical UUID string (NOT the little-endian .NET <c>new Guid(byte[])</c>
    /// layout), so the derived identity matches the Mac byte-for-byte.
    /// </summary>
    public static Guid DeterministicId(string value)
    {
        var digest = MD5.HashData(Encoding.UTF8.GetBytes(value));
        var hex = HexToken.Encode(digest);
        var canonical =
            hex.Substring(0, 8) + "-" +
            hex.Substring(8, 4) + "-" +
            hex.Substring(12, 4) + "-" +
            hex.Substring(16, 4) + "-" +
            hex.Substring(20, 12);
        return Guid.ParseExact(canonical, "D");
    }
}

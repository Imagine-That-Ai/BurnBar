using System;
using System.Globalization;
using System.Text.Json;

namespace OpenBurnBar.App.Presentation.Quota;

// Shared JSON scalar-extraction primitives for the portable quota parsers.
//
// Faithful port of the exact-key, first-match helpers the macOS adapters use:
//   • AgentLens/Services/ProviderQuota/ClaudeOAuthUsageFetcher.swift
//       ClaudeRateLimits.firstNumber(in:keys:) / firstDate(in:keys:)
//   • AgentLens/Services/ProviderQuota/FlexibleQuotaBucketNormalizer.swift
//       sanitizeKey(_:) + the numeric/date coercions (number/string/unix).
//
// These reproduce the Swift semantics value-for-value: a number decodes as a
// Double, a numeric string parses as a Double, a date is ISO-8601 (with or
// without fractional seconds) or a unix timestamp. Only the specific parsers
// that use EXACT keys are ported here; the fuzzy key matcher
// (FlexibleQuotaBucketNormalizer.value(in:matching:)) belongs to the flexible
// response-body mechanism which is scheduled with the remaining adapters.

/// <summary>Exact-key, first-match scalar readers over a <see cref="JsonElement"/> object.</summary>
public static class QuotaJson
{
    /// <summary>
    /// Parse UTF-8 JSON text into a root <see cref="JsonElement"/>. Returns
    /// <c>null</c> when the text is not valid JSON (Swift: the
    /// <c>try? JSONSerialization.jsonObject</c> guards that fall back to empty).
    /// </summary>
    public static JsonElement? TryParse(string json)
    {
        if (string.IsNullOrWhiteSpace(json))
        {
            return null;
        }

        try
        {
            using var document = JsonDocument.Parse(json);
            // Clone so the element survives disposal of the document.
            return document.RootElement.Clone();
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>Exact-key property lookup on a JSON object (case-sensitive, like a Swift dictionary).</summary>
    public static bool TryGetProperty(JsonElement obj, string key, out JsonElement value)
    {
        if (obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(key, out value))
        {
            return true;
        }

        value = default;
        return false;
    }

    /// <summary>
    /// First numeric value among <paramref name="keys"/>. Mirrors
    /// <c>ClaudeRateLimits.firstNumber</c> / <c>FlexibleQuotaBucketNormalizer.number</c>:
    /// a JSON number, or a numeric string, coerces to a Double.
    /// </summary>
    public static double? FirstNumber(JsonElement obj, params string[] keys)
    {
        if (obj.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        foreach (var key in keys)
        {
            if (!obj.TryGetProperty(key, out var value))
            {
                continue;
            }

            if (value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var number))
            {
                return number;
            }

            if (value.ValueKind == JsonValueKind.String
                && double.TryParse(value.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed))
            {
                return parsed;
            }
        }

        return null;
    }

    /// <summary>
    /// First date among <paramref name="keys"/>. Mirrors <c>ClaudeRateLimits.firstDate</c>:
    /// a JSON number is unix seconds; a string is ISO-8601 (optionally fractional) or unix seconds.
    /// </summary>
    public static DateTimeOffset? FirstDate(JsonElement obj, params string[] keys)
    {
        if (obj.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        foreach (var key in keys)
        {
            if (!obj.TryGetProperty(key, out var value))
            {
                continue;
            }

            switch (value.ValueKind)
            {
                case JsonValueKind.Number when value.TryGetDouble(out var seconds):
                    return UnixSecondsToDate(seconds);
                case JsonValueKind.String:
                    var text = value.GetString();
                    if (ParseIso8601(text) is DateTimeOffset iso)
                    {
                        return iso;
                    }

                    if (double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var unix))
                    {
                        return UnixSecondsToDate(unix);
                    }

                    break;
            }
        }

        return null;
    }

    /// <summary>
    /// Parse an ISO-8601 timestamp with or without fractional seconds, mirroring the two
    /// <c>ISO8601DateFormatter</c> instances the Swift helpers try in order.
    /// Returns <c>null</c> for non-ISO strings.
    /// </summary>
    public static DateTimeOffset? ParseIso8601(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return null;
        }

        if (DateTimeOffset.TryParse(
                text,
                CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind | DateTimeStyles.AssumeUniversal,
                out var parsed))
        {
            // Only accept genuine ISO-8601 date-time strings — a bare "1720000000"
            // parses as a number elsewhere, never here.
            if (text.Contains('T') || text.Contains('-') || text.Contains(':'))
            {
                return parsed.ToUniversalTime();
            }
        }

        return null;
    }

    /// <summary>
    /// Convert unix seconds (integer or fractional) to a UTC instant, matching Swift
    /// <c>Date(timeIntervalSince1970:)</c>.
    /// </summary>
    public static DateTimeOffset UnixSecondsToDate(double seconds)
    {
        var milliseconds = (long)Math.Round(seconds * 1000.0, MidpointRounding.AwayFromZero);
        return DateTimeOffset.FromUnixTimeMilliseconds(milliseconds);
    }

    /// <summary>
    /// Lower-cases and normalises a label into a bucket-key fragment, faithful to
    /// <c>FlexibleQuotaBucketNormalizer.sanitizeKey</c> (spaces/slashes → '-', parens dropped).
    /// </summary>
    public static string SanitizeKey(string value)
    {
        return value
            .ToLowerInvariant()
            .Replace(" ", "-", StringComparison.Ordinal)
            .Replace("/", "-", StringComparison.Ordinal)
            .Replace("(", string.Empty, StringComparison.Ordinal)
            .Replace(")", string.Empty, StringComparison.Ordinal);
    }
}

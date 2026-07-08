using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Text.Json;

namespace OpenBurnBar.App.MemorySearch.Memory;

// PORTED (faithful) from
//   AgentLens/Services/Memory/MemoryExtractionParser.swift  (parser + ExtractedMemoryCandidate)
//   OpenBurnBarCore/.../Memory/MemoryServing.swift          (enum MemoryKind)
//
// The Swift parser is deliberately strict + lossy: clean-JSON-first, then a bounded
// first-'{' … last-'}' brace-slice fallback for prose-wrapped replies; each candidate field is
// `try?`-decoded so a malformed field is DROPPED/nulled, not a hard error, and a non-object array
// element yields an all-nil (discarded) candidate. Reproduced here with a manual System.Text.Json
// walk because System.Text.Json is strict by default. An empty/unparseable body yields [].

/// <summary>Memory classification. Swift: <c>enum MemoryKind</c> (MemoryServing.swift). Raw-value
/// parity with the lowercase Swift String rawValues.</summary>
public enum MemoryKind
{
    Fact,
    Preference,
    Event,
    Profile,
    Relationship,
    Other,
}

/// <summary>Lowercase raw-value parity + case-insensitive parse. Swift: the <c>String</c>-backed enum.</summary>
public static class MemoryKindExtensions
{
    public static string RawValue(this MemoryKind kind) => kind switch
    {
        MemoryKind.Fact => "fact",
        MemoryKind.Preference => "preference",
        MemoryKind.Event => "event",
        MemoryKind.Profile => "profile",
        MemoryKind.Relationship => "relationship",
        _ => "other",
    };

    /// <summary>Maps a raw value to a kind; unrecognized (or null) → <see cref="MemoryKind.Fact"/>,
    /// matching the parser's <c>MemoryKind(rawValue:) ?? .fact</c>.</summary>
    public static MemoryKind ParseKindOrFact(string? rawLowercased) => rawLowercased switch
    {
        "fact" => MemoryKind.Fact,
        "preference" => MemoryKind.Preference,
        "event" => MemoryKind.Event,
        "profile" => MemoryKind.Profile,
        "relationship" => MemoryKind.Relationship,
        "other" => MemoryKind.Other,
        _ => MemoryKind.Fact,
    };
}

/// <summary>One validated candidate. Swift: <c>struct ExtractedMemoryCandidate</c>.
/// <see cref="ClaimedMessageId"/> is only a lookup key; the worker recomputes provenance.</summary>
public sealed record ExtractedMemoryCandidate(
    string Text,
    MemoryKind Kind,
    double Confidence,
    string? ClaimedMessageId);

/// <summary>Strict-JSON parser for the model's extraction output. Swift: <c>enum MemoryExtractionParser</c>.</summary>
public static class MemoryExtractionParser
{
    /// <summary>Max characters retained for a single fact body. Swift: <c>maxFactChars = 1_000</c>.</summary>
    public const int MaxFactChars = 1_000;

    private readonly record struct RawMemory(string? Text, string? Kind, double? Confidence, string? MessageId);

    /// <summary>Parse <paramref name="text"/> into validated candidates, capped at
    /// <paramref name="maxCandidates"/>. Swift: <c>parse(_:maxCandidates:)</c>.</summary>
    public static List<ExtractedMemoryCandidate> Parse(string text, int maxCandidates)
    {
        ArgumentNullException.ThrowIfNull(text);
        var payload = DecodePayload(text);
        if (payload == null)
        {
            return new List<ExtractedMemoryCandidate>();
        }

        int cap = Math.Max(0, maxCandidates);
        if (cap <= 0)
        {
            return new List<ExtractedMemoryCandidate>();
        }

        var results = new List<ExtractedMemoryCandidate>();
        foreach (var raw in payload)
        {
            if (results.Count >= cap)
            {
                break;
            }

            var candidate = Validate(raw);
            if (candidate != null)
            {
                results.Add(candidate);
            }
        }

        return results;
    }

    private static List<RawMemory>? DecodePayload(string text)
    {
        string trimmed = text.Trim();
        if (trimmed.Length == 0)
        {
            return null;
        }

        var decoded = TryDecode(trimmed);
        if (decoded != null)
        {
            return decoded;
        }

        // Fallback: slice the outermost JSON object out of a prose-wrapped reply.
        int start = trimmed.IndexOf('{');
        int end = trimmed.LastIndexOf('}');
        if (start < 0 || end < 0 || start >= end)
        {
            return null;
        }

        string candidate = trimmed.Substring(start, end - start + 1);
        return TryDecode(candidate);
    }

    /// <summary>
    /// Decodes into a memories list ONLY when the top-level JSON is an object (Swift's
    /// <c>decoder.container(keyedBy:)</c> is non-optional); otherwise returns null so the caller
    /// falls through to the brace slice. A missing/non-array <c>memories</c> → empty list.
    /// </summary>
    private static List<RawMemory>? TryDecode(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                return null;
            }

            var memories = new List<RawMemory>();
            if (root.TryGetProperty("memories", out var memoriesElement)
                && memoriesElement.ValueKind == JsonValueKind.Array)
            {
                foreach (var element in memoriesElement.EnumerateArray())
                {
                    memories.Add(ReadMemory(element));
                }
            }

            return memories;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static RawMemory ReadMemory(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            // Non-object array element → all-nil (Swift's keyed-container fallback).
            return new RawMemory(null, null, null, null);
        }

        return new RawMemory(
            ReadString(element, "text"),
            ReadString(element, "kind"),
            ReadDouble(element, "confidence"),
            ReadString(element, "messageId"));
    }

    private static string? ReadString(JsonElement element, string name)
    {
        // Swift `try? decode(String)` only succeeds for a JSON string.
        return element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;
    }

    private static double? ReadDouble(JsonElement element, string name)
    {
        // Swift `try? decode(Double)` only succeeds for a JSON number.
        if (element.TryGetProperty(name, out var value)
            && value.ValueKind == JsonValueKind.Number
            && value.TryGetDouble(out double parsed))
        {
            return parsed;
        }

        return null;
    }

    private static ExtractedMemoryCandidate? Validate(RawMemory raw)
    {
        if (raw.Text == null)
        {
            return null;
        }

        string body = raw.Text.Trim();
        if (body.Length == 0)
        {
            return null;
        }

        string bounded = GraphemePrefix(body, MaxFactChars);
        MemoryKind kind = MemoryKindExtensions.ParseKindOrFact(raw.Kind?.ToLowerInvariant() ?? string.Empty);
        double confidence = ClampConfidence(raw.Confidence);

        string? messageId = raw.MessageId?.Trim();
        string? normalizedMessageId = !string.IsNullOrEmpty(messageId) ? messageId : null;

        return new ExtractedMemoryCandidate(bounded, kind, confidence, normalizedMessageId);
    }

    /// <summary>nil or non-finite → 0.5; else clamped to [0,1]. Swift: <c>clampConfidence(_:)</c>.</summary>
    public static double ClampConfidence(double? value)
    {
        if (value is not double v || !double.IsFinite(v))
        {
            return 0.5;
        }

        return Math.Min(Math.Max(v, 0.0), 1.0);
    }

    private static string GraphemePrefix(string value, int count)
    {
        if (value.Length <= count)
        {
            return value;
        }

        var builder = new StringBuilder();
        var enumerator = StringInfo.GetTextElementEnumerator(value);
        int taken = 0;
        while (taken < count && enumerator.MoveNext())
        {
            builder.Append((string)enumerator.Current);
            taken++;
        }

        return builder.ToString();
    }
}

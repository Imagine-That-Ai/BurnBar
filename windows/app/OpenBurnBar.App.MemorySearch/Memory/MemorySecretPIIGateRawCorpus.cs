using System;
using System.Collections.Generic;
using System.Text.Json;

namespace OpenBurnBar.App.MemorySearch.Memory;

// PORTED (faithful) from the RawCorpus Decodable in
// OpenBurnBarCore/.../Memory/MemorySecretPIIGate.swift.
//
// Swift's RawCorpus is STRICT on required fields (id/label/kind/regex, version, patterns): a missing
// required field throws during decode, which the loader turns into a fail-closed Unavailable corpus.
// System.Text.Json is lenient by default, so this does a manual JsonDocument walk and returns null
// (→ Unavailable) when a required field is absent or the JSON is malformed.

internal sealed class RawCorpus
{
    internal sealed record RawPattern(
        string Id,
        string Label,
        string Kind,
        string Regex,
        bool? CaseInsensitive,
        bool? DotMatchesNewlines,
        bool? AnchorsMatchLines,
        string? Validator);

    internal sealed record RawEntropy(
        bool Enabled,
        string Label,
        string? Kind,
        int MinLength,
        int MaxLength,
        double MinShannonEntropy);

    internal sealed record RawDecoding(bool Enabled, int MaxCandidates, int MaxDecodedBytes);

    internal string Version { get; }

    internal IReadOnlyList<RawPattern> Patterns { get; }

    internal RawEntropy? Entropy { get; }

    internal RawEntropy? HexEntropy { get; }

    internal RawDecoding? Decoding { get; }

    private RawCorpus(
        string version,
        IReadOnlyList<RawPattern> patterns,
        RawEntropy? entropy,
        RawEntropy? hexEntropy,
        RawDecoding? decoding)
    {
        Version = version;
        Patterns = patterns;
        Entropy = entropy;
        HexEntropy = hexEntropy;
        Decoding = decoding;
    }

    internal static RawCorpus? TryDecode(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                return null;
            }

            if (!TryGetString(root, "version", out string version)
                || !root.TryGetProperty("patterns", out var patternsElement)
                || patternsElement.ValueKind != JsonValueKind.Array)
            {
                return null;
            }

            var patterns = new List<RawPattern>();
            foreach (var element in patternsElement.EnumerateArray())
            {
                if (element.ValueKind != JsonValueKind.Object
                    || !TryGetString(element, "id", out string id)
                    || !TryGetString(element, "label", out string label)
                    || !TryGetString(element, "kind", out string kind)
                    || !TryGetString(element, "regex", out string regex))
                {
                    return null;
                }

                patterns.Add(new RawPattern(
                    id,
                    label,
                    kind,
                    regex,
                    GetOptionalBool(element, "caseInsensitive"),
                    GetOptionalBool(element, "dotMatchesNewlines"),
                    GetOptionalBool(element, "anchorsMatchLines"),
                    GetOptionalString(element, "validator")));
            }

            return new RawCorpus(
                version,
                patterns,
                ParseEntropy(root, "entropy"),
                ParseEntropy(root, "hexEntropy"),
                ParseDecoding(root));
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static RawEntropy? ParseEntropy(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out var element) || element.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        if (!TryGetBool(element, "enabled", out bool enabled)
            || !TryGetString(element, "label", out string label)
            || !TryGetInt(element, "minLength", out int minLength)
            || !TryGetInt(element, "maxLength", out int maxLength)
            || !TryGetDouble(element, "minShannonEntropy", out double minEntropy))
        {
            return null;
        }

        return new RawEntropy(enabled, label, GetOptionalString(element, "kind"), minLength, maxLength, minEntropy);
    }

    private static RawDecoding? ParseDecoding(JsonElement root)
    {
        if (!root.TryGetProperty("decoding", out var element) || element.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        if (!TryGetBool(element, "enabled", out bool enabled)
            || !TryGetInt(element, "maxCandidates", out int maxCandidates)
            || !TryGetInt(element, "maxDecodedBytes", out int maxDecodedBytes))
        {
            return null;
        }

        return new RawDecoding(enabled, maxCandidates, maxDecodedBytes);
    }

    private static bool TryGetString(JsonElement element, string name, out string value)
    {
        if (element.TryGetProperty(name, out var property) && property.ValueKind == JsonValueKind.String)
        {
            value = property.GetString()!;
            return true;
        }

        value = string.Empty;
        return false;
    }

    private static string? GetOptionalString(JsonElement element, string name) =>
        element.TryGetProperty(name, out var property) && property.ValueKind == JsonValueKind.String
            ? property.GetString()
            : null;

    private static bool? GetOptionalBool(JsonElement element, string name)
    {
        if (!element.TryGetProperty(name, out var property))
        {
            return null;
        }

        return property.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            _ => null,
        };
    }

    private static bool TryGetBool(JsonElement element, string name, out bool value)
    {
        if (element.TryGetProperty(name, out var property))
        {
            if (property.ValueKind == JsonValueKind.True)
            {
                value = true;
                return true;
            }

            if (property.ValueKind == JsonValueKind.False)
            {
                value = false;
                return true;
            }
        }

        value = false;
        return false;
    }

    private static bool TryGetInt(JsonElement element, string name, out int value)
    {
        if (element.TryGetProperty(name, out var property)
            && property.ValueKind == JsonValueKind.Number
            && property.TryGetInt32(out value))
        {
            return true;
        }

        value = 0;
        return false;
    }

    private static bool TryGetDouble(JsonElement element, string name, out double value)
    {
        if (element.TryGetProperty(name, out var property)
            && property.ValueKind == JsonValueKind.Number
            && property.TryGetDouble(out value))
        {
            return true;
        }

        value = 0;
        return false;
    }
}

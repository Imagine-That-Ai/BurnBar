// PORTED (portable, unit-tested) from:
//   AgentLens/Services/SettingsManager.swift
//     decodeJSONStringArray / encodeJSONStringArray / manuallySerializeJSONStringArray
//
// Dependency-free except System.Text.Json (in-box for net8.0). The lossless
// string-list codec behind JSON-backed settings lists. Decode is lenient
// (malformed JSON or a mistyped element fails the whole payload to an empty
// list); encode normalizes (trim + drop empties) and — critically — never
// collapses to "[]" on encoder failure, because that would permanently drop
// the user's saved list on the next flush. The manual serializer is
// byte-compatible with Foundation's JSONEncoder for the escapable subset
// (including the `\/` forward-slash escape), so the fallback output matches
// the Swift happy path for the same values.

using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.Json;

namespace OpenBurnBar.App.Settings;

/// <summary>Lossless string-list JSON codec, parity with Swift.</summary>
public static class SettingsJsonArray
{
    /// <summary>
    /// Swift <c>decodeJSONStringArray</c>: malformed JSON (or a non-array
    /// payload, or a non-string element) decodes to an empty list; elements
    /// are trimmed and empties dropped. Never throws.
    /// </summary>
    public static IReadOnlyList<string> Decode(string json)
    {
        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(json);
        }
        catch (Exception ex) when (ex is JsonException || ex is ArgumentException)
        {
            return Array.Empty<string>();
        }

        using (document)
        {
            if (document.RootElement.ValueKind != JsonValueKind.Array)
            {
                return Array.Empty<string>();
            }

            List<string> values = new();
            foreach (JsonElement element in document.RootElement.EnumerateArray())
            {
                if (element.ValueKind != JsonValueKind.String)
                {
                    return Array.Empty<string>();
                }

                string trimmed = (element.GetString() ?? string.Empty).Trim();
                if (trimmed.Length > 0)
                {
                    values.Add(trimmed);
                }
            }

            return values;
        }
    }

    /// <summary>
    /// Swift <c>encodeJSONStringArray</c>: values are trimmed and empties
    /// dropped, then JSON-encoded. On the (infeasible) encoder failure the
    /// values are preserved via <see cref="ManuallySerialize"/> — never
    /// collapsed to <c>"[]"</c>.
    /// </summary>
    public static string Encode(IEnumerable<string> values)
    {
        string[] normalized = values
            .Select(value => value.Trim())
            .Where(value => value.Length > 0)
            .ToArray();
        try
        {
            return JsonSerializer.Serialize(normalized);
        }
        catch (Exception ex) when (ex is JsonException || ex is ArgumentException || ex is InvalidOperationException)
        {
            return ManuallySerialize(normalized);
        }
    }

    /// <summary>
    /// Swift <c>manuallySerializeJSONStringArray</c>: deterministic, infallible
    /// JSON-array serialization. Escapes per RFC 8259 and matches Foundation's
    /// <c>\/</c> forward-slash escape so the fallback output is byte-identical
    /// to the Swift happy path for the same values.
    /// </summary>
    public static string ManuallySerialize(IEnumerable<string> values)
    {
        StringBuilder builder = new();
        builder.Append('[');
        bool first = true;
        foreach (string value in values)
        {
            if (!first)
            {
                builder.Append(',');
            }

            first = false;
            builder.Append('"');
            foreach (char c in value)
            {
                switch (c)
                {
                    case '"': builder.Append("\\\""); break;
                    case '\\': builder.Append("\\\\"); break;
                    case '/': builder.Append("\\/"); break;
                    case '\b': builder.Append("\\b"); break;
                    case '\f': builder.Append("\\f"); break;
                    case '\n': builder.Append("\\n"); break;
                    case '\r': builder.Append("\\r"); break;
                    case '\t': builder.Append("\\t"); break;
                    default:
                        if (c < 0x20)
                        {
                            builder.Append("\\u");
                            builder.Append(((int)c).ToString("x4"));
                        }
                        else
                        {
                            builder.Append(c);
                        }

                        break;
                }
            }

            builder.Append('"');
        }

        builder.Append(']');
        return builder.ToString();
    }
}

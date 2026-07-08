using System;
using System.Collections.Generic;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace OpenBurnBar.CloudSync.Json;

/// <summary>
/// Canonical JSON serializer that reproduces, byte-for-byte, the output of the
/// macOS models' <c>JSONEncoder</c> configured with
/// <c>[.sortedKeys, .withoutEscapingSlashes]</c> — the exact configuration used
/// to generate the committed Swift-Codable parity vectors.
///
/// The three properties that make it match Swift's <c>Codable</c> output:
///   1. <b>Keys sorted ordinally at every level</b> (Swift <c>.sortedKeys</c>).
///   2. <b>Nil optionals omitted</b> (Swift omits a <c>nil</c> Optional).
///   3. <b>Minimal escaping</b> — only <c>"</c>, <c>\</c> and control chars are
///      escaped; <c>/</c> and non-ASCII pass through as UTF-8
///      (<see cref="JavaScriptEncoder.UnsafeRelaxedJsonEscaping"/>, Swift
///      <c>.withoutEscapingSlashes</c> + UTF-8 output).
///
/// Number formatting is delegated entirely to <see cref="System.Text.Json"/>,
/// which — like Swift 5+'s encoder — emits the shortest round-trippable form
/// (whole doubles drop the fractional part: <c>3.0 -&gt; 3</c>).
/// </summary>
public static class CanonicalJson
{
    private static readonly JsonSerializerOptions SerializeOptions = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        WriteIndented = false,
    };

    private static readonly JsonWriterOptions WriterOptions = new()
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        Indented = false,
        // The re-emit step only reorders already-valid JSON; skip the redundant
        // structural validation for speed and to keep behavior deterministic.
        SkipValidation = true,
    };

    /// <summary>Serialize a value to canonical (sorted-key, null-omitting, relaxed-escape) JSON bytes.</summary>
    public static byte[] SerializeToUtf8Bytes<T>(T value) => SerializeToUtf8Bytes(value, typeof(T));

    /// <summary>
    /// Non-generic overload: serialize <paramref name="value"/> as
    /// <paramref name="declaredType"/> so a boxed model (e.g. deserialized as
    /// <see cref="object"/> in a data-driven test) still serializes with its full
    /// property set. Used by the model-parity vectors.
    /// </summary>
    public static byte[] SerializeToUtf8Bytes(object? value, Type declaredType)
    {
        // 1. STJ writes the value with the model's number formatting, null
        //    omission, and minimal escaping — but in declaration order.
        byte[] unsorted = JsonSerializer.SerializeToUtf8Bytes(value, declaredType, SerializeOptions);

        // 2. Reparse and re-emit with keys sorted ordinally at every level. This
        //    changes only key ORDER; every scalar is copied via JsonElement.WriteTo
        //    so number/string bytes are byte-identical to step 1.
        using var document = JsonDocument.Parse(unsorted);
        var buffer = new System.Buffers.ArrayBufferWriter<byte>();
        using (var writer = new Utf8JsonWriter(buffer, WriterOptions))
        {
            WriteSorted(document.RootElement, writer);
        }
        return buffer.WrittenSpan.ToArray();
    }

    /// <summary>Serialize to a canonical UTF-8 JSON string.</summary>
    public static string Serialize<T>(T value) =>
        Encoding.UTF8.GetString(SerializeToUtf8Bytes(value));

    private static void WriteSorted(JsonElement element, Utf8JsonWriter writer)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                writer.WriteStartObject();
                var properties = new List<JsonProperty>();
                foreach (JsonProperty property in element.EnumerateObject())
                {
                    properties.Add(property);
                }
                properties.Sort(static (a, b) => string.CompareOrdinal(a.Name, b.Name));
                foreach (JsonProperty property in properties)
                {
                    writer.WritePropertyName(property.Name);
                    WriteSorted(property.Value, writer);
                }
                writer.WriteEndObject();
                break;

            case JsonValueKind.Array:
                writer.WriteStartArray();
                foreach (JsonElement item in element.EnumerateArray())
                {
                    WriteSorted(item, writer);
                }
                writer.WriteEndArray();
                break;

            default:
                // string / number / true / false / null — copied verbatim.
                element.WriteTo(writer);
                break;
        }
    }
}

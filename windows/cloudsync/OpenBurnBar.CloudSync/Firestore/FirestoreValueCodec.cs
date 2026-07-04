using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace OpenBurnBar.CloudSync.Firestore;

/// <summary>
/// Maps <see cref="CloudSyncValue"/> to/from the Firestore REST/RPC v1
/// <b>typed-value</b> JSON shape used by <c>documents.get</c> / <c>documents.patch</c>
/// / <c>documents:commit</c> / <c>documents:runQuery</c>:
/// <code>
///   { "stringValue": "..." }              { "integerValue": "123" }
///   { "doubleValue": 1.5 }                { "booleanValue": true }
///   { "nullValue": null }                 { "timestampValue": "2026-07-03T10:00:00Z" }
///   { "bytesValue": "base64" }
///   { "arrayValue": { "values": [ ... ] } }
///   { "mapValue":   { "fields": { k: <value> } } }
/// </code>
/// Note that Firestore encodes integers as JSON <b>strings</b> — the single most
/// common REST-shape mistake — and timestamps as RFC-3339 UTC.
///
/// The transform sentinels (<see cref="CloudSyncValue.ServerTimestamp"/> /
/// <see cref="CloudSyncValue.Delete"/>) are not encodable as document values; the
/// commit builder lifts them out first. Encoding one here throws — fail-closed
/// against a silent lost write.
/// </summary>
public static class FirestoreValueCodec
{
    // ── Encode: CloudSyncValue -> typed-value JsonNode ──────────────────────
    public static JsonNode Encode(CloudSyncValue value)
    {
        switch (value)
        {
            case CloudSyncValue.NullValue:
                return new JsonObject { ["nullValue"] = null };
            case CloudSyncValue.BooleanValue b:
                return new JsonObject { ["booleanValue"] = b.Value };
            case CloudSyncValue.IntegerValue i:
                return new JsonObject { ["integerValue"] = i.Value.ToString(CultureInfo.InvariantCulture) };
            case CloudSyncValue.DoubleValue d:
                return new JsonObject { ["doubleValue"] = JsonValue.Create(d.Value) };
            case CloudSyncValue.StringValue s:
                return new JsonObject { ["stringValue"] = s.Value };
            case CloudSyncValue.TimestampValue t:
                return new JsonObject { ["timestampValue"] = FormatTimestamp(t.Value) };
            case CloudSyncValue.BytesValue by:
                return new JsonObject { ["bytesValue"] = Convert.ToBase64String(by.Value) };
            case CloudSyncValue.ArrayValue a:
            {
                var values = new JsonArray();
                foreach (CloudSyncValue item in a.Items) values.Add(Encode(item));
                return new JsonObject { ["arrayValue"] = new JsonObject { ["values"] = values } };
            }
            case CloudSyncValue.MapValue m:
                return new JsonObject { ["mapValue"] = new JsonObject { ["fields"] = EncodeFields(m.Fields) } };
            case CloudSyncValue.ServerTimestamp:
            case CloudSyncValue.Delete:
                throw new InvalidOperationException(
                    "Field-transform sentinel cannot be encoded as a Firestore document value; " +
                    "it must be lifted into the commit transform list first.");
            default:
                throw new InvalidOperationException($"Unhandled CloudSyncValue: {value.GetType().Name}");
        }
    }

    public static JsonObject EncodeFields(IReadOnlyDictionary<string, CloudSyncValue> fields)
    {
        var obj = new JsonObject();
        foreach (KeyValuePair<string, CloudSyncValue> kv in fields)
        {
            obj[kv.Key] = Encode(kv.Value);
        }
        return obj;
    }

    // ── Decode: typed-value JsonElement -> CloudSyncValue ───────────────────
    public static CloudSyncValue Decode(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            throw new FormatException($"Firestore value must be a single-key object, got {element.ValueKind}.");
        }

        foreach (JsonProperty property in element.EnumerateObject())
        {
            switch (property.Name)
            {
                case "nullValue":
                    return CloudSyncValue.NullValue.Instance;
                case "booleanValue":
                    return new CloudSyncValue.BooleanValue(property.Value.GetBoolean());
                case "integerValue":
                    // Firestore sends integers as strings; tolerate a raw number too.
                    return new CloudSyncValue.IntegerValue(
                        property.Value.ValueKind == JsonValueKind.String
                            ? long.Parse(property.Value.GetString()!, CultureInfo.InvariantCulture)
                            : property.Value.GetInt64());
                case "doubleValue":
                    return new CloudSyncValue.DoubleValue(property.Value.GetDouble());
                case "stringValue":
                    return new CloudSyncValue.StringValue(property.Value.GetString() ?? string.Empty);
                case "timestampValue":
                    return new CloudSyncValue.TimestampValue(ParseTimestamp(property.Value.GetString()!));
                case "bytesValue":
                    return new CloudSyncValue.BytesValue(Convert.FromBase64String(property.Value.GetString()!));
                case "arrayValue":
                {
                    var items = new List<CloudSyncValue>();
                    if (property.Value.TryGetProperty("values", out JsonElement values)
                        && values.ValueKind == JsonValueKind.Array)
                    {
                        foreach (JsonElement item in values.EnumerateArray()) items.Add(Decode(item));
                    }
                    return new CloudSyncValue.ArrayValue(items);
                }
                case "mapValue":
                {
                    var fields = new Dictionary<string, CloudSyncValue>(StringComparer.Ordinal);
                    if (property.Value.TryGetProperty("fields", out JsonElement mapFields)
                        && mapFields.ValueKind == JsonValueKind.Object)
                    {
                        foreach (JsonProperty field in mapFields.EnumerateObject())
                        {
                            fields[field.Name] = Decode(field.Value);
                        }
                    }
                    return new CloudSyncValue.MapValue(fields);
                }
                default:
                    throw new FormatException($"Unknown Firestore value type '{property.Name}'.");
            }
        }

        throw new FormatException("Empty Firestore value object.");
    }

    public static CloudSyncFields DecodeFields(JsonElement fieldsElement)
    {
        var dict = new Dictionary<string, CloudSyncValue>(StringComparer.Ordinal);
        if (fieldsElement.ValueKind == JsonValueKind.Object)
        {
            foreach (JsonProperty property in fieldsElement.EnumerateObject())
            {
                dict[property.Name] = Decode(property.Value);
            }
        }
        return new CloudSyncFields(dict);
    }

    // RFC-3339 UTC with a trailing 'Z', matching Firestore's canonical timestamp form.
    internal static string FormatTimestamp(DateTimeOffset value) =>
        value.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ", CultureInfo.InvariantCulture);

    internal static DateTimeOffset ParseTimestamp(string value) =>
        DateTimeOffset.Parse(value, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal);
}

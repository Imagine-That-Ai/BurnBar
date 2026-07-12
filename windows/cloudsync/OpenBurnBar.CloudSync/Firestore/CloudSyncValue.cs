using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace OpenBurnBar.CloudSync.Firestore;

/// <summary>
/// Portable analogue of the Swift gateway's dynamic <c>[String: Any]</c> field
/// value. The macOS Firestore SDK hides the wire encoding behind untyped
/// dictionaries; on Windows we need an explicit, byte-deterministic value model
/// so <see cref="FirestoreValueCodec"/> can map each case to the Firestore REST
/// typed-value shape (<c>stringValue</c> / <c>integerValue</c> / ...).
///
/// The two <b>sentinel</b> cases (<see cref="ServerTimestamp"/>, <see cref="Delete"/>)
/// mirror Firestore's <c>FieldValue.serverTimestamp()</c> / <c>FieldValue.delete()</c>
/// field transforms. They are NOT values: they are resolved at write time (the
/// FakeGateway substitutes a fixed timestamp / removes the key; the REST gateway
/// lifts them into the commit request's transform list). Encoding a sentinel as a
/// plain document value throws.
/// </summary>
public abstract record CloudSyncValue
{
    public sealed record NullValue : CloudSyncValue
    {
        public static readonly NullValue Instance = new();
    }

    public sealed record BooleanValue(bool Value) : CloudSyncValue;

    public sealed record IntegerValue(long Value) : CloudSyncValue;

    public sealed record DoubleValue(double Value) : CloudSyncValue;

    public sealed record StringValue(string Value) : CloudSyncValue;

    /// <summary>An ISO-8601 / RFC-3339 timestamp (Firestore <c>timestampValue</c>).</summary>
    public sealed record TimestampValue(DateTimeOffset Value) : CloudSyncValue;

    public sealed record BytesValue(byte[] Value) : CloudSyncValue
    {
        public bool Equals(BytesValue? other) =>
            other is not null && Value.AsSpan().SequenceEqual(other.Value);

        public override int GetHashCode()
        {
            var hash = new HashCode();
            hash.AddBytes(Value);
            return hash.ToHashCode();
        }
    }

    public sealed record ArrayValue(IReadOnlyList<CloudSyncValue> Items) : CloudSyncValue
    {
        public bool Equals(ArrayValue? other) =>
            other is not null && Items.SequenceEqual(other.Items);

        public override int GetHashCode()
        {
            var hash = new HashCode();
            foreach (CloudSyncValue item in Items) hash.Add(item);
            return hash.ToHashCode();
        }
    }

    public sealed record MapValue(IReadOnlyDictionary<string, CloudSyncValue> Fields) : CloudSyncValue
    {
        public bool Equals(MapValue? other)
        {
            if (other is null || Fields.Count != other.Fields.Count) return false;
            foreach (KeyValuePair<string, CloudSyncValue> kv in Fields)
            {
                if (!other.Fields.TryGetValue(kv.Key, out CloudSyncValue? v) || !Equals(kv.Value, v))
                {
                    return false;
                }
            }
            return true;
        }

        public override int GetHashCode()
        {
            var hash = new HashCode();
            foreach (KeyValuePair<string, CloudSyncValue> kv in Fields.OrderBy(k => k.Key, StringComparer.Ordinal))
            {
                hash.Add(kv.Key);
                hash.Add(kv.Value);
            }
            return hash.ToHashCode();
        }
    }

    /// <summary>Firestore <c>FieldValue.serverTimestamp()</c> transform sentinel.</summary>
    public sealed record ServerTimestamp : CloudSyncValue
    {
        public static readonly ServerTimestamp Instance = new();
    }

    /// <summary>Firestore <c>FieldValue.delete()</c> transform sentinel (merge writes only).</summary>
    public sealed record Delete : CloudSyncValue
    {
        public static readonly Delete Instance = new();
    }

    // ── Ergonomic constructors ──────────────────────────────────────────────
    public static CloudSyncValue Of(string value) => new StringValue(value);
    public static CloudSyncValue Of(long value) => new IntegerValue(value);
    public static CloudSyncValue Of(int value) => new IntegerValue(value);
    public static CloudSyncValue Of(double value) => new DoubleValue(value);
    public static CloudSyncValue Of(bool value) => new BooleanValue(value);
    public static CloudSyncValue Of(DateTimeOffset value) => new TimestampValue(value);
    public static CloudSyncValue Of(byte[] value) => new BytesValue(value);
    public static CloudSyncValue Of(IReadOnlyList<CloudSyncValue> items) => new ArrayValue(items);
    public static CloudSyncValue Of(IReadOnlyDictionary<string, CloudSyncValue> fields) => new MapValue(fields);

    /// <summary>True when this value is a field-transform sentinel, not a literal value.</summary>
    public bool IsTransform => this is ServerTimestamp or Delete;

    public override string ToString() => this switch
    {
        NullValue => "null",
        BooleanValue b => b.Value ? "true" : "false",
        IntegerValue i => i.Value.ToString(CultureInfo.InvariantCulture),
        DoubleValue d => d.Value.ToString("R", CultureInfo.InvariantCulture),
        StringValue s => s.Value,
        TimestampValue t => t.Value.ToString("O", CultureInfo.InvariantCulture),
        BytesValue => "<bytes>",
        ArrayValue a => $"[{a.Items.Count}]",
        MapValue m => $"{{{m.Fields.Count}}}",
        ServerTimestamp => "<serverTimestamp>",
        Delete => "<delete>",
        _ => base.ToString() ?? string.Empty,
    };
}

/// <summary>An immutable set of Firestore document field values (the document body).</summary>
public sealed class CloudSyncFields
{
    private readonly Dictionary<string, CloudSyncValue> _fields;

    public CloudSyncFields() => _fields = new Dictionary<string, CloudSyncValue>(StringComparer.Ordinal);

    public CloudSyncFields(IReadOnlyDictionary<string, CloudSyncValue> fields) =>
        _fields = new Dictionary<string, CloudSyncValue>(fields, StringComparer.Ordinal);

    public IReadOnlyDictionary<string, CloudSyncValue> Values => _fields;

    public int Count => _fields.Count;

    public bool TryGet(string key, out CloudSyncValue value) => _fields.TryGetValue(key, out value!);

    public CloudSyncValue? this[string key] => _fields.TryGetValue(key, out CloudSyncValue? v) ? v : null;

    public CloudSyncFields Set(string key, CloudSyncValue value)
    {
        var copy = new Dictionary<string, CloudSyncValue>(_fields, StringComparer.Ordinal) { [key] = value };
        return new CloudSyncFields(copy);
    }

    public static CloudSyncFields From(IEnumerable<KeyValuePair<string, CloudSyncValue>> pairs)
    {
        var dict = new Dictionary<string, CloudSyncValue>(StringComparer.Ordinal);
        foreach (KeyValuePair<string, CloudSyncValue> pair in pairs) dict[pair.Key] = pair.Value;
        return new CloudSyncFields(dict);
    }
}

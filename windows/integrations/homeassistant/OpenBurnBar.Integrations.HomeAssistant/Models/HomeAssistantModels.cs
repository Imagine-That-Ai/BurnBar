using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.Json;

namespace OpenBurnBar.Integrations.HomeAssistant.Models;

// Home Assistant REST message model.
//
// Parity: AgentLens/Services/HomeAssistant/HomeAssistantClient.swift
//   struct State / enum AttributeValue / struct MediaPlayer.
//
// The macOS side decodes HA's `/api/states` documents with Codable; here we
// mirror the same shapes over System.Text.Json. HA returns a heterogeneous
// attributes dictionary where every value can be a string, number, bool, list,
// or null, so `HaAttributeValue` is a small discriminated union that we
// dynamic-decode and surface convenience accessors from — exactly as the Swift
// `AttributeValue` enum does.

/// One value inside a Home Assistant state's `attributes` dictionary.
/// Mirrors the Swift `HomeAssistantClient.AttributeValue` enum.
public abstract class HaAttributeValue : IEquatable<HaAttributeValue>
{
    public static readonly HaAttributeValue Null = new HaNull();

    public static HaAttributeValue String(string value) => new HaString(value);
    public static HaAttributeValue Number(double value) => new HaNumber(value);
    public static HaAttributeValue Bool(bool value) => new HaBool(value);
    public static HaAttributeValue Array(IReadOnlyList<HaAttributeValue> value) => new HaArray(value);

    /// Convenience accessor matching Swift `AttributeValue.stringValue`:
    /// string -> itself, number -> invariant string, bool -> "true"/"false",
    /// everything else -> null.
    public abstract string? StringValue { get; }

    /// Decodes a single JSON value into the union, matching the Swift
    /// singleValueContainer probe order (null, string, bool, number, array).
    public static HaAttributeValue FromJson(JsonElement element)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Null:
            case JsonValueKind.Undefined:
                return Null;
            case JsonValueKind.String:
                return String(element.GetString() ?? string.Empty);
            case JsonValueKind.True:
                return Bool(true);
            case JsonValueKind.False:
                return Bool(false);
            case JsonValueKind.Number:
                return Number(element.GetDouble());
            case JsonValueKind.Array:
                var items = new List<HaAttributeValue>(element.GetArrayLength());
                foreach (var child in element.EnumerateArray())
                {
                    items.Add(FromJson(child));
                }
                return Array(items);
            default:
                // Objects are not part of the attribute shapes we consume.
                return Null;
        }
    }

    public abstract bool Equals(HaAttributeValue? other);

    public override bool Equals(object? obj) => Equals(obj as HaAttributeValue);

    public override abstract int GetHashCode();

    private sealed class HaNull : HaAttributeValue
    {
        public override string? StringValue => null;
        public override bool Equals(HaAttributeValue? other) => other is HaNull;
        public override int GetHashCode() => 0;
    }

    private sealed class HaString : HaAttributeValue
    {
        private readonly string _value;
        public HaString(string value) => _value = value;
        public override string? StringValue => _value;
        public override bool Equals(HaAttributeValue? other) => other is HaString s && s._value == _value;
        public override int GetHashCode() => _value.GetHashCode();
    }

    private sealed class HaNumber : HaAttributeValue
    {
        private readonly double _value;
        public HaNumber(double value) => _value = value;
        // Parity: Swift `String(_ value: Double)` — shortest round-trippable
        // decimal, with a ".0" suffix for integral values ("4092" -> "4092.0").
        // This is load-bearing: the projection does Int(stringValue) on
        // supported_features, and Int("4092.0") fails just like Swift's, so a
        // NUMERIC supported_features contributes 0 to the bitmask on both
        // platforms (castability then falls to the keyword haystack).
        public override string? StringValue => SwiftDoubleString(_value);
        public override bool Equals(HaAttributeValue? other) => other is HaNumber n && n._value.Equals(_value);
        public override int GetHashCode() => _value.GetHashCode();

        private static string SwiftDoubleString(double value)
        {
            if (double.IsNaN(value)) return "nan";
            if (double.IsPositiveInfinity(value)) return "inf";
            if (double.IsNegativeInfinity(value)) return "-inf";
            var text = value.ToString(CultureInfo.InvariantCulture);
            if (!text.Contains('.') && !text.Contains('e') && !text.Contains('E'))
            {
                text += ".0";
            }
            return text;
        }
    }

    private sealed class HaBool : HaAttributeValue
    {
        private readonly bool _value;
        public HaBool(bool value) => _value = value;
        // Swift `String(bool)` yields "true"/"false".
        public override string? StringValue => _value ? "true" : "false";
        public override bool Equals(HaAttributeValue? other) => other is HaBool b && b._value == _value;
        public override int GetHashCode() => _value.GetHashCode();
    }

    private sealed class HaArray : HaAttributeValue
    {
        private readonly IReadOnlyList<HaAttributeValue> _value;
        public HaArray(IReadOnlyList<HaAttributeValue> value) => _value = value;
        public IReadOnlyList<HaAttributeValue> Items => _value;
        public override string? StringValue => null;
        public override bool Equals(HaAttributeValue? other)
        {
            if (other is not HaArray a || a._value.Count != _value.Count)
            {
                return false;
            }
            for (var i = 0; i < _value.Count; i++)
            {
                if (!_value[i].Equals(a._value[i]))
                {
                    return false;
                }
            }
            return true;
        }
        public override int GetHashCode()
        {
            var hash = 17;
            foreach (var item in _value)
            {
                hash = (hash * 31) + item.GetHashCode();
            }
            return hash;
        }
    }
}

/// A Home Assistant entity state document (`/api/states` row).
/// Mirrors the Swift `HomeAssistantClient.State`.
public sealed record HaEntityState(
    string EntityId,
    string State,
    IReadOnlyDictionary<string, HaAttributeValue> Attributes)
{
    /// Reads an attribute's string projection, or null when absent.
    public string? Attribute(string key) =>
        Attributes.TryGetValue(key, out var value) ? value.StringValue : null;
}

/// Tightly-typed view of a `media_player` state document.
/// Mirrors the Swift `HomeAssistantClient.MediaPlayer`.
public sealed record HaMediaPlayer(
    string EntityId,
    string FriendlyName,
    string? Model,
    bool SupportsCast,
    int SupportedFeatures,
    string State)
{
    public string Id => EntityId;
}

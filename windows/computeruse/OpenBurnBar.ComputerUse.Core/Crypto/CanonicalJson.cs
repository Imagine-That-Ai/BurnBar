// Deterministic canonical-JSON writer used for signing + hashing.
//
// Mirrors the two Swift canonical encoders in OpenBurnBarComputerUseCore:
//   * CapabilityTokenSigner.canonicalEncoder — JSONEncoder with
//     [.sortedKeys, .withoutEscapingSlashes] and dates as ISO-8601 strings.
//   * ComputerUseAuditHasher.canonicalJSONEncoder — the same, but dates as
//     millisecond integers.
//
// Both share three properties that this writer reproduces exactly so a signed
// or hashed body re-serializes byte-identically:
//   1. object keys are emitted in ASCII-ordinal ascending order (`sortedKeys`),
//   2. a null member is OMITTED entirely (Swift omits `nil` Optionals), and
//   3. `/` is written literally, never escaped (`withoutEscapingSlashes`).
//
// The caller supplies dates already converted to their canonical scalar form
// (an ISO-8601 string or an Int64 millisecond count), so this writer never has
// to know which domain it is serializing.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace OpenBurnBar.ComputerUse.Core.Crypto;

/// <summary>
/// Serializes an ordered object graph to the byte-stable canonical JSON the
/// capability-token signer and audit hasher agree on. Values may be
/// <see cref="string"/>, <see cref="bool"/>, <see cref="long"/>, <see cref="int"/>,
/// <see cref="double"/>, an <see cref="IReadOnlyList{T}"/> of the same, or a nested
/// <see cref="CanonicalJsonObject"/>. A <c>null</c> member is skipped.
/// </summary>
public static class CanonicalJson
{
    /// <summary>UTF-8 canonical bytes for <paramref name="value"/>.</summary>
    public static byte[] Encode(CanonicalJsonObject value)
    {
        if (value is null)
        {
            throw new ArgumentNullException(nameof(value));
        }

        var builder = new StringBuilder(256);
        WriteObject(builder, value);
        return Encoding.UTF8.GetBytes(builder.ToString());
    }

    /// <summary>UTF-8 canonical string for <paramref name="value"/> (test/debug).</summary>
    public static string EncodeToString(CanonicalJsonObject value)
        => Encoding.UTF8.GetString(Encode(value));

    private static void WriteObject(StringBuilder builder, CanonicalJsonObject value)
    {
        builder.Append('{');
        var first = true;
        // Emit keys in ordinal ascending order to match Swift's `.sortedKeys`.
        foreach (var key in value.SortedKeys())
        {
            var member = value[key];
            if (member is null)
            {
                continue; // Swift omits nil Optionals from the signed/hashed body.
            }

            if (!first)
            {
                builder.Append(',');
            }

            first = false;
            WriteString(builder, key);
            builder.Append(':');
            WriteValue(builder, member);
        }

        builder.Append('}');
    }

    private static void WriteValue(StringBuilder builder, object member)
    {
        switch (member)
        {
            case CanonicalJsonObject nested:
                WriteObject(builder, nested);
                break;
            case string s:
                WriteString(builder, s);
                break;
            case bool b:
                builder.Append(b ? "true" : "false");
                break;
            case int i:
                builder.Append(i.ToString(CultureInfo.InvariantCulture));
                break;
            case long l:
                builder.Append(l.ToString(CultureInfo.InvariantCulture));
                break;
            case double d:
                builder.Append(d.ToString("R", CultureInfo.InvariantCulture));
                break;
            case IReadOnlyList<string> stringArray:
                WriteStringArray(builder, stringArray);
                break;
            case IReadOnlyList<CanonicalJsonObject> objectArray:
                WriteObjectArray(builder, objectArray);
                break;
            default:
                throw new NotSupportedException(
                    $"CanonicalJson cannot encode a value of type {member.GetType()}.");
        }
    }

    private static void WriteStringArray(StringBuilder builder, IReadOnlyList<string> array)
    {
        builder.Append('[');
        for (var index = 0; index < array.Count; index++)
        {
            if (index > 0)
            {
                builder.Append(',');
            }

            WriteString(builder, array[index]);
        }

        builder.Append(']');
    }

    private static void WriteObjectArray(StringBuilder builder, IReadOnlyList<CanonicalJsonObject> array)
    {
        builder.Append('[');
        for (var index = 0; index < array.Count; index++)
        {
            if (index > 0)
            {
                builder.Append(',');
            }

            WriteObject(builder, array[index]);
        }

        builder.Append(']');
    }

    private static void WriteString(StringBuilder builder, string value)
    {
        builder.Append('"');
        foreach (var ch in value)
        {
            switch (ch)
            {
                case '"':
                    builder.Append("\\\"");
                    break;
                case '\\':
                    builder.Append("\\\\");
                    break;
                case '\b':
                    builder.Append("\\b");
                    break;
                case '\f':
                    builder.Append("\\f");
                    break;
                case '\n':
                    builder.Append("\\n");
                    break;
                case '\r':
                    builder.Append("\\r");
                    break;
                case '\t':
                    builder.Append("\\t");
                    break;
                default:
                    if (ch < 0x20)
                    {
                        builder.Append("\\u");
                        builder.Append(((int)ch).ToString("x4", CultureInfo.InvariantCulture));
                    }
                    else
                    {
                        // `/` and non-ASCII stay literal (Swift .withoutEscapingSlashes + UTF-8).
                        builder.Append(ch);
                    }

                    break;
            }
        }

        builder.Append('"');
    }
}

/// <summary>
/// An ordered bag of JSON members used as the canonical-JSON serialization
/// source. Insertion order does not matter — <see cref="CanonicalJson"/> always
/// re-sorts keys — but each key must be unique. A <c>null</c> value marks an
/// omitted (Swift-<c>nil</c>) member.
/// </summary>
public sealed class CanonicalJsonObject
{
    private readonly Dictionary<string, object?> _members = new(StringComparer.Ordinal);

    /// <summary>Sets (or clears, when <paramref name="value"/> is null) a member.</summary>
    public CanonicalJsonObject Set(string key, object? value)
    {
        if (key is null)
        {
            throw new ArgumentNullException(nameof(key));
        }

        _members[key] = value;
        return this;
    }

    internal object? this[string key] => _members.TryGetValue(key, out var value) ? value : null;

    internal IEnumerable<string> SortedKeys()
    {
        var keys = new List<string>(_members.Keys);
        keys.Sort(StringComparer.Ordinal);
        return keys;
    }
}

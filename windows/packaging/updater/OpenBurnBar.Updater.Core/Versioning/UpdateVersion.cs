// Monotonic dotted-numeric version for the updater's downgrade guard.
//
// Windows artifacts (MSIX) carry a 4-part numeric version
// Major.Minor.Build.Revision; the appcast's `sparkle:shortVersionString`
// mirrors the macOS marketing version. This parses either into an ordered tuple
// and compares component-by-component, treating missing trailing components as
// 0 ("1.4" == "1.4.0.0"). Only decimal-numeric components are accepted — a
// non-numeric or negative component is rejected so a malformed feed version
// fails closed (never silently sorts as "newer").
//
// The updater uses this to BLOCK downgrades (R19 defense-in-depth): a feed that
// offers a version less-than-or-equal-to the installed version never installs,
// even when its Ed25519 signature is otherwise valid. That defeats the
// "sign an old, vulnerable build and roll the victim back" attack.

using System;
using System.Collections.Generic;
using System.Globalization;

namespace OpenBurnBar.Updater.Core.Versioning;

/// <summary>An ordered dotted-numeric version, comparable and downgrade-aware.</summary>
public readonly struct UpdateVersion : IComparable<UpdateVersion>, IEquatable<UpdateVersion>
{
    /// <summary>MSIX versions are 4-part; we normalize every compare to this width.</summary>
    public const int NormalizedComponentCount = 4;

    private readonly int[] _components;

    private UpdateVersion(int[] components)
    {
        _components = components;
    }

    /// <summary>The raw string this version was parsed from (for diagnostics);
    /// null for a default (uninitialized) struct.</summary>
    public string? Raw { get; private init; }

    /// <summary>
    /// Parses "1", "1.4", "1.4.2", or "1.4.2.0" into an ordered version. Throws
    /// <see cref="FormatException"/> on any non-numeric / negative / empty
    /// component so a caller that forgot to guard fails loudly; feed parsing
    /// uses <see cref="TryParse"/> and fails closed instead.
    /// </summary>
    public static UpdateVersion Parse(string value)
    {
        if (!TryParse(value, out var version))
        {
            throw new FormatException($"Not a valid dotted-numeric version: '{value}'.");
        }

        return version;
    }

    /// <summary>
    /// Attempts to parse a dotted-numeric version. Returns false (and a default
    /// struct) for null / empty / non-numeric / negative / overflowing input so
    /// the updater treats a malformed feed version as unusable, not as newest.
    /// </summary>
    public static bool TryParse(string? value, out UpdateVersion version)
    {
        version = default;
        if (string.IsNullOrWhiteSpace(value))
        {
            return false;
        }

        var trimmed = value.Trim();
        var parts = trimmed.Split('.');
        if (parts.Length == 0 || parts.Length > 8)
        {
            return false;
        }

        var components = new List<int>(parts.Length);
        foreach (var part in parts)
        {
            if (part.Length == 0)
            {
                return false;
            }

            // Reject signs, whitespace, hex, and thousands separators — decimal digits only.
            foreach (var ch in part)
            {
                if (ch < '0' || ch > '9')
                {
                    return false;
                }
            }

            if (!int.TryParse(part, NumberStyles.None, CultureInfo.InvariantCulture, out var component))
            {
                return false;
            }

            components.Add(component);
        }

        version = new UpdateVersion(components.ToArray()) { Raw = trimmed };
        return true;
    }

    private int ComponentAt(int index) =>
        _components is not null && index < _components.Length ? _components[index] : 0;

    public int CompareTo(UpdateVersion other)
    {
        var width = Math.Max(
            _components?.Length ?? 0,
            other._components?.Length ?? 0);
        width = Math.Max(width, NormalizedComponentCount);

        for (var i = 0; i < width; i++)
        {
            var cmp = ComponentAt(i).CompareTo(other.ComponentAt(i));
            if (cmp != 0)
            {
                return cmp;
            }
        }

        return 0;
    }

    public bool Equals(UpdateVersion other) => CompareTo(other) == 0;

    public override bool Equals(object? obj) => obj is UpdateVersion other && Equals(other);

    public override int GetHashCode()
    {
        var hash = new HashCode();
        for (var i = 0; i < NormalizedComponentCount; i++)
        {
            hash.Add(ComponentAt(i));
        }

        return hash.ToHashCode();
    }

    public string ToNormalizedString()
    {
        var components = new string[NormalizedComponentCount];
        for (var i = 0; i < NormalizedComponentCount; i++)
        {
            components[i] = ComponentAt(i).ToString(CultureInfo.InvariantCulture);
        }

        return string.Join(".", components);
    }

    public override string ToString() => Raw ?? "0.0.0.0";

    public static bool operator ==(UpdateVersion left, UpdateVersion right) => left.Equals(right);

    public static bool operator !=(UpdateVersion left, UpdateVersion right) => !left.Equals(right);

    public static bool operator <(UpdateVersion left, UpdateVersion right) => left.CompareTo(right) < 0;

    public static bool operator >(UpdateVersion left, UpdateVersion right) => left.CompareTo(right) > 0;

    public static bool operator <=(UpdateVersion left, UpdateVersion right) => left.CompareTo(right) <= 0;

    public static bool operator >=(UpdateVersion left, UpdateVersion right) => left.CompareTo(right) >= 0;
}

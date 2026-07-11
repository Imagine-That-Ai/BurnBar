// Release version parsing + ordering (Phase 5 · signed distribution).
//
// The direct-download updater must answer one question safely: "is the feed's authenticated
// release strictly NEWER than what is installed?" A too-lenient parser that silently treats a
// malformed version as 0.0.0 could hide a downgrade or spuriously offer an update, so parsing
// is strict and comparison is total + well-defined.
//
// Format: 1–4 dot-separated numeric components (e.g. "1.0.28" or "1.0.28.0"), with an OPTIONAL
// pre-release suffix introduced by '-' (e.g. "1.1.0-beta.2"). Numeric releases sort by
// component; a pre-release sorts BEFORE the same numeric release (semver rule) so a beta never
// masquerades as newer than its final. Missing trailing components are treated as 0
// (1.0 == 1.0.0.0) for the numeric core only.

using System;
using System.Collections.Generic;
using System.Globalization;

namespace OpenBurnBar.Dist.UpdateFeed;

/// <summary>An ordered, strictly-parsed release version. Immutable value type.</summary>
public sealed class UpdateVersion : IComparable<UpdateVersion>, IEquatable<UpdateVersion>
{
    private const int ComponentCount = 4;

    private readonly int[] _components; // always length 4
    private readonly string _preRelease; // "" when this is a final release

    private UpdateVersion(int[] components, string preRelease, string original)
    {
        _components = components;
        _preRelease = preRelease;
        Original = original;
    }

    /// <summary>The exact source string this version was parsed from.</summary>
    public string Original { get; }

    /// <summary>True when this is a pre-release (carries a '-suffix').</summary>
    public bool IsPreRelease => _preRelease.Length > 0;

    /// <summary>Parse strictly. Throws <see cref="FormatException"/> on anything that is not a
    /// 1–4 component numeric version with an optional '-preRelease' suffix.</summary>
    public static UpdateVersion Parse(string value)
    {
        if (!TryParse(value, out var parsed) || parsed is null)
        {
            throw new FormatException($"Not a valid release version: '{value}'");
        }

        return parsed;
    }

    /// <summary>Parse strictly. Returns false (never throws) on malformed input — the updater
    /// treats an unparseable feed/installed version as fail-closed (no offer), never as 0.0.0.</summary>
    public static bool TryParse(string? value, out UpdateVersion? version)
    {
        version = null;
        if (string.IsNullOrWhiteSpace(value))
        {
            return false;
        }

        var trimmed = value.Trim();
        var preRelease = string.Empty;
        var dashIndex = trimmed.IndexOf('-');
        var core = trimmed;
        if (dashIndex >= 0)
        {
            core = trimmed.Substring(0, dashIndex);
            preRelease = trimmed.Substring(dashIndex + 1);
            if (preRelease.Length == 0 || !IsValidPreRelease(preRelease))
            {
                return false;
            }
        }

        var parts = core.Split('.');
        if (parts.Length is < 1 or > ComponentCount)
        {
            return false;
        }

        var components = new int[ComponentCount];
        for (var i = 0; i < parts.Length; i++)
        {
            var part = parts[i];
            if (part.Length == 0)
            {
                return false;
            }

            foreach (var ch in part)
            {
                if (ch is < '0' or > '9')
                {
                    return false;
                }
            }

            if (!int.TryParse(part, NumberStyles.None, CultureInfo.InvariantCulture, out var component))
            {
                return false;
            }

            components[i] = component;
        }

        version = new UpdateVersion(components, preRelease, trimmed);
        return true;
    }

    private static bool IsValidPreRelease(string preRelease)
    {
        // Dot-separated identifiers of [0-9A-Za-z-]; no empty identifiers. Deliberately narrow
        // so the pre-release token stays canonicalization-safe.
        foreach (var identifier in preRelease.Split('.'))
        {
            if (identifier.Length == 0)
            {
                return false;
            }

            foreach (var ch in identifier)
            {
                var ok = ch is >= '0' and <= '9' or >= 'A' and <= 'Z' or >= 'a' and <= 'z' || ch == '-';
                if (!ok)
                {
                    return false;
                }
            }
        }

        return true;
    }

    /// <summary>Total order: numeric core first; a pre-release sorts before the equal-core
    /// final; pre-release identifiers compare numerically when both numeric, else lexically,
    /// with numeric identifiers ranking below alphanumeric (semver §11).</summary>
    public int CompareTo(UpdateVersion? other)
    {
        if (other is null)
        {
            return 1;
        }

        for (var i = 0; i < ComponentCount; i++)
        {
            var cmp = _components[i].CompareTo(other._components[i]);
            if (cmp != 0)
            {
                return cmp;
            }
        }

        // Equal numeric core. A final release outranks a pre-release of the same core.
        if (_preRelease.Length == 0 && other._preRelease.Length == 0)
        {
            return 0;
        }

        if (_preRelease.Length == 0)
        {
            return 1; // this final > other pre-release
        }

        if (other._preRelease.Length == 0)
        {
            return -1; // this pre-release < other final
        }

        return ComparePreRelease(_preRelease, other._preRelease);
    }

    private static int ComparePreRelease(string left, string right)
    {
        var leftParts = left.Split('.');
        var rightParts = right.Split('.');
        var count = Math.Min(leftParts.Length, rightParts.Length);
        for (var i = 0; i < count; i++)
        {
            var l = leftParts[i];
            var r = rightParts[i];
            var lNumeric = IsNumericIdentifier(l);
            var rNumeric = IsNumericIdentifier(r);
            int cmp;
            if (lNumeric && rNumeric)
            {
                cmp = CompareNumericIdentifier(l, r);
            }
            else if (lNumeric != rNumeric)
            {
                cmp = lNumeric ? -1 : 1; // numeric identifiers have lower precedence
            }
            else
            {
                cmp = string.CompareOrdinal(l, r);
            }

            if (cmp != 0)
            {
                return cmp;
            }
        }

        // A larger set of pre-release fields has higher precedence when all preceding are equal.
        return leftParts.Length.CompareTo(rightParts.Length);
    }

    private static bool IsNumericIdentifier(string identifier)
    {
        foreach (var ch in identifier)
        {
            if (ch is < '0' or > '9')
            {
                return false;
            }
        }

        return identifier.Length > 0;
    }

    private static int CompareNumericIdentifier(string left, string right)
    {
        // Both are pure-digit strings; compare by length then lexically to avoid overflow.
        var l = left.TrimStart('0');
        var r = right.TrimStart('0');
        if (l.Length != r.Length)
        {
            return l.Length.CompareTo(r.Length);
        }

        return string.CompareOrdinal(l, r);
    }

    /// <summary>True iff <paramref name="candidate"/> is strictly newer than <paramref name="installed"/>.</summary>
    public static bool IsNewer(UpdateVersion candidate, UpdateVersion installed)
    {
        ArgumentNullException.ThrowIfNull(candidate);
        ArgumentNullException.ThrowIfNull(installed);
        return candidate.CompareTo(installed) > 0;
    }

    /// <inheritdoc/>
    public bool Equals(UpdateVersion? other) => other is not null && CompareTo(other) == 0;

    /// <inheritdoc/>
    public override bool Equals(object? obj) => obj is UpdateVersion other && Equals(other);

    /// <inheritdoc/>
    public override int GetHashCode()
    {
        var hash = new HashCode();
        foreach (var component in _components)
        {
            hash.Add(component);
        }

        // Normalize pre-release for hashing so Equals/GetHashCode stay consistent.
        hash.Add(_preRelease);
        return hash.ToHashCode();
    }

    /// <summary>The normalized 4-component numeric core, e.g. "1.0.28.0", plus any pre-release.</summary>
    public string ToNormalizedString()
    {
        var core = string.Join('.', (IEnumerable<int>)_components);
        return _preRelease.Length > 0 ? $"{core}-{_preRelease}" : core;
    }

    /// <inheritdoc/>
    public override string ToString() => Original;
}

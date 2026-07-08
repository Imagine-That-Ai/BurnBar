using System;

namespace OpenBurnBar.App.TextExpansion;

/// <summary>
/// Trigger normalization + validation. Faithful port of Swift
/// <c>TextExpansionTrigger</c> (OpenBurnBarCore/.../TextExpansion/TextExpansion.swift),
/// including the exact ASCII scalar rules so a trigger accepted on macOS is
/// accepted identically on Windows (and vice-versa).
/// </summary>
public static class TextExpansionTrigger
{
    public const string Prefix = "&&";

    public const int MinLength = 2;

    public const int MaxLength = 64;

    /// <summary>
    /// Trim whitespace/newlines, strip every leading <c>&amp;&amp;</c>, lowercase.
    /// Mirrors Swift <c>canonicalName(_:)</c> exactly (repeated prefix strip).
    /// </summary>
    public static string CanonicalName(string raw)
    {
        string value = raw.Trim();
        while (value.StartsWith(Prefix, StringComparison.Ordinal))
        {
            value = value.Substring(Prefix.Length);
        }

        return value.ToLowerInvariant();
    }

    /// <summary>Swift <c>activationToken(for:)</c>: <c>&amp;&amp;</c> + canonical name.</summary>
    public static string ActivationToken(string raw) => Prefix + CanonicalName(raw);

    /// <summary>
    /// Returns a human-readable validation error, or null when the (canonicalized)
    /// trigger is valid. Byte-faithful to Swift <c>validationError(for:)</c>:
    /// length bounds first, then per-scalar allow-list of <c>[a-z0-9_-]</c>.
    /// </summary>
    public static string? ValidationError(string raw)
    {
        string name = CanonicalName(raw);
        if (name.Length < MinLength)
        {
            return $"Trigger must be at least {MinLength} characters.";
        }

        if (name.Length > MaxLength)
        {
            return $"Trigger must be {MaxLength} characters or shorter.";
        }

        foreach (char scalar in name)
        {
            bool isLowercase = scalar >= 'a' && scalar <= 'z';
            bool isDigit = scalar >= '0' && scalar <= '9';
            bool isAllowedSymbol = scalar == '_' || scalar == '-';
            if (!(isLowercase || isDigit || isAllowedSymbol))
            {
                return "Use lowercase letters, numbers, hyphen, or underscore.";
            }
        }

        return null;
    }

    /// <summary>Swift <c>isValid(_:)</c>.</summary>
    public static bool IsValid(string raw) => ValidationError(raw) is null;
}

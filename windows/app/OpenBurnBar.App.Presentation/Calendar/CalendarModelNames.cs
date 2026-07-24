using System;
using System.Globalization;
using System.Linq;

namespace OpenBurnBar.App.Presentation.Calendar;

/// <summary>
/// Model-name normalization + display casing for the Model Mix card — the port of
/// macOS <c>TokenExtractionUtility.normalizeModelKey</c> /
/// <c>normalizeModelName</c> / <c>displayNameForModel</c>
/// (<c>OpenBurnBarCore/.../TokenExtractionUtility.swift</c>).
/// </summary>
public static class CalendarModelNames
{
    /// <summary>Strip <c>custom:</c> / <c>vibeproxy:</c> prefixes (Cursor conventions).</summary>
    public static string NormalizeModelName(string model)
    {
        string normalized = (model ?? string.Empty).Trim();
        if (normalized.StartsWith("custom:", StringComparison.OrdinalIgnoreCase))
        {
            normalized = normalized.Substring("custom:".Length);
        }

        if (normalized.StartsWith("vibeproxy:", StringComparison.OrdinalIgnoreCase))
        {
            normalized = normalized.Substring("vibeproxy:".Length).Trim(' ', '-', '_', ':', '\t', '\n', '\r');
        }

        return normalized;
    }

    /// <summary>Stable lowercase key for grouping usages by model.</summary>
    public static string NormalizeModelKey(string model) =>
        NormalizeModelName(model).Trim().ToLowerInvariant();

    /// <summary>Human-readable display name for a model string (title-cased key).</summary>
    public static string DisplayNameForModel(string rawName)
    {
        string key = NormalizeModelKey(rawName);
        if (key.Length == 0)
        {
            return rawName;
        }

        return string.Join(
            " ",
            key.Replace('-', ' ')
               .Replace('_', ' ')
               .Split(' ', StringSplitOptions.RemoveEmptyEntries)
               .Select(word => char.IsDigit(word[0])
                   ? word
                   : string.Concat(
                       char.ToUpper(word[0], CultureInfo.InvariantCulture).ToString(),
                       word.AsSpan(1))));
    }
}

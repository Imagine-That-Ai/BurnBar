// PORTED 1:1 from AgentLens/Views/Settings/Search/SettingsSearchEngine.swift.
//
// Ranks SettingsItems against a free-form query using weighted token hits across
// Title (weight 3), Keywords (weight 2), Subtitle (weight 2), and HelpText
// (weight 1).
//
// Match semantics (identical to the Swift source):
//   • Query is lowercased and diacritic-folded; the same is applied to each row
//     field once per call (manifests are small).
//   • Whitespace-separated query tokens use AND semantics — every token must hit
//     *some* field for the row to qualify.
//   • Score is the sum of weighted hits across fields. Tied scores break by folded
//     Title ascending (ordinal).
//   • Returns at most `limit` (default 25).
//
// Performance: linear scan over the manifest. With ~140 items x ~3 tokens the scan
// is sub-millisecond.

using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;

namespace OpenBurnBar.App.Settings;

/// <summary>Weighted token-hit ranker over the Settings manifest (Swift <c>SettingsSearchEngine</c>).</summary>
public static class SettingsSearchEngine
{
    /// <summary>Weight applied to a hit in the matching field.</summary>
    public static class Weight
    {
        public const int Title = 3;
        public const int Keyword = 2;
        public const int Subtitle = 2;
        public const int HelpText = 1;
    }

    public const int DefaultResultLimit = 25;

    /// <summary>
    /// Returns ranked matches for <paramref name="query"/> across <paramref name="items"/>.
    /// An empty / whitespace-only query yields an empty list.
    /// </summary>
    public static IReadOnlyList<SettingsItem> Search(
        string query,
        IReadOnlyList<SettingsItem> items,
        int limit = DefaultResultLimit)
    {
        var tokens = Tokenize(query);
        if (tokens.Count == 0) return Array.Empty<SettingsItem>();

        // Score every row that satisfies AND-semantics on tokens. LINQ OrderBy is a
        // stable sort, so equal (score, foldedTitle) rows keep manifest order — the
        // deterministic analog of the Swift comparator.
        var scored = new List<(SettingsItem Item, int Score, string FoldedTitle)>();
        foreach (var item in items)
        {
            var score = Score(item, tokens);
            if (score is int s) scored.Add((item, s, FoldedTitle(item)));
        }

        return scored
            .OrderByDescending(t => t.Score)
            .ThenBy(t => t.FoldedTitle, StringComparer.Ordinal)
            .Take(limit)
            .Select(t => t.Item)
            .ToArray();
    }

    /// <summary>
    /// Scoring honors AND semantics. Returns <c>null</c> if any token fails to hit any
    /// indexed field on the row.
    /// </summary>
    public static int? Score(SettingsItem item, IReadOnlyList<string> tokens)
    {
        var title = FoldedTitle(item);
        var keywords = item.Keywords.Select(Fold).ToArray();
        var subtitle = item.Subtitle is null ? string.Empty : Fold(item.Subtitle);
        var helpText = item.HelpText is null ? string.Empty : Fold(item.HelpText);

        var total = 0;
        foreach (var token in tokens)
        {
            var tokenScore = 0;
            if (title.Contains(token, StringComparison.Ordinal)) tokenScore += Weight.Title;
            if (keywords.Any(k => k.Contains(token, StringComparison.Ordinal))) tokenScore += Weight.Keyword;
            if (subtitle.Length != 0 && subtitle.Contains(token, StringComparison.Ordinal)) tokenScore += Weight.Subtitle;
            if (helpText.Length != 0 && helpText.Contains(token, StringComparison.Ordinal)) tokenScore += Weight.HelpText;

            if (tokenScore == 0) return null;
            total += tokenScore;
        }

        return total;
    }

    /// <summary>
    /// Lowercase + diacritic-fold a string for substring matching. Mirrors Swift
    /// <c>folding(options: [.diacriticInsensitive, .caseInsensitive])</c>: NFD-normalize,
    /// drop combining marks, then lowercase invariantly.
    /// </summary>
    public static string Fold(string input)
    {
        var normalized = input.Normalize(NormalizationForm.FormD);
        var builder = new StringBuilder(normalized.Length);
        foreach (var ch in normalized)
        {
            if (CharUnicodeInfo.GetUnicodeCategory(ch) != UnicodeCategory.NonSpacingMark)
            {
                builder.Append(ch);
            }
        }
        return builder.ToString().Normalize(NormalizationForm.FormC).ToLowerInvariant();
    }

    /// <summary>Tokenize a query string into whitespace-separated, folded, non-empty tokens.</summary>
    public static IReadOnlyList<string> Tokenize(string query)
    {
        return Fold(query)
            .Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)
            .ToArray();
    }

    private static string FoldedTitle(SettingsItem item) => Fold(item.Title);
}

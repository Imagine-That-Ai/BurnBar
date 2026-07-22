using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Presentation.SessionLogs;

/// <summary>
/// Deterministic command-palette ranking over the session-log read seam. FTS ids
/// are authoritative when available; the bounded metadata fallback keeps the
/// palette useful for older databases that do not have an FTS table.
/// </summary>
public static class SessionLogSearch
{
    private const int MaxSearchTextCharacters = 8 * 1024;

    public static IReadOnlyList<SessionLogRecord> Rank(
        string? query,
        IReadOnlyList<SessionLogRecord> records,
        IReadOnlyList<string>? rankedIds = null,
        int limit = 50)
    {
        ArgumentNullException.ThrowIfNull(records);
        if (limit is < 1 or > 200)
        {
            throw new ArgumentOutOfRangeException(nameof(limit));
        }

        string normalized = (query ?? string.Empty).Trim();
        var byId = records
            .Where(record => !string.IsNullOrWhiteSpace(record.Id))
            .GroupBy(record => record.Id, StringComparer.Ordinal)
            .ToDictionary(group => group.Key, group => group.First(), StringComparer.Ordinal);

        if (normalized.Length == 0)
        {
            return records
                .OrderByDescending(record => record.TimelineDate)
                .ThenBy(record => record.Id, StringComparer.Ordinal)
                .Take(limit)
                .ToArray();
        }

        var seen = new HashSet<string>(StringComparer.Ordinal);
        var results = new List<SessionLogRecord>(Math.Min(limit, records.Count));

        if (rankedIds is not null)
        {
            foreach (string id in rankedIds)
            {
                if (results.Count == limit)
                {
                    break;
                }

                if (byId.TryGetValue(id, out SessionLogRecord? record) && seen.Add(record.Id))
                {
                    results.Add(record);
                }
            }
        }

        if (results.Count == limit)
        {
            return results;
        }

        // A non-empty FTS result is authoritative. Only use metadata fallback
        // when the database returned no usable ids (older/non-FTS layouts).
        if (results.Count > 0)
        {
            return results;
        }

        var terms = normalized
            .Split(new[] { ' ', '\t', '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(term => term.Trim())
            .Where(term => term.Length > 0)
            .ToArray();

        var fallback = records
            .Where(record => !seen.Contains(record.Id))
            .Select(record => (Record: record, Score: MetadataScore(record, terms)))
            .Where(candidate => candidate.Score < int.MaxValue)
            .OrderBy(candidate => candidate.Score)
            .ThenByDescending(candidate => candidate.Record.TimelineDate)
            .ThenBy(candidate => candidate.Record.Id, StringComparer.Ordinal);

        foreach ((SessionLogRecord record, _) in fallback)
        {
            if (results.Count == limit)
            {
                break;
            }

            if (seen.Add(record.Id))
            {
                results.Add(record);
            }
        }

        return results;
    }

    private static int MetadataScore(SessionLogRecord record, IReadOnlyList<string> terms)
    {
        string title = record.DisplayTitle.Trim();
        string project = record.ProjectName.Trim();
        string provider = record.ProviderDisplayName.Trim();
        string session = record.SessionId.Trim();
        string fullText = record.FullText.Length > MaxSearchTextCharacters
            ? record.FullText[..MaxSearchTextCharacters]
            : record.FullText;
        string[] fields = { title, project, provider, session, fullText };

        int total = 0;
        foreach (string term in terms)
        {
            if (title.Contains(term, StringComparison.OrdinalIgnoreCase))
            {
                total += title.StartsWith(term, StringComparison.OrdinalIgnoreCase) ? 0 : 10;
                continue;
            }

            if (project.Contains(term, StringComparison.OrdinalIgnoreCase)
                || provider.Contains(term, StringComparison.OrdinalIgnoreCase)
                || session.Contains(term, StringComparison.OrdinalIgnoreCase))
            {
                total += 20;
                continue;
            }

            if (fullText.Contains(term, StringComparison.OrdinalIgnoreCase))
            {
                total += 40;
                continue;
            }

            if (fields.Any(field => MatchesSubsequence(term, field)))
            {
                total += 60;
                continue;
            }

            return int.MaxValue;
        }

        return total;
    }

    private static bool MatchesSubsequence(string pattern, string text)
    {
        int patternIndex = 0;
        foreach (char character in text)
        {
            if (patternIndex < pattern.Length
                && char.ToLowerInvariant(pattern[patternIndex]) == char.ToLowerInvariant(character))
            {
                patternIndex++;
            }

            if (patternIndex == pattern.Length)
            {
                return true;
            }
        }

        return patternIndex == pattern.Length;
    }
}

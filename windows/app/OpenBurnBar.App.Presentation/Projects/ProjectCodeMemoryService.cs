using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.Presentation.Projects;

/// <summary>
/// Long-lived Windows project-code memory seam. It keeps only bounded symbol
/// metadata and integrity state; source text is read transiently by the parser
/// and never enters the persisted index or companion responses.
/// </summary>
public sealed class ProjectCodeMemoryService : IDisposable
{
    private readonly ProjectCodeSymbolIndex _index;
    private readonly IProjectCodeStaticParserClient? _parser;

    public ProjectCodeMemoryService(
        ProjectCodeSymbolIndex index,
        IProjectCodeStaticParserClient? parser = null)
    {
        _index = index ?? throw new ArgumentNullException(nameof(index));
        _parser = parser;
    }

    public ProjectCodeIndexSnapshot? Snapshot => _index.Snapshot;

    public string Root => _index.Root;

    public bool IsWatching => _index.IsWatching;

    public IReadOnlyList<ProjectCodeSymbol> Symbols => _index.Symbols;

    public bool TryLoad() => _index.TryLoad();

    public void StartWatching() => _index.StartWatching();

    public Task<ProjectCodeIndexSnapshot> RefreshAsync(CancellationToken cancellationToken = default)
    {
        if (_parser is not null)
        {
            return _index.RefreshWithParserAsync(_parser, cancellationToken);
        }

        return Task.Run(_index.Refresh, cancellationToken);
    }

    public IReadOnlyList<ProjectCodeSearchHit> Search(string query, int limit = 50)
    {
        string normalized = (query ?? string.Empty).Trim();
        if (normalized.Length == 0 || normalized.Length > 256)
        {
            throw new ArgumentException("A search query between 1 and 256 characters is required.", nameof(query));
        }

        if (limit is < 1 or > 100)
        {
            throw new ArgumentOutOfRangeException(nameof(limit));
        }

        var hits = new List<ProjectCodeSearchHit>();
        foreach (ProjectCodeSymbol symbol in _index.Symbols)
        {
            int score = Score(symbol, normalized);
            if (score >= 0)
            {
                hits.Add(new ProjectCodeSearchHit(symbol, score));
            }
        }

        return hits
            .OrderBy(hit => hit.Score)
            .ThenBy(hit => hit.Symbol.Name, StringComparer.OrdinalIgnoreCase)
            .ThenBy(hit => hit.Symbol.FilePath, StringComparer.OrdinalIgnoreCase)
            .ThenBy(hit => hit.Symbol.Line)
            .Take(limit)
            .ToArray();
    }

    public IReadOnlyList<ProjectCodeSymbol> FindSymbol(string name, int limit = 50)
    {
        string normalized = (name ?? string.Empty).Trim();
        if (normalized.Length == 0 || normalized.Length > 256)
        {
            throw new ArgumentException("A symbol name between 1 and 256 characters is required.", nameof(name));
        }

        if (limit is < 1 or > 100)
        {
            throw new ArgumentOutOfRangeException(nameof(limit));
        }

        return _index.Symbols
            .Where(symbol => string.Equals(symbol.Name, normalized, StringComparison.OrdinalIgnoreCase))
            .OrderBy(symbol => symbol.FilePath, StringComparer.OrdinalIgnoreCase)
            .ThenBy(symbol => symbol.Line)
            .Take(limit)
            .ToArray();
    }

    public void Dispose() => _index.Dispose();

    private static int Score(ProjectCodeSymbol symbol, string query)
    {
        if (string.Equals(symbol.Name, query, StringComparison.OrdinalIgnoreCase))
        {
            return 0;
        }

        if (symbol.Name.StartsWith(query, StringComparison.OrdinalIgnoreCase))
        {
            return 10;
        }

        if (symbol.Name.Contains(query, StringComparison.OrdinalIgnoreCase))
        {
            return 20;
        }

        return symbol.FilePath.Contains(query, StringComparison.OrdinalIgnoreCase) ? 30 : -1;
    }
}

public sealed record ProjectCodeSearchHit(ProjectCodeSymbol Symbol, int Score);

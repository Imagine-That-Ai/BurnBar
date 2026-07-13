using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.Presentation.Projects;

/// <summary>
/// Long-lived Windows project-code memory seam. It keeps only bounded symbol
/// metadata and integrity state. Source text is read only for an explicit,
/// bounded context-pack request; it is never persisted and is always wrapped as
/// untrusted data before it leaves the service.
/// </summary>
public sealed class ProjectCodeMemoryService : IDisposable
{
    public const int MaxContextPackHits = 20;
    public const int MaxContextPackBytes = 64 * 1024;
    private const int ContextLinesAroundSymbol = 3;
    private const int MaxSourceLineCharacters = 16 * 1024;
    private const long MaxSourceFileBytes = 8 * 1024 * 1024;
    private static readonly Regex SecretAssignment = new(
        "(?i)(\\b(?:api[_-]?key|secret|token|password|authorization)\\b\\s*[:=]\\s*)([\\\"']?)[A-Za-z0-9_./+=:-]{12,}\\2",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);
    private static readonly Regex KnownSecretToken = new(
        "(?i)(?:sk-(?:ant-)?|gh[pousr]_|xox[baprs]-|AIza)[A-Za-z0-9_./+=:-]{12,}",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);
    private static readonly Regex PrivateKey = new(
        "-----BEGIN [A-Z0-9 ]+ PRIVATE KEY-----[\\s\\S]*?-----END [A-Z0-9 ]+ PRIVATE KEY-----",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);
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

    public bool HasDurableStore => _index.HasDurableStore;

    public ProjectCodeMemoryStoreStats? DurableStoreStats => _index.DurableStoreStats;

    public ProjectCodeCallGraphResult ReadCallGraph(string name, int limit = 200, int depth = 1) =>
        _index.ReadCallGraph(name, limit, depth);

    public ProjectCodeSemanticSearchResult ReadSemanticSearch(string query, int limit = 20) =>
        _index.ReadSemanticSearch(query, limit);

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

    /// <summary>
    /// Resolves references for a source location through the configured LSP
    /// parser. The public API uses one-based source lines like the symbol index;
    /// the parser request remains zero-based. Paths are confined to the project
    /// root before any source is sent to the helper.
    /// </summary>
    public async Task<ProjectCodeReferencesResult> FindReferencesAsync(
        string filePath,
        int line,
        int character,
        CancellationToken cancellationToken = default)
    {
        if (_parser is null)
        {
            throw new ProjectCodeParserException("project_code_references_unavailable");
        }

        if (line is < 1 or > 1_000_000)
        {
            throw new ArgumentOutOfRangeException(nameof(line));
        }

        if (character is < 0 or > 1_000_000)
        {
            throw new ArgumentOutOfRangeException(nameof(character));
        }

        string fullPath;
        try
        {
            fullPath = Path.GetFullPath(
                Path.IsPathRooted(filePath) ? filePath : Path.Combine(Root, filePath));
        }
        catch (Exception error) when (error is ArgumentException or NotSupportedException)
        {
            throw new ArgumentException("A valid project file path is required.", nameof(filePath), error);
        }

        string rootPrefix = Root.EndsWith(Path.DirectorySeparatorChar)
            ? Root
            : Root + Path.DirectorySeparatorChar;
        if (!fullPath.StartsWith(rootPrefix, StringComparison.OrdinalIgnoreCase)
            || !File.Exists(fullPath))
        {
            throw new ArgumentException("The file path must identify a file inside the project root.", nameof(filePath));
        }

        string text = await File.ReadAllTextAsync(fullPath, cancellationToken).ConfigureAwait(false);
        string relativePath = Path.GetRelativePath(Root, fullPath).Replace('\\', '/');
        string language = Path.GetExtension(fullPath).TrimStart('.').ToLowerInvariant();
        ProjectCodeParseResponse response = await _parser.ParseAsync(
            new ProjectCodeParseRequest(
                Guid.NewGuid().ToString("N"),
                relativePath,
                language,
                JsonLinesProjectCodeStaticParserClient.ComputeGitBlobSha(text),
                text,
                Root,
                Operation: "references",
                Position: new ProjectCodeParsePosition(line - 1, character)),
            cancellationToken).ConfigureAwait(false);

        return new ProjectCodeReferencesResult(
            relativePath,
            line,
            character,
            response.Ok,
            response.ShaMatch,
            response.References ?? Array.Empty<ProjectCodeParsedReference>(),
            response.Errors);
    }

    /// <summary>
    /// Builds a transient source context pack for an explicit query. The index
    /// remains metadata-only; snippets are bounded, path-confined, secret
    /// redacted, and marked as untrusted so callers cannot mistake source data
    /// for instructions.
    /// </summary>
    public ProjectCodeContextPack BuildContextPack(
        string query,
        int limit = 10,
        int maxBytes = 24_000)
    {
        string normalized = (query ?? string.Empty).Trim();
        if (normalized.Length == 0 || normalized.Length > 256)
        {
            throw new ArgumentException("A context query between 1 and 256 characters is required.", nameof(query));
        }

        if (limit is < 1 or > MaxContextPackHits)
        {
            throw new ArgumentOutOfRangeException(nameof(limit));
        }

        if (maxBytes is < 1 or > MaxContextPackBytes)
        {
            throw new ArgumentOutOfRangeException(nameof(maxBytes));
        }

        IReadOnlyList<ProjectCodeSearchHit> hits = Search(normalized, limit);
        var context = new StringBuilder();
        var included = new List<ProjectCodeSearchHit>();
        bool truncated = false;
        foreach (ProjectCodeSearchHit hit in hits)
        {
            string? snippet = ReadSnippet(hit.Symbol);
            if (snippet is null)
            {
                continue;
            }

            string block = BuildContextBlock(hit.Symbol, snippet);
            int remaining = maxBytes - Encoding.UTF8.GetByteCount(context.ToString());
            if (remaining <= 0)
            {
                truncated = true;
                break;
            }

            if (Encoding.UTF8.GetByteCount(block) > remaining)
            {
                context.Append(TakeUtf8Prefix(block, remaining));
                included.Add(hit);
                truncated = true;
                break;
            }

            context.Append(block);
            included.Add(hit);
        }

        return new ProjectCodeContextPack(
            normalized,
            context.ToString(),
            included,
            truncated || included.Count < hits.Count,
            UntrustedContentWrapped: included.Count > 0,
            WrappedCount: included.Count);
    }

    public void Dispose() => _index.Dispose();

    private string? ReadSnippet(ProjectCodeSymbol symbol)
    {
        string fullPath;
        try
        {
            fullPath = Path.GetFullPath(symbol.FilePath);
        }
        catch (ArgumentException)
        {
            return null;
        }

        string rootPrefix = Root.EndsWith(Path.DirectorySeparatorChar)
            ? Root
            : Root + Path.DirectorySeparatorChar;
        if (!fullPath.StartsWith(rootPrefix, StringComparison.OrdinalIgnoreCase)
            || !File.Exists(fullPath))
        {
            return null;
        }

        try
        {
            if (new FileInfo(fullPath).Length > MaxSourceFileBytes)
            {
                return null;
            }

            int startLine = Math.Max(1, symbol.Line - ContextLinesAroundSymbol);
            int endLine = symbol.Line + ContextLinesAroundSymbol;
            var lines = new List<string>(ContextLinesAroundSymbol * 2 + 1);
            int lineNumber = 0;
            foreach (string line in File.ReadLines(fullPath))
            {
                lineNumber++;
                if (lineNumber < startLine)
                {
                    continue;
                }

                if (lineNumber > endLine)
                {
                    break;
                }

                string bounded = line.Length > MaxSourceLineCharacters
                    ? line[..MaxSourceLineCharacters] + " [line truncated]"
                    : line;
                lines.Add(RedactSecrets(bounded));
            }

            return lines.Count == 0 ? null : string.Join(Environment.NewLine, lines);
        }
        catch (IOException)
        {
            return null;
        }
        catch (UnauthorizedAccessException)
        {
            return null;
        }
    }

    private string BuildContextBlock(ProjectCodeSymbol symbol, string snippet)
    {
        string relativePath = Path.GetRelativePath(Root, symbol.FilePath).Replace('\\', '/');
        string safeName = SanitizeHeaderValue(symbol.Name);
        string safePath = SanitizeHeaderValue(relativePath);
        return $"[project-code file=\"{safePath}\" line={symbol.Line} symbol=\"{safeName}\"]{Environment.NewLine}"
            + $"<<<UNTRUSTED_SOURCE_BEGIN>>>{Environment.NewLine}{snippet}{Environment.NewLine}"
            + $"<<<UNTRUSTED_SOURCE_END>>>{Environment.NewLine}{Environment.NewLine}";
    }

    private static string RedactSecrets(string text)
    {
        string redacted = PrivateKey.Replace(text, "[REDACTED_PRIVATE_KEY]");
        redacted = SecretAssignment.Replace(redacted, "$1$2[REDACTED]$2");
        return KnownSecretToken.Replace(redacted, "[REDACTED_TOKEN]");
    }

    private static string SanitizeHeaderValue(string value) =>
        value.Replace('\r', ' ').Replace('\n', ' ').Replace('"', '\'');

    private static string TakeUtf8Prefix(string value, int maxBytes)
    {
        if (maxBytes <= 0)
        {
            return string.Empty;
        }

        int bytes = 0;
        int characters = 0;
        foreach (Rune rune in value.EnumerateRunes())
        {
            int runeBytes = Encoding.UTF8.GetByteCount(rune.ToString());
            if (bytes + runeBytes > maxBytes)
            {
                break;
            }

            bytes += runeBytes;
            characters += rune.Utf16SequenceLength;
        }

        return value[..characters];
    }

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

public sealed record ProjectCodeContextPack(
    string Query,
    string Context,
    IReadOnlyList<ProjectCodeSearchHit> Hits,
    bool Truncated,
    bool UntrustedContentWrapped,
    int WrappedCount);

public sealed record ProjectCodeReferencesResult(
    string FilePath,
    int Line,
    int Character,
    bool Ok,
    bool ShaMatch,
    IReadOnlyList<ProjectCodeParsedReference> References,
    IReadOnlyList<string> Errors);

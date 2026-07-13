using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.Presentation.Projects;

/// <summary>
/// Bounded project-code symbol index for Pensieve/project search. The index stores
/// symbol metadata only; source text is read transiently and is never persisted.
/// </summary>
public sealed class ProjectCodeSymbolIndex : IDisposable
{
    private static readonly Regex Declaration = new(
        "(?i)(?:\\b(?:class|struct|enum|interface|protocol|actor|func|function|def|fn|const|let|var|type)\\s+([A-Za-z_][A-Za-z0-9_]*)|\\b(?:void|bool|int|string|double|float|task|[A-Z][A-Za-z0-9_<>]*)\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*\\()",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private readonly string _root;
    private readonly string _indexPath;
    private readonly int _maxFiles;
    private readonly int _maxSymbols;
    private readonly ProjectCodeMemoryStore? _store;
    private IProjectCodeStaticParserClient? _parser;
    private readonly object _gate = new();
    private FileSystemWatcher? _watcher;
    private Timer? _refreshTimer;
    private IReadOnlyList<ProjectCodeSymbol> _symbols = Array.Empty<ProjectCodeSymbol>();
    private ProjectCodeIndexSnapshot? _snapshot;

    public ProjectCodeSymbolIndex(
        string root,
        string? indexPath = null,
        int maxFiles = 500,
        int maxSymbols = 10_000,
        IProjectCodeStaticParserClient? parser = null,
        ProjectCodeMemoryStore? store = null)
    {
        if (string.IsNullOrWhiteSpace(root))
        {
            throw new ArgumentException("A project root is required.", nameof(root));
        }

        if (maxFiles <= 0 || maxSymbols <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(maxFiles));
        }

        _root = Path.GetFullPath(root);
        _indexPath = Path.GetFullPath(indexPath ?? Path.Combine(_root, ".openburnbar", "project-symbols.json"));
        _maxFiles = maxFiles;
        _maxSymbols = maxSymbols;
        _parser = parser;
        _store = store;
    }

    public IReadOnlyList<ProjectCodeSymbol> Symbols
    {
        get
        {
            lock (_gate)
            {
                return _symbols.ToArray();
            }
        }
    }

    public string Root => _root;

    public bool IsWatching => _watcher is not null;

    public bool HasDurableStore => _store is not null;

    public ProjectCodeMemoryStoreStats? DurableStoreStats => _store?.ReadStats();

    public ProjectCodeCallGraphResult ReadCallGraph(string name, int limit = 200, int depth = 1) =>
        _store?.ReadCallGraph(name, limit, depth)
        ?? throw new ProjectCodeParserException("project_code_call_graph_unavailable");

    public ProjectCodeSemanticSearchResult ReadSemanticSearch(string query, int limit = 20) =>
        _store?.ReadSemanticSearch(query, limit)
        ?? throw new ProjectCodeParserException("project_code_semantic_search_unavailable");

    public ProjectCodeIndexSnapshot? Snapshot
    {
        get
        {
            lock (_gate)
            {
                return _snapshot;
            }
        }
    }

    public ProjectCodeIndexSnapshot Refresh()
    {
        if (!Directory.Exists(_root))
        {
            SetSymbols(Array.Empty<ProjectCodeSymbol>());
            return Persist();
        }

        var symbols = new List<ProjectCodeSymbol>();
        ProjectCodeInventory inventory = ProjectCodeLexicalScanner.Scan(_root, _maxFiles);
        foreach (string path in EnumerateCodeFiles(_root, _maxFiles))
        {
            if (symbols.Count >= _maxSymbols)
            {
                break;
            }

            try
            {
                string[] lines = File.ReadAllLines(path);
                for (int i = 0; i < lines.Length && symbols.Count < _maxSymbols; i++)
                {
                    foreach (Match match in Declaration.Matches(lines[i]))
                    {
                        string name = match.Groups[1].Success
                            ? match.Groups[1].Value
                            : match.Groups[2].Value;
                        string kind = match.Groups[1].Success
                            ? lines[i][Math.Max(0, match.Index)..].Split(' ', StringSplitOptions.RemoveEmptyEntries)[0]
                            : "method";
                        symbols.Add(new ProjectCodeSymbol(name, kind.ToLowerInvariant(), path, i + 1));
                    }
                }
            }
            catch (UnauthorizedAccessException)
            {
                // An unreadable file is omitted from the honest index.
            }
            catch (IOException)
            {
                // A file can disappear while a watcher-triggered refresh runs.
            }
        }

        SetSymbols(symbols);
        ProjectCodeIndexSnapshot snapshot = Persist(inventory.Truncated || symbols.Count >= _maxSymbols);
        return snapshot;
    }

    /// <summary>
    /// Refreshes the index through the bundled Tree-sitter parser. If a file
    /// cannot be parsed, it is omitted rather than represented by fabricated
    /// symbols; callers can use <see cref="Refresh"/> for the explicit lexical
    /// fallback when the parser is unavailable.
    /// </summary>
    public async Task<ProjectCodeIndexSnapshot> RefreshWithParserAsync(
        IProjectCodeStaticParserClient parser,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(parser);
        _parser = parser;
        if (!Directory.Exists(_root))
        {
            SetSymbols(Array.Empty<ProjectCodeSymbol>());
            return Persist(parserMode: "tree-sitter");
        }

        var symbols = new List<ProjectCodeSymbol>();
        bool truncated = false;
        foreach (string path in EnumerateCodeFiles(_root, _maxFiles))
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (symbols.Count >= _maxSymbols)
            {
                truncated = true;
                break;
            }

            string text;
            try
            {
                text = File.ReadAllText(path);
            }
            catch (UnauthorizedAccessException)
            {
                continue;
            }
            catch (IOException)
            {
                continue;
            }

            string language = Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
            if (!ProjectCodeLexicalScanner.SupportsTreeSitter(path))
            {
                AppendLexicalSymbols(path, symbols, _maxSymbols);
                if (symbols.Count >= _maxSymbols)
                {
                    truncated = true;
                    break;
                }

                continue;
            }

            ProjectCodeParseResponse response;
            try
            {
                response = await parser.ParseAsync(
                    new ProjectCodeParseRequest(
                        Guid.NewGuid().ToString("N"),
                        path,
                        language,
                        JsonLinesProjectCodeStaticParserClient.ComputeGitBlobSha(text),
                        text,
                        _root),
                    cancellationToken).ConfigureAwait(false);
            }
            catch (ProjectCodeParserException)
            {
                continue;
            }

            if (!response.Ok || !response.ShaMatch)
            {
                continue;
            }

            foreach (ProjectCodeParsedSymbol symbol in response.Symbols)
            {
                if (symbols.Count >= _maxSymbols)
                {
                    truncated = true;
                    break;
                }

                symbols.Add(new ProjectCodeSymbol(
                    symbol.Name,
                    symbol.Kind,
                    path,
                    symbol.StartLine,
                    symbol.ConfidenceTier,
                    symbol.Parser,
                    symbol.EndLine));
            }
        }

        SetSymbols(symbols);
        return Persist(truncated, parserMode: "tree-sitter");
    }

    public bool TryLoad()
    {
        if (_store is not null && _store.TryLoad(_root, out ProjectCodeIndexSnapshot durableSnapshot))
        {
            SetSymbols(durableSnapshot.Symbols);
            lock (_gate)
            {
                _snapshot = durableSnapshot;
            }

            return true;
        }

        try
        {
            if (!File.Exists(_indexPath))
            {
                return false;
            }

            string json = File.ReadAllText(_indexPath);
            ProjectCodeIndexSnapshot? snapshot = JsonSerializer.Deserialize<ProjectCodeIndexSnapshot>(json);
            if (snapshot is null || !string.Equals(snapshot.Root, _root, StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }

            SetSymbols(snapshot.Symbols);
            lock (_gate)
            {
                _snapshot = snapshot;
            }
            return true;
        }
        catch (JsonException)
        {
            return false;
        }
        catch (IOException)
        {
            return false;
        }
    }

    public void StartWatching()
    {
        if (!Directory.Exists(_root) || _watcher is not null)
        {
            return;
        }

        _watcher = new FileSystemWatcher(_root)
        {
            IncludeSubdirectories = true,
            Filter = "*.*",
            NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size,
            EnableRaisingEvents = true,
        };
        _watcher.Created += OnChanged;
        _watcher.Changed += OnChanged;
        _watcher.Deleted += OnChanged;
        _watcher.Renamed += OnRenamed;
    }

    public void Dispose()
    {
        _watcher?.Dispose();
        _watcher = null;
        _refreshTimer?.Dispose();
        _refreshTimer = null;
        _store?.Dispose();
    }

    private static IEnumerable<string> EnumerateCodeFiles(string root, int maxFiles)
    {
        int count = 0;
        IEnumerable<string> files;
        try
        {
            files = Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories);
        }
        catch (IOException)
        {
            yield break;
        }
        catch (UnauthorizedAccessException)
        {
            yield break;
        }

        foreach (string path in files)
        {
            if (!IsCodeFile(path))
            {
                continue;
            }

            yield return path;
            count++;
            if (count >= maxFiles)
            {
                yield break;
            }
        }
    }

    private static bool IsCodeFile(string path) => ProjectCodeLexicalScanner.IsCodeFile(path);

    private static void AppendLexicalSymbols(string path, List<ProjectCodeSymbol> symbols, int maxSymbols)
    {
        try
        {
            string[] lines = File.ReadAllLines(path);
            for (int i = 0; i < lines.Length && symbols.Count < maxSymbols; i++)
            {
                foreach (Match match in Declaration.Matches(lines[i]))
                {
                    string name = match.Groups[1].Success ? match.Groups[1].Value : match.Groups[2].Value;
                    string kind = match.Groups[1].Success
                        ? lines[i][Math.Max(0, match.Index)..].Split(' ', StringSplitOptions.RemoveEmptyEntries)[0]
                        : "method";
                    symbols.Add(new ProjectCodeSymbol(name, kind.ToLowerInvariant(), path, i + 1));
                }
            }
        }
        catch (UnauthorizedAccessException)
        {
            // An unreadable file is omitted from the honest index.
        }
        catch (IOException)
        {
            // A file can disappear while a parser-backed refresh runs.
        }
    }

    private void OnChanged(object sender, FileSystemEventArgs args) => ScheduleRefresh();

    private void OnRenamed(object sender, RenamedEventArgs args) => ScheduleRefresh();

    private void ScheduleRefresh()
    {
        lock (_gate)
        {
            _refreshTimer ??= new Timer(_ => _ = RefreshFromWatcherAsync(), null, Timeout.Infinite, Timeout.Infinite);
            _refreshTimer.Change(250, Timeout.Infinite);
        }
    }

    private async Task RefreshFromWatcherAsync()
    {
        try
        {
            IProjectCodeStaticParserClient? parser = _parser;
            if (parser is null)
            {
                Refresh();
            }
            else
            {
                await RefreshWithParserAsync(parser).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException)
        {
            // A superseding watcher event can cancel the in-flight refresh.
        }
        catch (ProjectCodeParserException)
        {
            // Keep the last good index when the parser process is unavailable.
        }
    }

    private void SetSymbols(IReadOnlyList<ProjectCodeSymbol> symbols)
    {
        lock (_gate)
        {
            _symbols = symbols.ToArray();
        }
    }

    private ProjectCodeIndexSnapshot Persist(bool truncated = false, string parserMode = "lexical")
    {
        ProjectCodeIndexSnapshot snapshot = new(_root, DateTimeOffset.UtcNow, Symbols, truncated, parserMode);
        lock (_gate)
        {
            _snapshot = snapshot;
        }
        _store?.SaveIndex(_root, snapshot);
        try
        {
            string? directory = Path.GetDirectoryName(_indexPath);
            if (!string.IsNullOrWhiteSpace(directory))
            {
                Directory.CreateDirectory(directory);
            }

            string tempPath = _indexPath + ".tmp";
            File.WriteAllText(tempPath, JsonSerializer.Serialize(snapshot));
            File.Move(tempPath, _indexPath, overwrite: true);
        }
        catch (IOException)
        {
            // Persistence is best effort; the in-memory index remains usable.
        }

        return snapshot;
    }
}

public sealed record ProjectCodeSymbol(
    string Name,
    string Kind,
    string FilePath,
    int Line,
    string ConfidenceTier = "lexical_fallback",
    string Parser = "lexical",
    int? EndLine = null);

public sealed record ProjectCodeIndexSnapshot(
    string Root,
    DateTimeOffset RefreshedAt,
    IReadOnlyList<ProjectCodeSymbol> Symbols,
    bool Truncated,
    string ParserMode = "lexical");

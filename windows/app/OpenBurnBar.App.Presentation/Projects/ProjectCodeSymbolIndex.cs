using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;

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
    private readonly object _gate = new();
    private FileSystemWatcher? _watcher;
    private Timer? _refreshTimer;
    private IReadOnlyList<ProjectCodeSymbol> _symbols = Array.Empty<ProjectCodeSymbol>();

    public ProjectCodeSymbolIndex(
        string root,
        string? indexPath = null,
        int maxFiles = 500,
        int maxSymbols = 10_000)
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

    public bool TryLoad()
    {
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

    private static bool IsCodeFile(string path) =>
        path.EndsWith(".cs", StringComparison.OrdinalIgnoreCase)
        || path.EndsWith(".swift", StringComparison.OrdinalIgnoreCase)
        || path.EndsWith(".ts", StringComparison.OrdinalIgnoreCase)
        || path.EndsWith(".tsx", StringComparison.OrdinalIgnoreCase)
        || path.EndsWith(".js", StringComparison.OrdinalIgnoreCase)
        || path.EndsWith(".jsx", StringComparison.OrdinalIgnoreCase)
        || path.EndsWith(".py", StringComparison.OrdinalIgnoreCase)
        || path.EndsWith(".rs", StringComparison.OrdinalIgnoreCase)
        || path.EndsWith(".kt", StringComparison.OrdinalIgnoreCase)
        || path.EndsWith(".java", StringComparison.OrdinalIgnoreCase)
        || path.EndsWith(".go", StringComparison.OrdinalIgnoreCase);

    private void OnChanged(object sender, FileSystemEventArgs args) => ScheduleRefresh();

    private void OnRenamed(object sender, RenamedEventArgs args) => ScheduleRefresh();

    private void ScheduleRefresh()
    {
        lock (_gate)
        {
            _refreshTimer ??= new Timer(_ => Refresh(), null, Timeout.Infinite, Timeout.Infinite);
            _refreshTimer.Change(250, Timeout.Infinite);
        }
    }

    private void SetSymbols(IReadOnlyList<ProjectCodeSymbol> symbols)
    {
        lock (_gate)
        {
            _symbols = symbols.ToArray();
        }
    }

    private ProjectCodeIndexSnapshot Persist(bool truncated = false)
    {
        ProjectCodeIndexSnapshot snapshot = new(_root, DateTimeOffset.UtcNow, Symbols, truncated);
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

public sealed record ProjectCodeSymbol(string Name, string Kind, string FilePath, int Line);

public sealed record ProjectCodeIndexSnapshot(
    string Root,
    DateTimeOffset RefreshedAt,
    IReadOnlyList<ProjectCodeSymbol> Symbols,
    bool Truncated);

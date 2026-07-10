namespace OpenBurnBar.App.UsageRuntime;

public sealed class WindowsUsageLogDiscovery : IUsageLogDiscovery
{
    public const int DefaultMaxFiles = 5_000;

    private readonly IReadOnlyList<DiscoveryRoot> _roots;
    private readonly int _maxFiles;

    public WindowsUsageLogDiscovery(
        string userProfile,
        string? appData = null,
        int maxFiles = DefaultMaxFiles)
        : this(DefaultRoots(userProfile, appData), maxFiles)
    {
    }

    public WindowsUsageLogDiscovery(IReadOnlyList<DiscoveryRoot> roots, int maxFiles = DefaultMaxFiles)
    {
        _roots = roots ?? throw new ArgumentNullException(nameof(roots));
        _maxFiles = Math.Max(1, maxFiles);
        WatchRoots = _roots
            .Select(root => root.Path)
            .Where(Directory.Exists)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    public IReadOnlyList<string> WatchRoots { get; }

    public IReadOnlyList<DiscoveredUsageLog> Discover(CancellationToken cancellationToken = default)
    {
        var logs = new List<DiscoveredUsageLog>();
        var options = new EnumerationOptions
        {
            RecurseSubdirectories = true,
            IgnoreInaccessible = true,
            AttributesToSkip = FileAttributes.ReparsePoint | FileAttributes.System,
            MatchCasing = MatchCasing.CaseInsensitive,
        };

        foreach (DiscoveryRoot root in _roots)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!Directory.Exists(root.Path))
            {
                continue;
            }

            foreach (string path in Directory.EnumerateFiles(root.Path, "*", options))
            {
                cancellationToken.ThrowIfCancellationRequested();
                string extension = Path.GetExtension(path);
                if (!extension.Equals(".jsonl", StringComparison.OrdinalIgnoreCase)
                    && !extension.Equals(".json", StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                try
                {
                    var info = new FileInfo(path);
                    if (info.Length == 0)
                    {
                        continue;
                    }

                    logs.Add(new DiscoveredUsageLog(root.Provider, info.FullName, info.LastWriteTimeUtc));
                }
                catch (IOException)
                {
                    // A provider can rotate a log between enumeration and metadata access.
                }
                catch (UnauthorizedAccessException)
                {
                    // Inaccessible provider folders remain an honest partial scan.
                }
            }
        }

        return logs
            .OrderByDescending(log => log.LastWriteAt)
            .ThenBy(log => log.Path, StringComparer.OrdinalIgnoreCase)
            .Take(_maxFiles)
            .ToArray();
    }

    public static IReadOnlyList<DiscoveryRoot> DefaultRoots(string userProfile, string? appData = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(userProfile);
        string roaming = string.IsNullOrWhiteSpace(appData)
            ? Path.Combine(userProfile, "AppData", "Roaming")
            : appData;
        return new[]
        {
            new DiscoveryRoot("claude", Path.Combine(userProfile, ".claude", "projects")),
            new DiscoveryRoot("claude", Path.Combine(userProfile, ".claude", "transcripts")),
            new DiscoveryRoot("codex", Path.Combine(userProfile, ".codex", "sessions")),
            new DiscoveryRoot("grok", Path.Combine(userProfile, ".grok", "sessions")),
            new DiscoveryRoot("gemini", Path.Combine(userProfile, ".gemini", "tmp")),
            new DiscoveryRoot("factory", Path.Combine(userProfile, ".factory", "sessions")),
            new DiscoveryRoot("cursor", Path.Combine(userProfile, ".cursor", "projects")),
            new DiscoveryRoot("cursor", Path.Combine(roaming, "Cursor", "User", "workspaceStorage")),
        };
    }
}

public sealed record DiscoveryRoot(string Provider, string Path);

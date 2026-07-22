using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using OpenBurnBar.CloudSync.Crypto;

namespace OpenBurnBar.App.CloudSync.Pensieve;

/// <summary>
/// Live Windows watcher for repo docs, notes, and settled Claude sessions. It
/// writes only encrypted knowledge batches and metadata-only session sentinels
/// into the shared device queue; it never authenticates to Firebase.
/// </summary>
public sealed class PensieveKnowledgeWatcher : IAsyncDisposable
{
    public const string QueueOverrideEnvironmentVariable = "OPENBURNBAR_PENSIEVE_QUEUE_DIR";
    public const string RepoDocsEnvironmentVariable = "OPENBURNBAR_PENSIEVE_REPO_DOCS_PATH";
    public const string NotesEnvironmentVariable = "OPENBURNBAR_PENSIEVE_NOTES_PATH";

    private const int EnqueuedVectorIdsCap = 65_536;
    private const int MaximumSourceFilesPerScan = 20_000;
    private const long MaximumSourceFileBytes = 16L * 1024 * 1024;

    private readonly object _stateGate = new();
    private readonly SemaphoreSlim _scanGate = new(1, 1);
    private readonly IReadOnlyList<PensieveWatchRoot> _roots;
    private readonly string _queueDirectory;
    private readonly Func<byte[]?> _vaultKeyProvider;
    private readonly TimeSpan _debounceInterval;
    private readonly TimeSpan _backstopInterval;
    private readonly TimeProvider _timeProvider;
    private readonly Action<Exception>? _errorSink;
    private readonly HashSet<string> _enqueuedVectorIds = new(StringComparer.Ordinal);
    private readonly List<FileSystemWatcher> _watchers = new();
    private readonly HashSet<Task> _backgroundTasks = new();

    private CancellationTokenSource? _lifetime;
    private CancellationTokenSource? _debounce;
    private Task? _debounceTask;
    private Task? _backstopTask;
    private DateTimeOffset? _lastScanAt;
    private DateTimeOffset? _lastEnqueueAt;
    private int _lastEnqueuedCount;
    private PensieveWatcherErrorCode _errorCode;

    public PensieveKnowledgeWatcher(
        IReadOnlyList<PensieveWatchRoot> roots,
        string queueDirectory,
        Func<byte[]?> vaultKeyProvider,
        TimeSpan? debounceInterval = null,
        TimeSpan? backstopInterval = null,
        TimeProvider? timeProvider = null,
        Action<Exception>? errorSink = null)
    {
        ArgumentNullException.ThrowIfNull(roots);
        ArgumentException.ThrowIfNullOrWhiteSpace(queueDirectory);
        ArgumentNullException.ThrowIfNull(vaultKeyProvider);
        _roots = roots
            .GroupBy(static root => (root.Path, root.SourceKind))
            .Select(static group => group.First())
            .ToArray();
        _queueDirectory = Path.GetFullPath(queueDirectory.Trim());
        _vaultKeyProvider = vaultKeyProvider;
        _debounceInterval = debounceInterval ?? TimeSpan.FromSeconds(2);
        _backstopInterval = backstopInterval ?? TimeSpan.FromMinutes(15);
        _timeProvider = timeProvider ?? TimeProvider.System;
        _errorSink = errorSink;
        if (_debounceInterval < TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(debounceInterval));
        if (_backstopInterval <= TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(backstopInterval));
        if (_roots.Any(root => IsSameOrDescendant(_queueDirectory, root.Path)))
        {
            throw new ArgumentException(
                "The Pensieve queue must be outside every watched source root.",
                nameof(queueDirectory));
        }
    }

    public static string DefaultQueueDirectory()
    {
        string? configured = Environment.GetEnvironmentVariable(QueueOverrideEnvironmentVariable);
        return !string.IsNullOrWhiteSpace(configured)
            ? Path.GetFullPath(configured.Trim())
            : Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".openburnbar",
                "pensieve-queue");
    }

    public static IReadOnlyList<PensieveWatchRoot> StandardRoots(
        string? repoDocsPath = null,
        string? notesPath = null,
        string? claudeProjectsPath = null)
    {
        var roots = new List<PensieveWatchRoot>();
        if (!string.IsNullOrWhiteSpace(repoDocsPath))
        {
            roots.Add(new PensieveWatchRoot(repoDocsPath, PensieveSourceKind.RepoDocs, new[] { "md", "mdx", "txt", "rst" }));
        }
        if (!string.IsNullOrWhiteSpace(notesPath))
        {
            roots.Add(new PensieveWatchRoot(notesPath, PensieveSourceKind.Notes, new[] { "md", "txt" }));
        }
        string claude = string.IsNullOrWhiteSpace(claudeProjectsPath)
            ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "projects")
            : claudeProjectsPath;
        roots.Add(new PensieveWatchRoot(claude, PensieveSourceKind.ChatMemory, new[] { "jsonl" }));
        return roots;
    }

    public PensieveWatcherStatus Status
    {
        get
        {
            lock (_stateGate)
            {
                return new PensieveWatcherStatus(
                    _lifetime is { IsCancellationRequested: false },
                    _roots.Count,
                    _lastScanAt,
                    _lastEnqueueAt,
                    _lastEnqueuedCount,
                    _errorCode);
            }
        }
    }

    public void Start()
    {
        lock (_stateGate)
        {
            if (_lifetime is { IsCancellationRequested: false })
            {
                return;
            }

            _lifetime?.Dispose();
            _lifetime = new CancellationTokenSource();
            try
            {
                foreach (PensieveWatchRoot root in _roots)
                {
                    Directory.CreateDirectory(root.Path);
                    var watcher = new FileSystemWatcher(root.Path)
                    {
                        IncludeSubdirectories = true,
                        NotifyFilter = NotifyFilters.FileName
                            | NotifyFilters.DirectoryName
                            | NotifyFilters.LastWrite
                            | NotifyFilters.Size,
                    };
                    watcher.Changed += OnSourceChanged;
                    watcher.Created += OnSourceChanged;
                    watcher.Deleted += OnSourceChanged;
                    watcher.Renamed += OnSourceChanged;
                    watcher.Error += OnWatcherError;
                    _watchers.Add(watcher);
                    watcher.EnableRaisingEvents = true;
                }

                _backstopTask = RunBackstopAsync(_lifetime.Token);
                TrackBackgroundTask(_backstopTask);
            }
            catch
            {
                foreach (FileSystemWatcher watcher in _watchers)
                {
                    watcher.Dispose();
                }
                _watchers.Clear();
                _lifetime.Cancel();
                _lifetime.Dispose();
                _lifetime = null;
                throw;
            }
        }
        ScheduleScan();
    }

    public async Task<PensieveWatcherStatus> ScanNowAsync(CancellationToken cancellationToken = default)
    {
        await _scanGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await ScanCoreAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _scanGate.Release();
        }
        return Status;
    }

    public async ValueTask DisposeAsync()
    {
        CancellationTokenSource? lifetime;
        CancellationTokenSource? debounce;
        Task[] backgroundTasks;
        lock (_stateGate)
        {
            lifetime = _lifetime;
            debounce = _debounce;
            backgroundTasks = _backgroundTasks.ToArray();
            _lifetime = null;
            _debounce = null;
            _debounceTask = null;
            _backstopTask = null;
            foreach (FileSystemWatcher watcher in _watchers)
            {
                watcher.EnableRaisingEvents = false;
                watcher.Changed -= OnSourceChanged;
                watcher.Created -= OnSourceChanged;
                watcher.Deleted -= OnSourceChanged;
                watcher.Renamed -= OnSourceChanged;
                watcher.Error -= OnWatcherError;
                watcher.Dispose();
            }
            _watchers.Clear();
        }

        debounce?.Cancel();
        lifetime?.Cancel();
        await Task.WhenAll(backgroundTasks.Select(ObserveCancellationAsync)).ConfigureAwait(false);
        debounce?.Dispose();
        lifetime?.Dispose();
    }

    private void OnSourceChanged(object sender, FileSystemEventArgs args) => ScheduleScan();

    private void OnWatcherError(object sender, ErrorEventArgs args)
    {
        SetError(PensieveWatcherErrorCode.WatcherFailed, args.GetException());
        ScheduleScan();
    }

    private void ScheduleScan()
    {
        lock (_stateGate)
        {
            if (_lifetime is not { IsCancellationRequested: false } lifetime)
            {
                return;
            }
            _debounce?.Cancel();
            _debounce?.Dispose();
            _debounce = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
            _debounceTask = RunDebouncedScanAsync(_debounce.Token);
            TrackBackgroundTask(_debounceTask);
        }
    }

    private async Task RunDebouncedScanAsync(CancellationToken cancellationToken)
    {
        try
        {
            await Task.Delay(_debounceInterval, _timeProvider, cancellationToken).ConfigureAwait(false);
            await ScanNowAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            SetError(PensieveWatcherErrorCode.WatcherFailed, exception);
        }
    }

    private async Task RunBackstopAsync(CancellationToken cancellationToken)
    {
        try
        {
            using var timer = new PeriodicTimer(_backstopInterval, _timeProvider);
            while (await timer.WaitForNextTickAsync(cancellationToken).ConfigureAwait(false))
            {
                await ScanNowAsync(cancellationToken).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            SetError(PensieveWatcherErrorCode.WatcherFailed, exception);
        }
    }

    private async Task ScanCoreAsync(CancellationToken cancellationToken)
    {
        byte[]? vaultKey = null;
        try
        {
            byte[]? providedKey = _vaultKeyProvider();
            if (providedKey is not { Length: 32 })
            {
                SetStatus(0, PensieveWatcherErrorCode.VaultKeyUnavailable);
                return;
            }
            vaultKey = providedKey.ToArray();

            int enqueued = 0;
            PensieveWatcherErrorCode error = PensieveWatcherErrorCode.None;
            foreach (PensieveWatchRoot root in _roots)
            {
                cancellationToken.ThrowIfCancellationRequested();
                try
                {
                    enqueued += root.SourceKind == PensieveSourceKind.ChatMemory
                        ? await SignalSettledSessionsAsync(root, cancellationToken).ConfigureAwait(false)
                        : await PrepareDocumentsAsync(root, vaultKey, cancellationToken).ConfigureAwait(false);
                }
                catch (PensieveQueueWriteException exception)
                {
                    error = PensieveWatcherErrorCode.QueueWriteFailed;
                    _errorSink?.Invoke(exception.InnerException ?? exception);
                }
                catch (IOException exception)
                {
                    error = PensieveWatcherErrorCode.SourceReadFailed;
                    _errorSink?.Invoke(exception);
                }
                catch (UnauthorizedAccessException exception)
                {
                    error = PensieveWatcherErrorCode.SourceReadFailed;
                    _errorSink?.Invoke(exception);
                }
            }
            SetStatus(enqueued, error);
        }
        finally
        {
            if (vaultKey is not null)
            {
                CryptographicOperations.ZeroMemory(vaultKey);
            }
        }
    }

    private async Task<int> PrepareDocumentsAsync(
        PensieveWatchRoot root,
        byte[] vaultKey,
        CancellationToken cancellationToken)
    {
        int enqueued = 0;
        foreach (string filePath in EnumerateEligibleFiles(root))
        {
            cancellationToken.ThrowIfCancellationRequested();
            string? text = await ReadBoundedUtf8Async(filePath, cancellationToken).ConfigureAwait(false);
            if (text is null)
            {
                continue;
            }
            if (string.IsNullOrWhiteSpace(text))
            {
                continue;
            }

            string relativePath = Path.GetRelativePath(root.Path, filePath).Replace('\\', '/');
            string slug = PensieveKnowledgeChunker.Slugify(relativePath);
            PensieveKnowledgeBatch batch = PensieveKnowledgeChunker.PrepareBatch(
                text,
                root.SourceKind,
                relativePath,
                slug,
                vaultKey,
                title: Path.GetFileNameWithoutExtension(filePath));
            IReadOnlyList<PensieveKnowledgeVector> novel;
            lock (_stateGate)
            {
                novel = batch.Vectors.Where(vector => !_enqueuedVectorIds.Contains(vector.VectorId)).ToArray();
            }
            if (novel.Count == 0)
            {
                continue;
            }

            var novelBatch = batch with { Vectors = novel };
            foreach (PensieveKnowledgeBatch partition in PensieveKnowledgeChunker.SplitForCommit(novelBatch))
            {
                await WriteBatchAsync(partition, cancellationToken).ConfigureAwait(false);
                lock (_stateGate)
                {
                    if (_enqueuedVectorIds.Count + partition.Vectors.Count > EnqueuedVectorIdsCap)
                    {
                        _enqueuedVectorIds.Clear();
                    }
                    foreach (PensieveKnowledgeVector vector in partition.Vectors)
                    {
                        _enqueuedVectorIds.Add(vector.VectorId);
                    }
                }
                enqueued += partition.Vectors.Count;
            }
        }
        return enqueued;
    }

    private static async Task<string?> ReadBoundedUtf8Async(
        string filePath,
        CancellationToken cancellationToken)
    {
        await using var stream = new FileStream(
            filePath,
            FileMode.Open,
            FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete,
            16 * 1024,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
        long length = stream.Length;
        if (length is <= 0 or > MaximumSourceFileBytes)
        {
            return null;
        }

        var bytes = new byte[checked((int)length)];
        int read = 0;
        while (read < bytes.Length)
        {
            int count = await stream.ReadAsync(bytes.AsMemory(read), cancellationToken).ConfigureAwait(false);
            if (count == 0) break;
            read += count;
        }
        try
        {
            return new UTF8Encoding(false, true).GetString(bytes, 0, read);
        }
        catch (DecoderFallbackException)
        {
            return null;
        }
    }

    private async Task<int> SignalSettledSessionsAsync(
        PensieveWatchRoot root,
        CancellationToken cancellationToken)
    {
        string sentinelDirectory = Path.Combine(_queueDirectory, "session-end-signals");
        int signalled = 0;
        DateTimeOffset now = _timeProvider.GetUtcNow();
        foreach (string filePath in EnumerateEligibleFiles(root))
        {
            cancellationToken.ThrowIfCancellationRequested();
            DateTimeOffset modifiedAt = File.GetLastWriteTimeUtc(filePath);
            if (now - modifiedAt < _debounceInterval)
            {
                continue;
            }

            string modifiedWire = modifiedAt.ToString("O");
            string key = CloudVaultCrypto.Sha256Hex(filePath + "@" + modifiedWire);
            string sentinelPath = Path.Combine(sentinelDirectory, key + ".json");
            if (File.Exists(sentinelPath))
            {
                continue;
            }

            byte[] payload = JsonSerializer.SerializeToUtf8Bytes(new
            {
                sessionPath = filePath,
                modifiedAt = modifiedWire,
                sourceKind = PensieveSourceKind.ChatMemory.WireValue(),
                schemaVersion = 1,
            }, PensieveJson.CompactOptions);
            await WriteQueuePayloadAsync(sentinelPath, payload, cancellationToken).ConfigureAwait(false);
            signalled++;
        }
        return signalled;
    }

    private async Task WriteBatchAsync(PensieveKnowledgeBatch batch, CancellationToken cancellationToken)
    {
        string vectorIdsJson = JsonSerializer.Serialize(batch.Vectors.Select(static vector => vector.VectorId));
        string idsHash = CloudVaultCrypto.Sha256Hex(vectorIdsJson);
        string path = Path.Combine(_queueDirectory, $"{batch.SourceSlug}-{idsHash}.json");
        byte[] payload = JsonSerializer.SerializeToUtf8Bytes(batch, PensieveJson.QueueOptions);
        await WriteQueuePayloadAsync(path, payload, cancellationToken).ConfigureAwait(false);
    }

    private static async Task WriteQueuePayloadAsync(
        string path,
        byte[] payload,
        CancellationToken cancellationToken)
    {
        try
        {
            await AtomicWriteAsync(path, payload, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw new PensieveQueueWriteException(exception);
        }
    }

    private static async Task AtomicWriteAsync(string destination, byte[] payload, CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
        string temporary = destination + ".tmp-" + Guid.NewGuid().ToString("N");
        try
        {
            await using (var stream = new FileStream(
                temporary,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                16 * 1024,
                FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await stream.WriteAsync(payload, cancellationToken).ConfigureAwait(false);
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
                stream.Flush(flushToDisk: true);
            }
            if (!OperatingSystem.IsWindows())
            {
                File.SetUnixFileMode(temporary, UnixFileMode.UserRead | UnixFileMode.UserWrite);
            }
            File.Move(temporary, destination, overwrite: true);
        }
        finally
        {
            try { File.Delete(temporary); }
            catch (IOException) { }
        }
    }

    private IEnumerable<string> EnumerateEligibleFiles(PensieveWatchRoot root)
    {
        var pending = new Stack<DirectoryInfo>();
        pending.Push(new DirectoryInfo(root.Path));
        int yielded = 0;
        while (pending.Count > 0 && yielded < MaximumSourceFilesPerScan)
        {
            DirectoryInfo directory = pending.Pop();
            IEnumerable<FileSystemInfo> entries;
            try
            {
                entries = directory.EnumerateFileSystemInfos();
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                _errorSink?.Invoke(exception);
                continue;
            }

            foreach (FileSystemInfo entry in entries.OrderBy(static entry => entry.Name, StringComparer.OrdinalIgnoreCase))
            {
                if ((entry.Attributes & (FileAttributes.Hidden | FileAttributes.ReparsePoint)) != 0)
                {
                    continue;
                }
                if (entry is DirectoryInfo child)
                {
                    pending.Push(child);
                    continue;
                }
                if (entry is not FileInfo file)
                {
                    continue;
                }
                string extension = Path.GetExtension(file.Name).TrimStart('.');
                if (root.IncludedExtensions.Count > 0 && !root.IncludedExtensions.Contains(extension))
                {
                    continue;
                }
                yield return file.FullName;
                yielded++;
                if (yielded >= MaximumSourceFilesPerScan)
                {
                    yield break;
                }
            }
        }
    }

    private void SetStatus(int enqueued, PensieveWatcherErrorCode errorCode)
    {
        lock (_stateGate)
        {
            DateTimeOffset now = _timeProvider.GetUtcNow();
            _lastScanAt = now;
            _lastEnqueuedCount = enqueued;
            if (enqueued > 0) _lastEnqueueAt = now;
            _errorCode = errorCode;
        }
    }

    private void SetError(PensieveWatcherErrorCode errorCode, Exception exception)
    {
        lock (_stateGate)
        {
            _errorCode = errorCode;
        }
        _errorSink?.Invoke(exception);
    }

    private void TrackBackgroundTask(Task task)
    {
        _backgroundTasks.Add(task);
        _ = task.ContinueWith(
            completed =>
            {
                lock (_stateGate)
                {
                    _backgroundTasks.Remove(completed);
                }
            },
            CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
    }

    private static async Task ObserveCancellationAsync(Task task)
    {
        try { await task.ConfigureAwait(false); }
        catch (OperationCanceledException) { }
    }

    private static bool IsSameOrDescendant(string candidate, string root)
    {
        string relative = Path.GetRelativePath(root, candidate);
        return relative == "."
            || (!relative.StartsWith(".." + Path.DirectorySeparatorChar, StringComparison.Ordinal)
                && !string.Equals(relative, "..", StringComparison.Ordinal)
                && !Path.IsPathRooted(relative));
    }

    private sealed class PensieveQueueWriteException(Exception innerException)
        : IOException("The sealed Pensieve queue could not be updated.", innerException);
}

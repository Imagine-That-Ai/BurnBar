using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.Presentation.Quota;

public sealed record DomainCoreQuotaShadowSampleV1
{
    public const int CurrentSchemaVersion = 1;

    [JsonPropertyName("schemaVersion")]
    public int SchemaVersion { get; init; } = CurrentSchemaVersion;

    [JsonPropertyName("sampleId")]
    public required string SampleId { get; init; }

    [JsonPropertyName("domain")]
    public string Domain { get; init; } = "quota";

    [JsonPropertyName("consumer")]
    public string Consumer { get; init; } = "windows";

    [JsonPropertyName("channel")]
    public required string Channel { get; init; }

    [JsonPropertyName("operation")]
    public required string Operation { get; init; }

    [JsonPropertyName("coreVersion")]
    public required string CoreVersion { get; init; }

    [JsonPropertyName("observedAt")]
    public required string ObservedAt { get; init; }

    [JsonPropertyName("outcome")]
    public required string Outcome { get; init; }

    [JsonPropertyName("mismatchCategory")]
    public string? MismatchCategory { get; init; }

    [JsonPropertyName("legacyMicros")]
    public required long LegacyMicros { get; init; }

    [JsonPropertyName("rustMicros")]
    public required long RustMicros { get; init; }
}

public sealed class DomainCoreQuotaShadowEvidenceSpool
{
    public sealed record ReadyBatch(string Token, IReadOnlyList<DomainCoreQuotaShadowSampleV1> Samples);

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = null,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
    };

    private readonly object _gate = new();
    private readonly string _directory;
    private readonly string _activePath;
    private readonly int _maxFileBytes;
    private readonly int _maxReadyFiles;
    private readonly int _maxSamplesPerFile;
    private long _lastReadyOrdinal;

    public DomainCoreQuotaShadowEvidenceSpool(
        string directory,
        int maxFileBytes = 256 * 1024,
        int maxReadyFiles = 8,
        int maxSamplesPerFile = 100)
    {
        if (string.IsNullOrWhiteSpace(directory)) throw new ArgumentException("Spool directory is required.", nameof(directory));
        if (maxFileBytes <= 0) throw new ArgumentOutOfRangeException(nameof(maxFileBytes));
        if (maxReadyFiles <= 0) throw new ArgumentOutOfRangeException(nameof(maxReadyFiles));
        if (maxSamplesPerFile <= 0) throw new ArgumentOutOfRangeException(nameof(maxSamplesPerFile));
        _directory = Path.GetFullPath(directory);
        _activePath = Path.Combine(_directory, "active.jsonl");
        _maxFileBytes = maxFileBytes;
        _maxReadyFiles = maxReadyFiles;
        _maxSamplesPerFile = maxSamplesPerFile;
        Directory.CreateDirectory(_directory);
        _lastReadyOrdinal = ReadyFiles()
            .Select(path => Path.GetFileName(path).Split('-', 3)[1])
            .Select(value => long.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out long ordinal) ? ordinal : 0)
            .DefaultIfEmpty()
            .Max();
    }

    public void Append(DomainCoreQuotaShadowSampleV1 sample)
    {
        ArgumentNullException.ThrowIfNull(sample);
        byte[] line = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(sample, JsonOptions) + "\n");
        if (line.Length > _maxFileBytes) throw new InvalidDataException("Shadow sample exceeds the spool file bound.");

        lock (_gate)
        {
            if (ActiveSize() + line.Length > _maxFileBytes || ActiveSampleCount() >= _maxSamplesPerFile)
            {
                SealActive();
            }
            using var stream = new FileStream(
                _activePath,
                FileMode.Append,
                FileAccess.Write,
                FileShare.Read,
                bufferSize: 4096,
                FileOptions.WriteThrough);
            stream.Write(line);
            stream.Flush(flushToDisk: true);
        }
    }

    public ReadyBatch? NextBatch(bool sealActive = true)
    {
        lock (_gate)
        {
            if (sealActive) SealActive();
            string? path = ReadyFiles().FirstOrDefault();
            if (path is null) return null;
            var samples = File.ReadLines(path)
                .Where(line => line.Length > 0)
                .Select(line => JsonSerializer.Deserialize<DomainCoreQuotaShadowSampleV1>(line, JsonOptions)
                    ?? throw new InvalidDataException("Shadow spool contains a null sample."))
                .ToArray();
            if (samples.Length == 0 || samples.Length > _maxSamplesPerFile)
            {
                throw new InvalidDataException("Shadow spool batch violates its sample bound.");
            }
            return new ReadyBatch(Path.GetFileName(path), samples);
        }
    }

    public void Acknowledge(string token)
    {
        if (!token.StartsWith("ready-", StringComparison.Ordinal)
            || !token.EndsWith(".jsonl", StringComparison.Ordinal)
            || token.IndexOfAny(new[] { '/', '\\' }) >= 0)
        {
            throw new InvalidDataException("Invalid shadow spool acknowledgement token.");
        }
        lock (_gate)
        {
            string path = Path.Combine(_directory, token);
            if (File.Exists(path)) File.Delete(path);
        }
    }

    public int PendingSampleCount()
    {
        lock (_gate)
        {
            IEnumerable<string> files = ReadyFiles();
            if (File.Exists(_activePath)) files = files.Append(_activePath);
            return files.Sum(path => File.ReadLines(path).Count(line => line.Length > 0));
        }
    }

    private void SealActive()
    {
        if (ActiveSize() == 0) return;
        var ready = ReadyFiles().ToList();
        while (ready.Count >= _maxReadyFiles)
        {
            File.Delete(ready[0]);
            ready.RemoveAt(0);
        }
        _lastReadyOrdinal = Math.Max(DateTime.UtcNow.Ticks, _lastReadyOrdinal + 1);
        string ordinal = _lastReadyOrdinal.ToString("D19", CultureInfo.InvariantCulture);
        string token = $"ready-{ordinal}-{Guid.NewGuid():D}.jsonl";
        File.Move(_activePath, Path.Combine(_directory, token));
    }

    private IEnumerable<string> ReadyFiles() => Directory
        .EnumerateFiles(_directory, "ready-*.jsonl", SearchOption.TopDirectoryOnly)
        .OrderBy(path => Path.GetFileName(path), StringComparer.Ordinal);

    private long ActiveSize() => File.Exists(_activePath) ? new FileInfo(_activePath).Length : 0;

    private int ActiveSampleCount() => File.Exists(_activePath)
        ? File.ReadLines(_activePath).Count(line => line.Length > 0)
        : 0;
}

internal sealed class DomainCoreQuotaShadowUploadCoordinator
{
    private readonly object _scheduleGate = new();
    private readonly SemaphoreSlim _flushGate = new(1, 1);
    private readonly DomainCoreQuotaShadowEvidenceSpool _spool;
    private readonly Func<IReadOnlyList<DomainCoreQuotaShadowSampleV1>, CancellationToken, Task> _uploader;
    private readonly TimeSpan _debounce;
    private Task? _scheduledFlush;
    private long _scheduleVersion;

    internal DomainCoreQuotaShadowUploadCoordinator(
        DomainCoreQuotaShadowEvidenceSpool spool,
        Func<IReadOnlyList<DomainCoreQuotaShadowSampleV1>, CancellationToken, Task> uploader,
        TimeSpan? debounce = null)
    {
        _spool = spool ?? throw new ArgumentNullException(nameof(spool));
        _uploader = uploader ?? throw new ArgumentNullException(nameof(uploader));
        _debounce = debounce ?? TimeSpan.FromSeconds(5);
        if (_debounce < TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(debounce));
    }

    internal void Schedule()
    {
        lock (_scheduleGate)
        {
            _scheduleVersion++;
            if (_scheduledFlush is { IsCompleted: false }) return;
            _scheduledFlush = Task.Run(RunScheduledFlushAsync);
        }
    }

    private async Task RunScheduledFlushAsync()
    {
        while (true)
        {
            long observedVersion;
            lock (_scheduleGate) observedVersion = _scheduleVersion;

            await Task.Delay(_debounce).ConfigureAwait(false);

            lock (_scheduleGate)
            {
                if (observedVersion != _scheduleVersion) continue;
            }

            await FlushAsync(CancellationToken.None).ConfigureAwait(false);

            lock (_scheduleGate)
            {
                if (observedVersion != _scheduleVersion) continue;
                if (_spool.PendingSampleCount() > 0)
                {
                    _scheduleVersion++;
                    continue;
                }
                _scheduledFlush = null;
                return;
            }
        }
    }

    internal void FlushNow() => _ = Task.Run(async () =>
    {
        await FlushAsync(CancellationToken.None).ConfigureAwait(false);
        if (_spool.PendingSampleCount() > 0) Schedule();
    });

    internal async Task FlushAsync(CancellationToken cancellationToken)
    {
        if (!await _flushGate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return;
        try
        {
            bool sealActive = true;
            while (_spool.NextBatch(sealActive) is { } batch)
            {
                sealActive = false;
                await _uploader(batch.Samples, cancellationToken).ConfigureAwait(false);
                _spool.Acknowledge(batch.Token);
            }
        }
        catch
        {
            // Durable spool remains intact and is retried after the bounded delay.
        }
        finally
        {
            _flushGate.Release();
        }
    }
}

public static class DomainCoreQuotaShadowEvidence
{
    private static readonly Regex CoreVersionPattern = new(
        "^[0-9]+\\.[0-9]+\\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$",
        RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);
    private static readonly HashSet<string> Operations = new(StringComparer.Ordinal)
    {
        "claude_quota",
        "codex_quota",
        "cursor_quota",
        "anthropic_quota",
    };
    private static readonly HashSet<string> MismatchCategories = new(StringComparer.Ordinal)
    {
        "result_mismatch",
        "native_unavailable",
        "native_error",
        "invalid_result",
    };
    private static readonly Lazy<DomainCoreQuotaShadowEvidenceSpool> DefaultSpool = new(() => new(
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "OpenBurnBar",
            "DomainCoreShadow")));
    private static DomainCoreQuotaShadowUploadCoordinator? _coordinator;

    public static void ConfigureUploader(
        Func<IReadOnlyList<DomainCoreQuotaShadowSampleV1>, CancellationToken, Task> uploader)
    {
        _coordinator = new DomainCoreQuotaShadowUploadCoordinator(
            DefaultSpool.Value,
            uploader ?? throw new ArgumentNullException(nameof(uploader)));
        _coordinator.FlushNow();
    }

    internal static void RecordComparison(
        string operation,
        string coreVersion,
        bool equivalent,
        string? mismatchCategory,
        long legacyMicros,
        long rustMicros)
    {
        PersistComparison(operation, coreVersion, equivalent, mismatchCategory, legacyMicros, rustMicros);
    }

    private static void PersistComparison(
        string operation,
        string coreVersion,
        bool equivalent,
        string? mismatchCategory,
        long legacyMicros,
        long rustMicros)
    {
        string? channel = Environment.GetEnvironmentVariable("OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL")?.Trim().ToLowerInvariant();
        if (channel is not ("internal" or "beta")
            || !Operations.Contains(operation)
            || coreVersion.Length > 64
            || !CoreVersionPattern.IsMatch(coreVersion)
            || (equivalent && mismatchCategory is not null)
            || (!equivalent && (mismatchCategory is null || !MismatchCategories.Contains(mismatchCategory)))
            || legacyMicros is < 0 or > 600_000_000
            || rustMicros is < 0 or > 600_000_000)
        {
            return;
        }

        DefaultSpool.Value.Append(new DomainCoreQuotaShadowSampleV1
        {
            SampleId = Guid.NewGuid().ToString("D", CultureInfo.InvariantCulture).ToLowerInvariant(),
            Channel = channel,
            Operation = operation,
            CoreVersion = coreVersion,
            ObservedAt = DateTimeOffset.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture),
            Outcome = equivalent ? "match" : "mismatch",
            MismatchCategory = mismatchCategory,
            LegacyMicros = legacyMicros,
            RustMicros = rustMicros,
        });
        _coordinator?.Schedule();
    }
}

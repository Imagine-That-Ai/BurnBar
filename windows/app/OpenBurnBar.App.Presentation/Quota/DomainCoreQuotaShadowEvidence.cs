using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using OpenBurnBar.App.Configuration;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.Presentation.Quota;

public sealed record DomainCoreShadowLoadedIdentity(
    string CoreVersion,
    uint CoreAbiVersion,
    string CoreSourceSha256);

public sealed record DomainCoreShadowEvidenceIdentity(
    string Channel,
    string CandidateCommit,
    string ExpectedCoreVersion,
    uint ExpectedCoreAbiVersion,
    string ExpectedCoreSourceSha256)
{
    internal bool Matches(DomainCoreShadowSampleV3 sample) =>
        sample.Channel == Channel
        && sample.CandidateCommit == CandidateCommit
        && sample.ExpectedCoreVersion == ExpectedCoreVersion
        && sample.ExpectedCoreAbiVersion == ExpectedCoreAbiVersion
        && sample.ExpectedCoreSourceSha256 == ExpectedCoreSourceSha256;
}

public sealed record DomainCoreShadowSampleV3
{
    public const int CurrentSchemaVersion = 3;

    [JsonPropertyName("schemaVersion")]
    public int SchemaVersion { get; init; } = CurrentSchemaVersion;

    [JsonPropertyName("sampleId")]
    public required string SampleId { get; init; }

    [JsonPropertyName("domain")]
    public string Domain { get; init; } = "quota";

    [JsonPropertyName("slice")]
    public required string Slice { get; init; }

    [JsonPropertyName("consumer")]
    public string Consumer { get; init; } = "windows";

    [JsonPropertyName("channel")]
    public required string Channel { get; init; }

    [JsonPropertyName("operation")]
    public required string Operation { get; init; }

    [JsonPropertyName("candidateCommit")]
    public required string CandidateCommit { get; init; }

    [JsonPropertyName("expectedCoreVersion")]
    public required string ExpectedCoreVersion { get; init; }

    [JsonPropertyName("expectedCoreAbiVersion")]
    public required uint ExpectedCoreAbiVersion { get; init; }

    [JsonPropertyName("expectedCoreSourceSha256")]
    public required string ExpectedCoreSourceSha256 { get; init; }

    [JsonPropertyName("loadedCoreVersion")]
    public string? LoadedCoreVersion { get; init; }

    [JsonPropertyName("loadedCoreAbiVersion")]
    public uint? LoadedCoreAbiVersion { get; init; }

    [JsonPropertyName("loadedCoreSourceSha256")]
    public string? LoadedCoreSourceSha256 { get; init; }

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
    public sealed record ReadyBatch(string Token, IReadOnlyList<DomainCoreShadowSampleV3> Samples);

    private static readonly HashSet<string> SamplePropertyNames = new(StringComparer.Ordinal)
    {
        "schemaVersion", "sampleId", "domain", "slice", "consumer", "channel", "operation",
        "candidateCommit", "expectedCoreVersion", "expectedCoreAbiVersion", "expectedCoreSourceSha256",
        "loadedCoreVersion", "loadedCoreAbiVersion", "loadedCoreSourceSha256", "observedAt", "outcome",
        "mismatchCategory", "legacyMicros", "rustMicros",
    };

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = null,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
    };

    private readonly object _gate = new();
    private readonly DomainCoreShadowEvidenceIdentity _identity;
    private readonly string _rootDirectory;
    private readonly string _directory;
    private readonly string _activePath;
    private readonly int _maxFileBytes;
    private readonly int _maxReadyFiles;
    private readonly int _maxSamplesPerFile;
    private long _lastReadyOrdinal;

    public DomainCoreQuotaShadowEvidenceSpool(
        string directory,
        DomainCoreShadowEvidenceIdentity identity,
        int maxFileBytes = 256 * 1024,
        int maxReadyFiles = 8,
        int maxSamplesPerFile = 100)
    {
        if (string.IsNullOrWhiteSpace(directory)) throw new ArgumentException("Spool directory is required.", nameof(directory));
        _identity = identity ?? throw new ArgumentNullException(nameof(identity));
        if (maxFileBytes <= 0) throw new ArgumentOutOfRangeException(nameof(maxFileBytes));
        if (maxReadyFiles <= 0) throw new ArgumentOutOfRangeException(nameof(maxReadyFiles));
        if (maxSamplesPerFile <= 0) throw new ArgumentOutOfRangeException(nameof(maxSamplesPerFile));
        _rootDirectory = Path.GetFullPath(directory);
        Directory.CreateDirectory(_rootDirectory);
        _directory = Path.Combine(_rootDirectory, Namespace(identity));
        _activePath = Path.Combine(_directory, "active.jsonl");
        _maxFileBytes = maxFileBytes;
        _maxReadyFiles = maxReadyFiles;
        _maxSamplesPerFile = maxSamplesPerFile;
        Directory.CreateDirectory(_directory);
        DiscardStaleNamespaces();
        _lastReadyOrdinal = ReadyFiles()
            .Select(path => Path.GetFileName(path).Split('-', 3)[1])
            .Select(value => long.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out long ordinal) ? ordinal : 0)
            .DefaultIfEmpty()
            .Max();
    }

    public void Append(DomainCoreShadowSampleV3 sample)
    {
        ArgumentNullException.ThrowIfNull(sample);
        if (sample.SchemaVersion != DomainCoreShadowSampleV3.CurrentSchemaVersion || !_identity.Matches(sample))
        {
            throw new InvalidDataException("Shadow sample does not match the active signed candidate.");
        }
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

    public ReadyBatch? NextBatch(bool sealActive = true, DateTimeOffset? now = null)
    {
        lock (_gate)
        {
            if (sealActive) SealActive();
            while (ReadyFiles().FirstOrDefault() is { } path)
            {
                // Read failures may be transient. Do not classify or delete a file until all
                // of its bytes have been read successfully.
                string[] lines = File.ReadAllLines(path);
                var samples = new List<DomainCoreShadowSampleV3>();
                foreach (string line in lines.Where(line => line.Length > 0))
                {
                    try
                    {
                        using JsonDocument document = JsonDocument.Parse(line);
                        string[] properties = document.RootElement.ValueKind == JsonValueKind.Object
                            ? document.RootElement.EnumerateObject().Select(property => property.Name).ToArray()
                            : Array.Empty<string>();
                        if (properties.Length != SamplePropertyNames.Count
                            || properties.Distinct(StringComparer.Ordinal).Count() != SamplePropertyNames.Count
                            || properties.Any(property => !SamplePropertyNames.Contains(property)))
                        {
                            continue;
                        }
                        DomainCoreShadowSampleV3? sample = document.RootElement.Deserialize<DomainCoreShadowSampleV3>(JsonOptions);
                        if (sample is not null
                            && DomainCoreQuotaShadowEvidence.ValidStoredSample(_identity, sample, now ?? DateTimeOffset.UtcNow))
                        {
                            samples.Add(sample);
                        }
                    }
                    catch (JsonException)
                    {
                        // A successfully-read malformed record is not retryable and must not
                        // prevent later valid records in the same durable file from uploading.
                    }
                }
                if (samples.Count == 0 || lines.Count(line => line.Length > 0) > _maxSamplesPerFile)
                {
                    File.Delete(path);
                    continue;
                }
                return new ReadyBatch(Path.GetFileName(path), samples);
            }
            return null;
        }
    }

    public void DiscardAll()
    {
        lock (_gate)
        {
            foreach (string path in ReadyFiles()) File.Delete(path);
            if (File.Exists(_activePath)) File.Delete(_activePath);
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

    private static string Namespace(DomainCoreShadowEvidenceIdentity identity)
    {
        string material = string.Join("\n", new[]
        {
            identity.Channel,
            identity.CandidateCommit,
            identity.ExpectedCoreVersion,
            identity.ExpectedCoreAbiVersion.ToString(CultureInfo.InvariantCulture),
            identity.ExpectedCoreSourceSha256,
        });
        return $"v3-{Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(material))).ToLowerInvariant()}";
    }

    private void DiscardStaleNamespaces()
    {
        foreach (string path in Directory.EnumerateFiles(_rootDirectory, "ready-*.jsonl", SearchOption.TopDirectoryOnly))
        {
            File.Delete(path);
        }
        string legacyActive = Path.Combine(_rootDirectory, "active.jsonl");
        if (File.Exists(legacyActive)) File.Delete(legacyActive);
        foreach (string path in Directory.EnumerateDirectories(_rootDirectory, "v3-*", SearchOption.TopDirectoryOnly))
        {
            if (!string.Equals(path, _directory, StringComparison.OrdinalIgnoreCase)) Directory.Delete(path, recursive: true);
        }
    }
}

internal sealed class DomainCoreQuotaShadowUploadCoordinator
{
    private readonly object _scheduleGate = new();
    private readonly SemaphoreSlim _flushGate = new(1, 1);
    private readonly DomainCoreQuotaShadowEvidenceSpool _spool;
    private readonly Func<IReadOnlyList<DomainCoreShadowSampleV3>, CancellationToken, Task> _uploader;
    private readonly Func<TimeSpan, Task> _delay;
    private readonly TimeSpan _debounce;
    private Task? _scheduledFlush;
    private long _scheduleVersion;

    internal DomainCoreQuotaShadowUploadCoordinator(
        DomainCoreQuotaShadowEvidenceSpool spool,
        Func<IReadOnlyList<DomainCoreShadowSampleV3>, CancellationToken, Task> uploader,
        TimeSpan? debounce = null,
        Func<TimeSpan, Task>? delay = null)
    {
        _spool = spool ?? throw new ArgumentNullException(nameof(spool));
        _uploader = uploader ?? throw new ArgumentNullException(nameof(uploader));
        _delay = delay ?? (duration => Task.Delay(duration));
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

            await _delay(_debounce).ConfigureAwait(false);

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
    private static readonly TimeSpan MaximumSampleAge = TimeSpan.FromDays(31);
    private static readonly TimeSpan MaximumFutureSkew = TimeSpan.FromMinutes(5);
    private static readonly Regex SampleIdPattern = new(
        "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
        RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);
    private static readonly Regex CoreVersionPattern = new(
        "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)" +
        "(?:-(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)" +
        "(?:\\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?" +
        "(?:\\+[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?$",
        RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);
    private static readonly Dictionary<string, string> OperationSlices = new(StringComparer.Ordinal)
    {
        ["claude_quota"] = "claude",
        ["codex_quota"] = "codex",
        ["cursor_quota"] = "cursor",
        ["anthropic_quota"] = "anthropic",
        ["cloudvault_aad_v1"] = "foundation",
        ["cloudvault_aad_v2"] = "foundation",
        ["cloudvault_resolve_aad"] = "foundation",
        ["cloudvault_sha256"] = "foundation",
        ["cloudvault_key_id"] = "foundation",
        ["cloudvault_keyed_hash"] = "foundation",
        ["cloudvault_base64_encode"] = "foundation",
        ["cloudvault_base64_decode"] = "foundation",
        ["cloudvault_validate_p256_public_key"] = "foundation",
        ["cloudvault_aes_seal_detached"] = "aes",
        ["cloudvault_aes_seal_combined"] = "aes",
        ["cloudvault_aes_open_detached"] = "aes",
        ["cloudvault_aes_open_text"] = "aes",
        ["cloudvault_aes_open_combined"] = "aes",
        ["cloudvault_recovery_wrapping_key"] = "recovery",
        ["cloudvault_recovery_verification_hash"] = "recovery",
        ["cloudvault_recovery_wrap_vault_key"] = "recovery",
        ["cloudvault_recovery_open_vault_key"] = "recovery",
        ["cloudvault_escrow_seal"] = "escrow",
        ["cloudvault_escrow_open"] = "escrow",
        ["cloudvault_escrow_split_wire"] = "escrow",
        ["pensieve_deterministic_embed_and_cloak"] = "pensieve-vectors",
        ["pensieve_deterministic_embed"] = "pensieve-vectors",
        ["pensieve_vector_cloak"] = "pensieve-vectors",
        ["pensieve_l2_normalize"] = "pensieve-vectors",
    };
    private static readonly HashSet<string> MismatchCategories = new(StringComparer.Ordinal)
    {
        "result_mismatch",
        "native_unavailable",
        "native_error",
        "invalid_result",
        "loaded_identity_mismatch",
    };
    private static readonly Regex Sha256Pattern = new(
        "^[0-9a-f]{64}$",
        RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);
    private static readonly string DefaultSpoolRoot = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "OpenBurnBar",
        "DomainCoreShadow");
    private static DomainCoreQuotaShadowEvidenceSpool? _spool;
    private static DomainCoreQuotaShadowUploadCoordinator? _coordinator;

    public static void ConfigureUploader(
        Func<IReadOnlyList<DomainCoreShadowSampleV3>, CancellationToken, Task> uploader)
    {
        ArgumentNullException.ThrowIfNull(uploader);
        if (!TryEvidenceIdentity(out DomainCoreShadowEvidenceIdentity? identity))
        {
            try
            {
                if (Directory.Exists(DefaultSpoolRoot)) Directory.Delete(DefaultSpoolRoot, recursive: true);
            }
            catch (Exception error)
            {
                Trace.TraceWarning("domain_core.shadow_evidence.cleanup_failed error={0}", error.GetType().Name);
            }
            _spool = null;
            _coordinator = null;
            return;
        }
        _spool = CreateSpoolBestEffort(DefaultSpoolRoot, identity!);
        if (_spool is null)
        {
            _coordinator = null;
            return;
        }
        _coordinator = new DomainCoreQuotaShadowUploadCoordinator(
            _spool,
            uploader);
        _coordinator.FlushNow();
    }

    internal static DomainCoreQuotaShadowEvidenceSpool? CreateSpoolBestEffort(
        string directory,
        DomainCoreShadowEvidenceIdentity identity)
    {
        try
        {
            return new DomainCoreQuotaShadowEvidenceSpool(directory, identity);
        }
        catch (Exception error)
        {
            Trace.TraceWarning("domain_core.shadow_evidence.initialize_failed error={0}", error.GetType().Name);
            return null;
        }
    }

    internal static void RecordComparison(
        string operation,
        DomainCoreShadowLoadedIdentity? loadedIdentity,
        bool equivalent,
        string? mismatchCategory,
        long legacyMicros,
        long rustMicros)
    {
        string? slice = SliceForOperation(operation);
        if (slice is null) return;
        PersistComparison(
            "quota",
            slice,
            operation,
            loadedIdentity,
            equivalent,
            mismatchCategory,
            legacyMicros,
            rustMicros);
    }

    public static void RecordComparison(
        string domain,
        string slice,
        string operation,
        string? loadedCoreVersion,
        uint? loadedCoreAbiVersion,
        string? loadedCoreSourceSha256,
        bool equivalent,
        string? mismatchCategory,
        long legacyMicros,
        long rustMicros)
    {
        DomainCoreShadowLoadedIdentity? loadedIdentity = loadedCoreVersion is not null
            && loadedCoreAbiVersion is uint abiVersion
            && loadedCoreSourceSha256 is not null
                ? new(loadedCoreVersion, abiVersion, loadedCoreSourceSha256)
                : null;
        PersistComparison(domain, slice, operation, loadedIdentity, equivalent, mismatchCategory, legacyMicros, rustMicros);
    }

    private static void PersistComparison(
        string domain,
        string slice,
        string operation,
        DomainCoreShadowLoadedIdentity? loadedIdentity,
        bool equivalent,
        string? mismatchCategory,
        long legacyMicros,
        long rustMicros)
    {
        if (!TryEvidenceIdentity(out DomainCoreShadowEvidenceIdentity? identity)
            || _spool is null
            || !OperationSlices.TryGetValue(operation, out string? expectedSlice)
            || expectedSlice != slice
            || (domain == "quota" && !operation.EndsWith("_quota", StringComparison.Ordinal))
            || (domain == "cloudvault" && !operation.StartsWith("cloudvault_", StringComparison.Ordinal) && !operation.StartsWith("pensieve_", StringComparison.Ordinal))
            || (equivalent && mismatchCategory is not null)
            || (!equivalent && (mismatchCategory is null || !MismatchCategories.Contains(mismatchCategory)))
            || !ValidLoadedIdentity(identity!, loadedIdentity, equivalent, mismatchCategory)
            || legacyMicros is < 0 or > 600_000_000
            || rustMicros is < 0 or > 600_000_000)
        {
            return;
        }

        var sample = new DomainCoreShadowSampleV3
        {
            Domain = domain,
            SampleId = Guid.NewGuid().ToString("D", CultureInfo.InvariantCulture).ToLowerInvariant(),
            Channel = identity!.Channel,
            Slice = slice,
            Operation = operation,
            CandidateCommit = identity.CandidateCommit,
            ExpectedCoreVersion = identity.ExpectedCoreVersion,
            ExpectedCoreAbiVersion = identity.ExpectedCoreAbiVersion,
            ExpectedCoreSourceSha256 = identity.ExpectedCoreSourceSha256,
            LoadedCoreVersion = loadedIdentity?.CoreVersion,
            LoadedCoreAbiVersion = loadedIdentity?.CoreAbiVersion,
            LoadedCoreSourceSha256 = loadedIdentity?.CoreSourceSha256,
            ObservedAt = DateTimeOffset.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture),
            Outcome = equivalent ? "match" : "mismatch",
            MismatchCategory = mismatchCategory,
            LegacyMicros = legacyMicros,
            RustMicros = rustMicros,
        };
        _ = PersistBestEffort(
            _spool,
            sample,
            _coordinator is null ? null : _coordinator.Schedule);
    }

    internal static bool PersistBestEffort(
        DomainCoreQuotaShadowEvidenceSpool spool,
        DomainCoreShadowSampleV3 sample,
        Action? schedule)
    {
        try
        {
            spool.Append(sample);
            schedule?.Invoke();
            return true;
        }
        catch (Exception error)
        {
            Trace.TraceWarning("domain_core.shadow_evidence.persist_failed error={0}", error.GetType().Name);
            return false;
        }
    }

    public static bool ValidAcknowledgementCounts(int accepted, int duplicates, int batchSize) =>
        batchSize >= 0
        && accepted >= 0
        && duplicates >= 0
        && accepted <= batchSize
        && duplicates <= batchSize
        && accepted + (long)duplicates == batchSize;

    internal static DomainCoreCandidateIdentity? CurrentSignedCandidateIdentity()
    {
        var profile = DomainCoreBuildProfileResolver.Current();
        return profile.IsValid
            && profile.ArtifactAuthority == "signed"
            && profile.EvidenceEnabled
            && profile.RolloutChannel is "internal" or "beta"
            ? profile.CandidateIdentity
            : null;
    }

    internal static string? SliceForOperation(string operation) =>
        OperationSlices.GetValueOrDefault(operation);

    private static bool TryEvidenceIdentity(out DomainCoreShadowEvidenceIdentity? identity)
    {
        identity = null;
        var profile = DomainCoreBuildProfileResolver.Current();
        if (!profile.IsValid
            || profile.ArtifactAuthority != "signed"
            || !profile.EvidenceEnabled
            || profile.RolloutChannel is not ("internal" or "beta")
            || profile.CandidateIdentity is not { } candidate)
        {
            return false;
        }
        identity = new(
            profile.RolloutChannel,
            candidate.CandidateCommit,
            candidate.ExpectedCoreVersion,
            candidate.ExpectedCoreAbiVersion,
            candidate.ExpectedCoreSourceSha256);
        return true;
    }

    internal static bool ValidLoadedIdentity(
        DomainCoreShadowEvidenceIdentity expected,
        DomainCoreShadowLoadedIdentity? loaded,
        bool equivalent,
        string? mismatchCategory)
    {
        bool loadedValid = loaded is null
            || (loaded.CoreVersion.Length <= 64
                && CoreVersionPattern.IsMatch(loaded.CoreVersion)
                && loaded.CoreAbiVersion >= 1
                && Sha256Pattern.IsMatch(loaded.CoreSourceSha256));
        if (!loadedValid) return false;
        bool matches = loaded is not null
            && loaded.CoreVersion == expected.ExpectedCoreVersion
            && loaded.CoreAbiVersion == expected.ExpectedCoreAbiVersion
            && loaded.CoreSourceSha256 == expected.ExpectedCoreSourceSha256;
        if (equivalent || mismatchCategory is "result_mismatch" or "invalid_result") return matches;
        if (mismatchCategory == "native_unavailable") return loaded is null;
        if (mismatchCategory == "native_error") return matches;
        return mismatchCategory == "loaded_identity_mismatch" && loaded is not null && !matches;
    }

    internal static bool ValidStoredSample(
        DomainCoreShadowEvidenceIdentity expected,
        DomainCoreShadowSampleV3 sample,
        DateTimeOffset now)
    {
        if (sample.SchemaVersion != DomainCoreShadowSampleV3.CurrentSchemaVersion
            || sample.Consumer != "windows"
            || !expected.Matches(sample)
            || string.IsNullOrEmpty(sample.SampleId)
            || !SampleIdPattern.IsMatch(sample.SampleId)
            || string.IsNullOrEmpty(sample.Operation)
            || !OperationSlices.TryGetValue(sample.Operation, out string? expectedSlice)
            || sample.Slice != expectedSlice
            || (sample.Domain == "quota" && !sample.Operation.EndsWith("_quota", StringComparison.Ordinal))
            || sample.Domain is not ("quota" or "cloudvault")
            || (sample.Domain == "cloudvault" && !sample.Operation.StartsWith("cloudvault_", StringComparison.Ordinal) && !sample.Operation.StartsWith("pensieve_", StringComparison.Ordinal))
            || sample.LegacyMicros is < 0 or > 600_000_000
            || sample.RustMicros is < 0 or > 600_000_000
            || string.IsNullOrEmpty(sample.ObservedAt)
            || !TryParseObservedAt(sample.ObservedAt, out DateTimeOffset observedAt)
            || observedAt < now - MaximumSampleAge
            || observedAt > now + MaximumFutureSkew)
        {
            return false;
        }

        bool equivalent = sample.Outcome == "match";
        if ((!equivalent && sample.Outcome != "mismatch")
            || (equivalent && sample.MismatchCategory is not null)
            || (!equivalent && (sample.MismatchCategory is null || !MismatchCategories.Contains(sample.MismatchCategory))))
        {
            return false;
        }

        bool loadedIsNull = sample.LoadedCoreVersion is null
            && sample.LoadedCoreAbiVersion is null
            && sample.LoadedCoreSourceSha256 is null;
        bool loadedIsPresent = sample.LoadedCoreVersion is not null
            && sample.LoadedCoreAbiVersion is not null
            && sample.LoadedCoreSourceSha256 is not null;
        if (!loadedIsNull && !loadedIsPresent) return false;
        DomainCoreShadowLoadedIdentity? loaded = loadedIsPresent
            ? new(sample.LoadedCoreVersion!, sample.LoadedCoreAbiVersion!.Value, sample.LoadedCoreSourceSha256!)
            : null;
        return ValidLoadedIdentity(expected, loaded, equivalent, sample.MismatchCategory);
    }

    private static bool TryParseObservedAt(string value, out DateTimeOffset observedAt) =>
        DateTimeOffset.TryParseExact(
            value,
            new[] { "yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mm:ss.fff'Z'" },
            CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
            out observedAt);
}

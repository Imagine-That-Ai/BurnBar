using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.Quota;
using Xunit;

namespace OpenBurnBar.App.Quota.Tests;

public sealed class DomainCoreQuotaShadowEvidenceTests : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"openburnbar-shadow-{Guid.NewGuid():D}");

    [Fact]
    public void Serialization_UsesExactPrivacySafeSchemaIncludingNullCategory()
    {
        string json = JsonSerializer.Serialize(Sample(1));
        using JsonDocument document = JsonDocument.Parse(json);
        string[] keys = document.RootElement.EnumerateObject().Select(property => property.Name).Order().ToArray();

        Assert.Equal(new[]
        {
            "candidateCommit", "channel", "consumer", "domain", "expectedCoreAbiVersion",
            "expectedCoreSourceSha256", "expectedCoreVersion", "legacyMicros", "loadedCoreAbiVersion",
            "loadedCoreSourceSha256", "loadedCoreVersion", "mismatchCategory", "observedAt", "operation",
            "outcome", "rustMicros", "sampleId", "schemaVersion", "slice",
        }, keys);
        Assert.Equal(JsonValueKind.Null, document.RootElement.GetProperty("mismatchCategory").ValueKind);
        Assert.DoesNotContain("uid", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("payload", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("deviceId", json, StringComparison.OrdinalIgnoreCase);
    }

    [Theory]
    [InlineData("claude_quota", "claude")]
    [InlineData("codex_quota", "codex")]
    [InlineData("cursor_quota", "cursor")]
    [InlineData("anthropic_quota", "anthropic")]
    [InlineData("cloudvault_aad_v1", "foundation")]
    [InlineData("cloudvault_aad_v2", "foundation")]
    [InlineData("cloudvault_resolve_aad", "foundation")]
    [InlineData("cloudvault_sha256", "foundation")]
    [InlineData("cloudvault_key_id", "foundation")]
    [InlineData("cloudvault_keyed_hash", "foundation")]
    [InlineData("cloudvault_base64_encode", "foundation")]
    [InlineData("cloudvault_base64_decode", "foundation")]
    [InlineData("cloudvault_validate_p256_public_key", "foundation")]
    [InlineData("cloudvault_aes_seal_detached", "aes")]
    [InlineData("cloudvault_aes_seal_combined", "aes")]
    [InlineData("cloudvault_aes_open_detached", "aes")]
    [InlineData("cloudvault_aes_open_text", "aes")]
    [InlineData("cloudvault_aes_open_combined", "aes")]
    [InlineData("cloudvault_recovery_wrapping_key", "recovery")]
    [InlineData("cloudvault_recovery_verification_hash", "recovery")]
    [InlineData("cloudvault_recovery_wrap_vault_key", "recovery")]
    [InlineData("cloudvault_recovery_open_vault_key", "recovery")]
    [InlineData("cloudvault_escrow_seal", "escrow")]
    [InlineData("cloudvault_escrow_open", "escrow")]
    [InlineData("cloudvault_escrow_split_wire", "escrow")]
    public void OperationCoverage_UsesServerApprovedSlice(string operation, string slice)
    {
        Assert.Equal(slice, DomainCoreQuotaShadowEvidence.SliceForOperation(operation));
    }

    [Fact]
    public void LoadedIdentityValidation_EnforcesV3OutcomeRules()
    {
        DomainCoreShadowEvidenceIdentity expected = Identity();
        var matching = new DomainCoreShadowLoadedIdentity("0.3.0", 3, new string('c', 64));
        var different = matching with { CoreSourceSha256 = new string('d', 64) };

        Assert.True(DomainCoreQuotaShadowEvidence.ValidLoadedIdentity(expected, matching, true, null));
        Assert.True(DomainCoreQuotaShadowEvidence.ValidLoadedIdentity(expected, matching, false, "result_mismatch"));
        Assert.True(DomainCoreQuotaShadowEvidence.ValidLoadedIdentity(expected, matching, false, "invalid_result"));
        Assert.True(DomainCoreQuotaShadowEvidence.ValidLoadedIdentity(expected, matching, false, "native_error"));
        Assert.True(DomainCoreQuotaShadowEvidence.ValidLoadedIdentity(expected, null, false, "native_unavailable"));
        Assert.True(DomainCoreQuotaShadowEvidence.ValidLoadedIdentity(expected, different, false, "loaded_identity_mismatch"));

        Assert.False(DomainCoreQuotaShadowEvidence.ValidLoadedIdentity(expected, null, true, null));
        Assert.False(DomainCoreQuotaShadowEvidence.ValidLoadedIdentity(expected, null, false, "native_error"));
        Assert.False(DomainCoreQuotaShadowEvidence.ValidLoadedIdentity(expected, matching, false, "native_unavailable"));
        Assert.False(DomainCoreQuotaShadowEvidence.ValidLoadedIdentity(expected, different, false, "native_error"));
        Assert.False(DomainCoreQuotaShadowEvidence.ValidLoadedIdentity(expected, matching, false, "loaded_identity_mismatch"));
        Assert.False(DomainCoreQuotaShadowEvidence.ValidLoadedIdentity(
            expected,
            matching with { CoreVersion = "00.3.0" },
            false,
            "loaded_identity_mismatch"));
    }

    [Theory]
    [InlineData(1, 0, 1, true)]
    [InlineData(0, 1, 1, true)]
    [InlineData(-1, 2, 1, false)]
    [InlineData(2, -1, 1, false)]
    [InlineData(2, 0, 1, false)]
    [InlineData(int.MaxValue, 1, int.MaxValue, false)]
    public void AcknowledgementValidation_FailsClosed(
        int accepted,
        int duplicates,
        int batchSize,
        bool expected)
    {
        Assert.Equal(
            expected,
            DomainCoreQuotaShadowEvidence.ValidAcknowledgementCounts(accepted, duplicates, batchSize));
    }

    [Fact]
    public void SpoolInitializationFailure_DisablesEvidenceWithoutEscaping()
    {
        Directory.CreateDirectory(_directory);
        string fileInsteadOfDirectory = Path.Combine(_directory, "not-a-directory");
        File.WriteAllText(fileInsteadOfDirectory, "occupied");

        DomainCoreQuotaShadowEvidenceSpool? spool = DomainCoreQuotaShadowEvidence.CreateSpoolBestEffort(
            fileInsteadOfDirectory,
            Identity());

        Assert.Null(spool);
    }

    [Fact]
    public void PersistFailure_DoesNotEscapeOrDiscardExistingEvidence()
    {
        var spool = new DomainCoreQuotaShadowEvidenceSpool(_directory, Identity());
        spool.Append(Sample(1));
        string activePath = Assert.Single(Directory.EnumerateFiles(_directory, "active.jsonl", SearchOption.AllDirectories));

        bool persisted;
        using (var locked = new FileStream(activePath, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            persisted = DomainCoreQuotaShadowEvidence.PersistBestEffort(spool, Sample(2), schedule: null);
        }

        Assert.False(persisted);
        Assert.Equal(1, spool.PendingSampleCount());
    }

    [Fact]
    public void SchedulingFailure_DoesNotEscapeAndKeepsPersistedEvidence()
    {
        var spool = new DomainCoreQuotaShadowEvidenceSpool(_directory, Identity());

        bool persisted = DomainCoreQuotaShadowEvidence.PersistBestEffort(
            spool,
            Sample(1),
            () => throw new IOException("scheduler unavailable"));

        Assert.False(persisted);
        Assert.Equal(1, spool.PendingSampleCount());
    }

    [Fact]
    public void Rotation_BoundsReadyFilesAndDropsOldestWholeBatch()
    {
        var spool = new DomainCoreQuotaShadowEvidenceSpool(
            _directory,
            Identity(),
            maxFileBytes: 4096,
            maxReadyFiles: 2,
            maxSamplesPerFile: 1);

        spool.Append(Sample(1));
        spool.Append(Sample(2));
        spool.Append(Sample(3));
        DomainCoreQuotaShadowEvidenceSpool.ReadyBatch batch = Assert.IsType<DomainCoreQuotaShadowEvidenceSpool.ReadyBatch>(spool.NextBatch());

        Assert.Equal(2, spool.PendingSampleCount());
        Assert.Equal(2, Directory.EnumerateFiles(_directory, "ready-*.jsonl", SearchOption.AllDirectories).Count());
        Assert.Equal("00000000-0000-4000-8000-000000000002", batch.Samples.Single().SampleId);
    }

    [Fact]
    public void FailedUploadCanRetrySameBatchUntilAcknowledged()
    {
        var spool = new DomainCoreQuotaShadowEvidenceSpool(_directory, Identity());
        spool.Append(Sample(1));

        DomainCoreQuotaShadowEvidenceSpool.ReadyBatch first = Assert.IsType<DomainCoreQuotaShadowEvidenceSpool.ReadyBatch>(spool.NextBatch());
        DomainCoreQuotaShadowEvidenceSpool.ReadyBatch retry = Assert.IsType<DomainCoreQuotaShadowEvidenceSpool.ReadyBatch>(spool.NextBatch());
        Assert.Equal(first.Token, retry.Token);
        Assert.Equal(1, spool.PendingSampleCount());

        spool.Acknowledge(retry.Token);
        Assert.Equal(0, spool.PendingSampleCount());
        Assert.Null(spool.NextBatch());
    }

    [Fact]
    public void ExpiredHeadIsDroppedWithoutBlockingFreshEvidence()
    {
        var now = new DateTimeOffset(2026, 7, 14, 12, 0, 0, TimeSpan.Zero);
        var spool = new DomainCoreQuotaShadowEvidenceSpool(
            _directory,
            Identity(),
            maxSamplesPerFile: 1);
        spool.Append(Sample(1, now.AddDays(-32)));
        spool.Append(Sample(2, now));

        DomainCoreQuotaShadowEvidenceSpool.ReadyBatch batch = Assert.IsType<DomainCoreQuotaShadowEvidenceSpool.ReadyBatch>(
            spool.NextBatch(now: now));

        Assert.Equal("00000000-0000-4000-8000-000000000002", Assert.Single(batch.Samples).SampleId);
        spool.Acknowledge(batch.Token);
        Assert.Null(spool.NextBatch(now: now));
    }

    [Fact]
    public void InvalidStoredRecordIsDiscardedWithoutBlockingValidRecordInSameFile()
    {
        var now = new DateTimeOffset(2026, 7, 14, 12, 0, 0, TimeSpan.Zero);
        var spool = new DomainCoreQuotaShadowEvidenceSpool(_directory, Identity());
        spool.Append(Sample(1, now));
        _ = Assert.IsType<DomainCoreQuotaShadowEvidenceSpool.ReadyBatch>(spool.NextBatch(now: now));
        string readyPath = Assert.Single(Directory.EnumerateFiles(_directory, "ready-*.jsonl", SearchOption.AllDirectories));
        string valid = JsonSerializer.Serialize(Sample(2, now));
        File.WriteAllText(
            readyPath,
            "{\"schemaVersion\":3,\"candidateCommit\":\"" + new string('a', 40) + "\"}\n" + valid + "\n");

        DomainCoreQuotaShadowEvidenceSpool.ReadyBatch batch = Assert.IsType<DomainCoreQuotaShadowEvidenceSpool.ReadyBatch>(
            spool.NextBatch(sealActive: false, now: now));

        Assert.Equal("00000000-0000-4000-8000-000000000002", Assert.Single(batch.Samples).SampleId);
    }

    [Fact]
    public void TransientReadFailureKeepsUnacknowledgedFileForRetry()
    {
        var now = new DateTimeOffset(2026, 7, 14, 12, 0, 0, TimeSpan.Zero);
        var spool = new DomainCoreQuotaShadowEvidenceSpool(_directory, Identity());
        spool.Append(Sample(1, now));
        _ = Assert.IsType<DomainCoreQuotaShadowEvidenceSpool.ReadyBatch>(spool.NextBatch(now: now));
        string readyPath = Assert.Single(Directory.EnumerateFiles(_directory, "ready-*.jsonl", SearchOption.AllDirectories));

        using (var locked = new FileStream(readyPath, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            Assert.Throws<IOException>(() => spool.NextBatch(sealActive: false, now: now));
            Assert.True(File.Exists(readyPath));
        }

        Assert.NotNull(spool.NextBatch(sealActive: false, now: now));
    }

    [Fact]
    public async Task RapidSamplesCoalesceIntoOneBoundedDelayedUpload()
    {
        var spool = new DomainCoreQuotaShadowEvidenceSpool(_directory, Identity());
        var batchSizes = new List<int>();
        var delays = new Queue<TaskCompletionSource>();
        var delayStarted = new SemaphoreSlim(0);
        Task ControlledDelay(TimeSpan _)
        {
            var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            lock (delays) delays.Enqueue(completion);
            delayStarted.Release();
            return completion.Task;
        }
        async Task ReleaseNextDelay()
        {
            await delayStarted.WaitAsync(TimeSpan.FromSeconds(5), CancellationToken.None);
            TaskCompletionSource completion;
            lock (delays) completion = delays.Dequeue();
            completion.SetResult();
        }
        var uploaded = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var coordinator = new DomainCoreQuotaShadowUploadCoordinator(
            spool,
            (samples, _) =>
            {
                lock (batchSizes) batchSizes.Add(samples.Count);
                uploaded.SetResult();
                return Task.CompletedTask;
            },
            TimeSpan.FromSeconds(5),
            ControlledDelay);

        spool.Append(Sample(1));
        coordinator.Schedule();
        await delayStarted.WaitAsync(TimeSpan.FromSeconds(5), CancellationToken.None);
        spool.Append(Sample(2));
        coordinator.Schedule();
        TaskCompletionSource first;
        lock (delays) first = delays.Dequeue();
        first.SetResult();
        await delayStarted.WaitAsync(TimeSpan.FromSeconds(5), CancellationToken.None);
        spool.Append(Sample(3));
        coordinator.Schedule();
        TaskCompletionSource second;
        lock (delays) second = delays.Dequeue();
        second.SetResult();
        await ReleaseNextDelay();
        await uploaded.Task.WaitAsync(TimeSpan.FromSeconds(5));

        lock (batchSizes) Assert.Equal(new[] { 3 }, batchSizes);
        Assert.Equal(0, spool.PendingSampleCount());
    }

    [Fact]
    public void CandidateTransitionDropsPriorCandidateNamespace()
    {
        var first = new DomainCoreQuotaShadowEvidenceSpool(_directory, Identity(), maxSamplesPerFile: 1);
        first.Append(Sample(1));
        Assert.Equal(1, first.PendingSampleCount());

        var secondIdentity = Identity() with
        {
            CandidateCommit = new string('b', 40),
            ExpectedCoreSourceSha256 = new string('d', 64),
        };
        var second = new DomainCoreQuotaShadowEvidenceSpool(_directory, secondIdentity, maxSamplesPerFile: 1);

        Assert.Equal(0, second.PendingSampleCount());
        string candidateDirectory = Assert.Single(Directory.EnumerateDirectories(_directory, "v3-*"));
        Assert.Matches("^v3-[0-9a-f]{64}$", Path.GetFileName(candidateDirectory));
    }

    [Fact]
    public void ConstructorDropsLegacyV1AndV2RootFilesWithoutRelabelingThem()
    {
        Directory.CreateDirectory(_directory);
        File.WriteAllText(Path.Combine(_directory, "active.jsonl"), "{\"schemaVersion\":1}\n");
        File.WriteAllText(Path.Combine(_directory, "ready-0000000000000000001-old.jsonl"), "{\"schemaVersion\":2}\n");

        var spool = new DomainCoreQuotaShadowEvidenceSpool(_directory, Identity());

        Assert.Equal(0, spool.PendingSampleCount());
        Assert.False(File.Exists(Path.Combine(_directory, "active.jsonl")));
        Assert.Empty(Directory.EnumerateFiles(_directory, "ready-*.jsonl"));
    }

    [Fact]
    public void DisabledProfileCleanupDiscardsDurableEvidence()
    {
        var spool = new DomainCoreQuotaShadowEvidenceSpool(_directory, Identity());
        spool.Append(Sample(1));

        spool.DiscardAll();

        Assert.Equal(0, spool.PendingSampleCount());
    }

    // The pensieve-vectors slice must admit all four canonical pensieve operation IDs,
    // including pensieve_l2_normalize. The pre-fix bug: the Windows OperationSlices map
    // omitted pensieve_l2_normalize, so Apple's canonical l2-normalize comparison records
    // (and any Windows-side normalization shadow record) were silently dropped.
    [Theory]
    [InlineData("pensieve_l2_normalize", "pensieve-vectors")]
    [InlineData("pensieve_vector_cloak", "pensieve-vectors")]
    [InlineData("pensieve_deterministic_embed", "pensieve-vectors")]
    [InlineData("pensieve_deterministic_embed_and_cloak", "pensieve-vectors")]
    public void PensieveVectorsAdmitsAllCanonicalOperationIds(string operation, string slice)
    {
        Assert.Equal(slice, DomainCoreQuotaShadowEvidence.SliceForOperation(operation));
    }

    // The legacy short aliases (cloak, l2_normalize, embed, embed_and_cloak) are not
    // canonical and must never resolve to a slice — Windows has no compat shim. A null
    // slice means the shadow record is dropped before persistence, the correct behavior.
    [Theory]
    [InlineData("cloak")]
    [InlineData("l2_normalize")]
    [InlineData("embed")]
    [InlineData("embed_and_cloak")]
    public void ShortAliasOperationsAreNotAdmittedToAnySlice(string operation)
    {
        Assert.Null(DomainCoreQuotaShadowEvidence.SliceForOperation(operation));
    }

    // A stored V3 sample carrying pensieve_l2_normalize must validate as a durable
    // pensieve-vectors record. The pre-fix map omission would have rejected this sample
    // at ValidStoredSample (operation not in OperationSlices), dropping legitimate evidence.
    [Fact]
    public void ValidStoredSampleAcceptsCanonicalPensieveL2NormalizeRecord()
    {
        DomainCoreShadowEvidenceIdentity identity = Identity();
        var sample = Sample(1) with
        {
            Slice = "pensieve-vectors",
            Operation = "pensieve_l2_normalize",
        };
        Assert.True(DomainCoreQuotaShadowEvidence.ValidStoredSample(identity, sample, DateTimeOffset.UtcNow));
    }

    // A short-alias operation has no slice binding, so a stored sample carrying it must
    // be rejected by ValidStoredSample even when the slice field claims pensieve-vectors.
    [Theory]
    [InlineData("cloak")]
    [InlineData("l2_normalize")]
    [InlineData("embed")]
    [InlineData("embed_and_cloak")]
    public void ValidStoredSampleRejectsShortAliasPensieveRecords(string operation)
    {
        DomainCoreShadowEvidenceIdentity identity = Identity();
        var sample = Sample(1) with
        {
            Slice = "pensieve-vectors",
            Operation = operation,
        };
        Assert.False(DomainCoreQuotaShadowEvidence.ValidStoredSample(identity, sample, DateTimeOffset.UtcNow));
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
    }

    private static DomainCoreShadowEvidenceIdentity Identity() => new(
        "internal",
        new string('a', 40),
        "0.3.0",
        3,
        new string('c', 64));

    private static DomainCoreShadowSampleV3 Sample(int suffix, DateTimeOffset? observedAt = null) => new()
    {
        SampleId = $"00000000-0000-4000-8000-{suffix:D12}",
        Channel = "internal",
        Slice = "claude",
        Operation = "claude_quota",
        CandidateCommit = new string('a', 40),
        ExpectedCoreVersion = "0.3.0",
        ExpectedCoreAbiVersion = 3,
        ExpectedCoreSourceSha256 = new string('c', 64),
        LoadedCoreVersion = "0.3.0",
        LoadedCoreAbiVersion = 3,
        LoadedCoreSourceSha256 = new string('c', 64),
        ObservedAt = (observedAt ?? DateTimeOffset.UtcNow).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'"),
        Outcome = "match",
        MismatchCategory = null,
        LegacyMicros = 120,
        RustMicros = 80,
    };
}

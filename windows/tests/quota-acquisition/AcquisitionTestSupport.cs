using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.Quota;
using OpenBurnBar.App.Quota.Acquisition;
using Xunit;

namespace OpenBurnBar.App.Quota.Acquisition.Tests;

/// <summary>Deterministic clock: settable now; delays recorded and (by default) immediate.</summary>
internal sealed class ManualQuotaClock : IQuotaAcquisitionClock
{
    public DateTimeOffset UtcNow { get; set; } = DateTimeOffset.FromUnixTimeSeconds(1783036800);

    public List<TimeSpan> Delays { get; } = new();

    /// <summary>Override to gate delays (e.g. hand back a TCS task for debounce tests).</summary>
    public Func<TimeSpan, CancellationToken, Task>? OnDelay { get; set; }

    public Task Delay(TimeSpan delay, CancellationToken cancellationToken)
    {
        Delays.Add(delay);
        return OnDelay is not null ? OnDelay(delay, cancellationToken) : Task.CompletedTask;
    }
}

/// <summary>Recording transport (cloudsync RecordingTransport pattern).</summary>
internal sealed class RecordingQuotaTransport : IQuotaHttpTransport
{
    private readonly Func<QuotaHttpRequest, QuotaHttpResponse> _responder;

    public RecordingQuotaTransport(Func<QuotaHttpRequest, QuotaHttpResponse> responder) => _responder = responder;

    public List<QuotaHttpRequest> Requests { get; } = new();

    public QuotaHttpRequest LastRequest => Requests[^1];

    public Task<QuotaHttpResponse> SendAsync(QuotaHttpRequest request, CancellationToken cancellationToken = default)
    {
        Requests.Add(request);
        return Task.FromResult(_responder(request));
    }

    public static QuotaHttpResponse Json(int status, string body, IReadOnlyDictionary<string, string>? headers = null) =>
        new(status, Encoding.UTF8.GetBytes(body), headers ?? new Dictionary<string, string>());

    public static QuotaHttpResponse Empty(int status, IReadOnlyDictionary<string, string>? headers = null) =>
        new(status, Array.Empty<byte>(), headers ?? new Dictionary<string, string>());
}

/// <summary>Scripted acquisition source for coordinator tests.</summary>
internal sealed class FakeQuotaSource : IQuotaPayloadSource
{
    private readonly Func<ProviderQuotaSnapshot?> _produce;

    public FakeQuotaSource(string sourceId, Func<ProviderQuotaSnapshot?> produce)
    {
        SourceId = sourceId;
        _produce = produce;
    }

    public string SourceId { get; }

    public int CallCount { get; private set; }

    public Task<ProviderQuotaSnapshot?> TryAcquireAsync(CancellationToken cancellationToken)
    {
        CallCount++;
        return Task.FromResult(_produce());
    }
}

/// <summary>Fake watcher for the seam contract tests — no real FileSystemWatcher.</summary>
internal sealed class FakeQuotaFileWatcher : IQuotaFileWatcher
{
    public event Action<string>? Changed;

    public bool Started { get; private set; }

    public bool Disposed { get; private set; }

    public void Start() => Started = true;

    public void Fire(string path) => Changed?.Invoke(path);

    public void Dispose() => Disposed = true;
}

/// <summary>Snapshot factory + shared fixture/oracle helpers.</summary>
internal static class AcquisitionTestSupport
{
    private const double Tolerance = 1e-6;

    private static readonly JsonSerializerOptions ExpectedOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
    };

    internal static ProviderQuotaSnapshot Snapshot(string provider, string statusMessage = "test") => new()
    {
        Provider = provider,
        FetchedAt = DateTimeOffset.FromUnixTimeSeconds(1783036800),
        Source = ProviderQuotaSourceKind.OfficialApi,
        Confidence = ProviderQuotaConfidence.Exact,
        StatusMessage = statusMessage,
        Buckets = new[]
        {
            new ProviderQuotaBucket
            {
                Key = $"{provider}-window",
                Label = "window",
                WindowKind = ProviderQuotaWindowKind.RollingHours,
                UsedPercent = 40,
                Unit = ProviderQuotaUnit.Percent,
            },
        },
    };

    internal static string ReadFixture(string fileName)
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", fileName);
        Assert.True(File.Exists(path), $"Missing fixture '{fileName}' at '{path}'.");
        return File.ReadAllText(path);
    }

    internal static ExpectedSnapshot ReadExpected(string fileName)
    {
        var expected = JsonSerializer.Deserialize<ExpectedSnapshot>(ReadFixture(fileName), ExpectedOptions);
        Assert.NotNull(expected);
        return expected!;
    }

    internal static IReadOnlyDictionary<string, string> ReadHeaderFixture(string fileName)
    {
        var map = JsonSerializer.Deserialize<Dictionary<string, string>>(ReadFixture(fileName));
        Assert.NotNull(map);
        return map!;
    }

    /// <summary>Value-for-value oracle assert (tests/quota QuotaFixtures.AssertMatches peer).</summary>
    internal static void AssertMatches(ProviderQuotaSnapshot actual, ExpectedSnapshot expected)
    {
        Assert.Equal(expected.Provider, actual.Provider);
        Assert.Equal(Enum.Parse<ProviderQuotaSourceKind>(expected.Source), actual.Source);
        Assert.Equal(Enum.Parse<ProviderQuotaConfidence>(expected.Confidence), actual.Confidence);
        Assert.Equal(expected.StatusMessage, actual.StatusMessage);
        Assert.Equal(expected.Buckets.Count, actual.Buckets.Count);

        for (var i = 0; i < expected.Buckets.Count; i++)
        {
            ExpectedBucket want = expected.Buckets[i];
            ProviderQuotaBucket got = actual.Buckets[i];
            Assert.Equal(want.Key, got.Key);
            Assert.Equal(want.Label, got.Label);
            Assert.Equal(Enum.Parse<ProviderQuotaWindowKind>(want.WindowKind), got.WindowKind);
            Assert.Equal(Enum.Parse<ProviderQuotaUnit>(want.Unit), got.Unit);
            Assert.Equal(want.IsEstimated, got.IsEstimated);
            AssertDouble(want.UsedValue, got.UsedValue, $"bucket[{i}].usedValue");
            AssertDouble(want.LimitValue, got.LimitValue, $"bucket[{i}].limitValue");
            AssertDouble(want.RemainingValue, got.RemainingValue, $"bucket[{i}].remainingValue");
            AssertDouble(want.UsedPercent, got.UsedPercent, $"bucket[{i}].usedPercent");
            AssertReset(want.ResetsAtUnix, got.ResetsAt, $"bucket[{i}].resetsAt");
        }
    }

    private static void AssertDouble(double? expected, double? actual, string field)
    {
        if (expected is null)
        {
            Assert.True(actual is null, $"{field}: expected null but got {actual}");
            return;
        }

        Assert.True(actual is not null, $"{field}: expected {expected} but got null");
        Assert.True(
            Math.Abs(expected.Value - actual!.Value) <= Tolerance,
            $"{field}: expected {expected} but got {actual}");
    }

    private static void AssertReset(long? expectedUnix, DateTimeOffset? actual, string field)
    {
        if (expectedUnix is null)
        {
            Assert.True(actual is null, $"{field}: expected null reset but got {actual}");
            return;
        }

        Assert.True(actual is not null, $"{field}: expected reset {expectedUnix} but got null");
        Assert.Equal(expectedUnix.Value, actual!.Value.ToUnixTimeSeconds());
    }

    /// <summary>Create an isolated temp dir; caller wraps in try/finally delete.</summary>
    internal static string CreateTempDirectory()
    {
        var path = Path.Combine(Path.GetTempPath(), $"obb-quota-acq-{Guid.NewGuid():N}");
        Directory.CreateDirectory(path);
        return path;
    }
}

/// <summary>The committed expected-snapshot shape (tests/quota parity oracle).</summary>
internal sealed class ExpectedSnapshot
{
    public string Provider { get; set; } = string.Empty;

    public string Source { get; set; } = string.Empty;

    public string Confidence { get; set; } = string.Empty;

    public string StatusMessage { get; set; } = string.Empty;

    public long? NowUnix { get; set; }

    public List<ExpectedBucket> Buckets { get; set; } = new();
}

/// <summary>One expected bucket.</summary>
internal sealed class ExpectedBucket
{
    public string Key { get; set; } = string.Empty;

    public string Label { get; set; } = string.Empty;

    public string WindowKind { get; set; } = string.Empty;

    public double? UsedValue { get; set; }

    public double? LimitValue { get; set; }

    public double? RemainingValue { get; set; }

    public double? UsedPercent { get; set; }

    public long? ResetsAtUnix { get; set; }

    public string Unit { get; set; } = string.Empty;

    public bool IsEstimated { get; set; }
}

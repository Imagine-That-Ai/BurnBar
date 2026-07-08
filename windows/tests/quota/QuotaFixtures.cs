using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using OpenBurnBar.App.Presentation.Quota;
using Xunit;

namespace OpenBurnBar.App.Quota.Tests;

/// <summary>
/// Loads the committed recorded quota fixtures (input + expected snapshot) and
/// asserts a parsed <see cref="ProviderQuotaSnapshot"/> matches the expected
/// snapshot value-for-value. The expected files are hand-derived from the Swift
/// adapter algorithm (with epoch conversions computed independently), so they
/// are a genuine parity oracle rather than a re-statement of the C# code.
/// </summary>
internal static class QuotaFixtures
{
    private const double Tolerance = 1e-6;

    private static readonly JsonSerializerOptions ExpectedOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
    };

    internal static string ReadInput(string fileName) => File.ReadAllText(FixturePath(fileName));

    internal static ExpectedSnapshot ReadExpected(string fileName)
    {
        var json = File.ReadAllText(FixturePath(fileName));
        var expected = JsonSerializer.Deserialize<ExpectedSnapshot>(json, ExpectedOptions);
        Assert.NotNull(expected);
        return expected!;
    }

    /// <summary>Parse the header-input fixture into a case-preserving header dictionary.</summary>
    internal static IReadOnlyDictionary<string, string> ReadHeaderInput(string fileName)
    {
        var json = File.ReadAllText(FixturePath(fileName));
        var map = JsonSerializer.Deserialize<Dictionary<string, string>>(json);
        Assert.NotNull(map);
        return map!;
    }

    /// <summary>Assert the parsed snapshot equals the expected fixture value-for-value.</summary>
    internal static void AssertMatches(ProviderQuotaSnapshot actual, ExpectedSnapshot expected)
    {
        Assert.Equal(expected.Provider, actual.Provider);
        Assert.Equal(Enum.Parse<ProviderQuotaSourceKind>(expected.Source), actual.Source);
        Assert.Equal(Enum.Parse<ProviderQuotaConfidence>(expected.Confidence), actual.Confidence);
        Assert.Equal(expected.StatusMessage, actual.StatusMessage);
        Assert.Equal(expected.Buckets.Count, actual.Buckets.Count);

        for (var i = 0; i < expected.Buckets.Count; i++)
        {
            var want = expected.Buckets[i];
            var got = actual.Buckets[i];
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
            $"{field}: expected {expected} but got {actual} (Δ {Math.Abs(expected.Value - actual.Value)})");
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

    private static string FixturePath(string fileName)
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", fileName);
        if (!File.Exists(path))
        {
            throw new FileNotFoundException($"Missing quota fixture '{fileName}' at '{path}'.");
        }

        return path;
    }
}

/// <summary>The committed expected-snapshot shape (parity oracle).</summary>
internal sealed class ExpectedSnapshot
{
    public string Provider { get; set; } = string.Empty;

    public string Source { get; set; } = string.Empty;

    public string Confidence { get; set; } = string.Empty;

    public string StatusMessage { get; set; } = string.Empty;

    /// <summary>Fixed reference instant for relative-reset mechanisms (Codex / headers).</summary>
    public long? NowUnix { get; set; }

    public List<ExpectedBucket> Buckets { get; set; } = new();
}

/// <summary>One expected bucket. Fields mirror <see cref="ProviderQuotaBucket"/>.</summary>
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

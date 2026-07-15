using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using OpenBurnBar.App.Presentation.Quota;
using Xunit;
using DomainCore = uniffi.openburnbar_domain_ffi.OpenburnbarDomainFfiMethods;

namespace OpenBurnBar.App.Quota.Tests;

public sealed class DomainCoreQuotaBridgeTests
{
    [Fact]
    public void Apply_ShadowNativeUnavailable_FallsBackToLegacy()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(1783036800);
        var expected = CodexUsageQuotaParser.Parse(
            QuotaFixtures.ReadInput("codex-usage-input.json"),
            now,
            DomainCoreQuotaMigrationMode.Legacy);
        var legacyEvaluations = 0;
        var order = new List<string>();
        var categories = new List<string?>();
        var snapshot = DomainCoreQuotaBridge.Apply(
            "codex_quota_test",
            () =>
            {
                order.Add("rust");
                throw new DllNotFoundException("simulated missing pilot library");
            },
            () =>
            {
                order.Add("legacy");
                legacyEvaluations++;
                return expected;
            },
            now,
            CodexUsageQuotaParser.ManagementUrl,
            mapMalformedSnapshot: false,
            DomainCoreQuotaMigrationMode.Shadow,
            requireNative: false,
            comparisonSink: (_, _, _, category, _, _) => categories.Add(category));

        Assert.Same(expected, snapshot);
        Assert.Equal(1, legacyEvaluations);
        Assert.Equal(new[] { "legacy", "rust" }, order);
        Assert.Equal(new[] { "native_unavailable" }, categories);
    }

    [Fact]
    public void Apply_RustNativeUnavailable_FailsClosedWithoutLegacy()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(1783036800);
        var legacyEvaluations = 0;

        Assert.Throws<InvalidOperationException>(() => DomainCoreQuotaBridge.Apply(
            "codex_quota_test",
            () => throw new DllNotFoundException("simulated missing core"),
            () =>
            {
                legacyEvaluations++;
                return null;
            },
            now,
            CodexUsageQuotaParser.ManagementUrl,
            mapMalformedSnapshot: false,
            DomainCoreQuotaMigrationMode.Rust,
            requireNative: false));
        Assert.Equal(0, legacyEvaluations);
    }

    [Fact]
    public void Apply_RustMode_DoesNotEvaluateLegacyParser()
    {
        var input = QuotaFixtures.ReadInput("codex-usage-input.json");
        var now = DateTimeOffset.FromUnixTimeSeconds(1783036800);
        var legacyEvaluations = 0;

        var snapshot = DomainCoreQuotaBridge.Apply(
            "codex_quota_test",
            () => DomainCore.ParseCodexUsageQuota(Encoding.UTF8.GetBytes(input), now.ToUnixTimeSeconds()),
            () =>
            {
                legacyEvaluations++;
                return null;
            },
            now,
            CodexUsageQuotaParser.ManagementUrl,
            mapMalformedSnapshot: false,
            DomainCoreQuotaMigrationMode.Rust);

        Assert.NotNull(snapshot);
        Assert.Equal(0, legacyEvaluations);
    }

    [Fact]
    public void Apply_ShadowMode_EvaluatesLegacyParserOnce()
    {
        var input = QuotaFixtures.ReadInput("codex-usage-input.json");
        var now = DateTimeOffset.FromUnixTimeSeconds(1783036800);
        var expected = CodexUsageQuotaParser.Parse(input, now, DomainCoreQuotaMigrationMode.Legacy);
        var legacyEvaluations = 0;

        var snapshot = DomainCoreQuotaBridge.Apply(
            "codex_quota_test",
            () => DomainCore.ParseCodexUsageQuota(Encoding.UTF8.GetBytes(input), now.ToUnixTimeSeconds()),
            () =>
            {
                legacyEvaluations++;
                return expected;
            },
            now,
            CodexUsageQuotaParser.ManagementUrl,
            mapMalformedSnapshot: false,
            DomainCoreQuotaMigrationMode.Shadow);

        Assert.Same(expected, snapshot);
        Assert.Equal(1, legacyEvaluations);
    }

    [Fact]
    public void Apply_ShadowMode_EmitsExactlyOneWholeCallComparison()
    {
        var input = QuotaFixtures.ReadInput("codex-usage-input.json");
        var now = DateTimeOffset.FromUnixTimeSeconds(1783036800);
        var expected = CodexUsageQuotaParser.Parse(input, now, DomainCoreQuotaMigrationMode.Legacy);
        var comparisons = 0;
        _ = DomainCoreQuotaBridge.Apply(
            "codex_quota",
            () => DomainCore.ParseCodexUsageQuota(Encoding.UTF8.GetBytes(input), now.ToUnixTimeSeconds()),
            () => expected,
            now,
            CodexUsageQuotaParser.ManagementUrl,
            mapMalformedSnapshot: false,
            DomainCoreQuotaMigrationMode.Shadow,
            comparisonSink: (operation, version, equivalent, category, legacyMicros, rustMicros) =>
            {
                Assert.Equal("codex_quota", operation);
                Assert.False(string.IsNullOrWhiteSpace(version));
                Assert.True(equivalent);
                Assert.Null(category);
                Assert.True(legacyMicros >= 0);
                Assert.True(rustMicros >= 0);
                comparisons++;
            });

        Assert.Equal(1, comparisons);
    }

    [Fact]
    public void Apply_DevelopmentModeEnvVarAndV2Spool_AreStartable()
    {
        // Development builds honor the canonical process override. Signed
        // artifacts instead bind mode and evidence channel to their embedded
        // build profile, as documented by the operator runbook.
        var input = QuotaFixtures.ReadInput("codex-usage-input.json");
        var now = DateTimeOffset.FromUnixTimeSeconds(1783036800);
        var expected = CodexUsageQuotaParser.Parse(input, now, DomainCoreQuotaMigrationMode.Legacy);
        var comparisons = 0;
        var previousMode = Environment.GetEnvironmentVariable(
            "OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE", EnvironmentVariableTarget.Process);

        Environment.SetEnvironmentVariable(
            "OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE", "shadow", EnvironmentVariableTarget.Process);
        try
        {
            _ = DomainCoreQuotaBridge.Apply(
                "codex_quota",
                () => DomainCore.ParseCodexUsageQuota(Encoding.UTF8.GetBytes(input), now.ToUnixTimeSeconds()),
                () => expected,
                now,
                CodexUsageQuotaParser.ManagementUrl,
                mapMalformedSnapshot: false,
                requestedMode: null,
                comparisonSink: (operation, version, equivalent, category, legacyMicros, rustMicros) =>
                {
                    Assert.Equal("codex_quota", operation);
                    Assert.False(string.IsNullOrWhiteSpace(version));
                    Assert.True(equivalent);
                    Assert.Null(category);
                    Assert.True(legacyMicros >= 0);
                    Assert.True(rustMicros >= 0);
                    comparisons++;
                });
        }
        finally
        {
            Environment.SetEnvironmentVariable(
                "OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE", previousMode, EnvironmentVariableTarget.Process);
        }

        Assert.Equal(1, comparisons);

        // Prove the current v2 telemetry schema can traverse the bounded spool.
        var directory = Path.Combine(Path.GetTempPath(), $"openburnbar-shadow-{Guid.NewGuid():D}");
        try
        {
            var spool = new DomainCoreQuotaShadowEvidenceSpool(directory);
            var sample = new DomainCoreShadowSampleV2
            {
                SampleId = Guid.NewGuid().ToString("D", CultureInfo.InvariantCulture),
                Channel = "internal",
                Slice = "codex",
                Operation = "codex_quota",
                CoreVersion = "0.3.0",
                ObservedAt = "2026-07-13T12:00:00.000Z",
                Outcome = "match",
                MismatchCategory = null,
                LegacyMicros = 120,
                RustMicros = 80,
            };

            spool.Append(sample);
            var batch = Assert.IsType<DomainCoreQuotaShadowEvidenceSpool.ReadyBatch>(spool.NextBatch());

            Assert.Single(batch.Samples);
            Assert.Equal(sample.SampleId, batch.Samples[0].SampleId);
            Assert.Equal("internal", batch.Samples[0].Channel);
            Assert.Equal("codex", batch.Samples[0].Slice);
            Assert.Equal("codex_quota", batch.Samples[0].Operation);
            spool.Acknowledge(batch.Token);
            Assert.Equal(0, spool.PendingSampleCount());
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }
}

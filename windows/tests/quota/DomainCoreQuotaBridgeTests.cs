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
    public void Apply_ShadowModeWithChannelEnvVar_RecordsTelemetrySample()
    {
        // P-ARCH-1a part 1: prove the Windows shadow clock is truly startable
        // via the OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE env var — NOT by passing
        // Shadow directly. The test sets the env var, passes requestedMode:null,
        // and verifies the production resolution path enters shadow mode.
        var input = QuotaFixtures.ReadInput("codex-usage-input.json");
        var now = DateTimeOffset.FromUnixTimeSeconds(1783036800);
        var expected = CodexUsageQuotaParser.Parse(input, now, DomainCoreQuotaMigrationMode.Legacy);
        var comparisons = 0;

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
                    Assert.False(string.IsNullOrWhiteSpace(operation));
                    Assert.False(string.IsNullOrWhiteSpace(version));
                    Assert.True(legacyMicros >= 0);
                    Assert.True(rustMicros >= 0);
                    comparisons++;
                });
        }
        finally
        {
            Environment.SetEnvironmentVariable(
                "OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE", null, EnvironmentVariableTarget.Process);
        }

        Assert.Equal(1, comparisons);

        // P-ARCH-1a part 2: prove the telemetry path is gated by the
        // OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL env var — NOT by directly
        // calling spool.Append. The test calls the production
        // DomainCoreQuotaShadowEvidence.RecordComparison sink, which reads the
        // channel env var and only persists when it is internal or beta.
        var spoolDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "OpenBurnBar", "DomainCoreShadow");

        // With channel=internal, RecordComparison MUST persist a sample.
        Environment.SetEnvironmentVariable(
            "OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL", "internal", EnvironmentVariableTarget.Process);
        try
        {
            DomainCoreQuotaShadowEvidence.RecordComparison(
                "codex_quota", "0.3.0", equivalent: true, mismatchCategory: null,
                legacyMicros: 120, rustMicros: 80);

            // Verify a sample was persisted to the spool directory.
            Assert.True(Directory.Exists(spoolDir), "spool directory must exist after RecordComparison with channel=internal");
            var files = Directory.GetFiles(spoolDir, "*.jsonl");
            Assert.True(files.Length > 0, "at least one .jsonl file must exist after RecordComparison with channel=internal");
            var sampleText = File.ReadAllText(files[0]);
            Assert.Contains("\"channel\":\"internal\"", sampleText);
            Assert.Contains("\"operation\":\"codex_quota\"", sampleText);
        }
        finally
        {
            Environment.SetEnvironmentVariable(
                "OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL", null, EnvironmentVariableTarget.Process);
            // Clean up spool directory to avoid polluting the test machine.
            if (Directory.Exists(spoolDir)) Directory.Delete(spoolDir, recursive: true);
        }

        // With channel=production (or unset), RecordComparison MUST NOT persist.
        Environment.SetEnvironmentVariable(
            "OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL", "production", EnvironmentVariableTarget.Process);
        try
        {
            var beforeFiles = Directory.Exists(spoolDir)
                ? Directory.GetFiles(spoolDir, "*.jsonl").Length
                : 0;

            DomainCoreQuotaShadowEvidence.RecordComparison(
                "codex_quota", "0.3.0", equivalent: true, mismatchCategory: null,
                legacyMicros: 120, rustMicros: 80);

            var afterFiles = Directory.Exists(spoolDir)
                ? Directory.GetFiles(spoolDir, "*.jsonl").Length
                : 0;
            Assert.Equal(beforeFiles, afterFiles);
        }
        finally
        {
            Environment.SetEnvironmentVariable(
                "OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL", null, EnvironmentVariableTarget.Process);
            if (Directory.Exists(spoolDir)) Directory.Delete(spoolDir, recursive: true);
        }
    }
}

using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using OpenBurnBar.App.Presentation.Quota;
using Xunit;
using DomainCore = uniffi.openburnbar_domain_ffi.OpenburnbarDomainFfiMethods;

namespace OpenBurnBar.App.Quota.Tests;

public sealed class DomainCoreQuotaBridgeTests
{
    [Fact]
    public void Loaded_native_identity_is_observed_for_attestation()
    {
        var nativeLibraryPath = Environment.GetEnvironmentVariable("DOMAIN_CORE_NATIVE_LIBRARY_PATH");
        var reportPath = Environment.GetEnvironmentVariable("DOMAIN_CORE_OBSERVED_IDENTITY_REPORT");
        if (string.IsNullOrWhiteSpace(nativeLibraryPath) && string.IsNullOrWhiteSpace(reportPath))
        {
            return;
        }

        Assert.False(string.IsNullOrWhiteSpace(nativeLibraryPath));
        Assert.False(string.IsNullOrWhiteSpace(reportPath));
        nativeLibraryPath = Path.GetFullPath(nativeLibraryPath!);
        Assert.True(File.Exists(nativeLibraryPath));
        Assert.False(File.GetAttributes(nativeLibraryPath).HasFlag(FileAttributes.ReparsePoint));

        NativeLibrary.SetDllImportResolver(
            typeof(DomainCore).Assembly,
            (libraryName, _, _) =>
                libraryName == "openburnbar_domain_ffi"
                    ? NativeLibrary.Load(nativeLibraryPath)
                    : IntPtr.Zero);

        var identity = new
        {
            candidateCommit = Environment.GetEnvironmentVariable("DOMAIN_CORE_CANDIDATE_COMMIT") ?? string.Empty,
            coreVersion = DomainCore.DomainCoreVersion(),
            abiVersion = DomainCore.DomainCoreAbiVersion(),
            sourceSha256 = DomainCore.DomainCoreSourceFingerprint(),
            binarySha256 = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(nativeLibraryPath))).ToLowerInvariant(),
        };
        Assert.Matches("^[0-9a-f]{40}$", identity.candidateCommit);
        Assert.False(string.IsNullOrWhiteSpace(identity.coreVersion));
        Assert.Equal(3u, identity.abiVersion);
        Assert.Matches("^[0-9a-f]{64}$", identity.sourceSha256);
        Assert.Matches("^[0-9a-f]{64}$", identity.binarySha256);

        File.WriteAllText(reportPath!, JsonSerializer.Serialize(identity) + Environment.NewLine);
    }

    [Fact]
    public void Apply_ShadowOperationLoadError_RetainsLoadedIdentityAndFallsBackToLegacy()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(1783036800);
        var expected = CodexUsageQuotaParser.Parse(
            QuotaFixtures.ReadInput("codex-usage-input.json"),
            now,
            DomainCoreQuotaMigrationMode.Legacy);
        var legacyEvaluations = 0;
        var order = new List<string>();
        var categories = new List<string?>();
        var loadedIdentities = new List<DomainCoreShadowLoadedIdentity?>();
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
            comparisonSink: (_, loadedIdentity, _, category, _, _) =>
            {
                loadedIdentities.Add(loadedIdentity);
                categories.Add(category);
            });

        Assert.Same(expected, snapshot);
        Assert.Equal(1, legacyEvaluations);
        Assert.Equal(new[] { "legacy", "rust" }, order);
        Assert.Equal(new[] { "native_error" }, categories);
        Assert.NotNull(Assert.Single(loadedIdentities));
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
            comparisonSink: (operation, loadedIdentity, equivalent, category, legacyMicros, rustMicros) =>
            {
                Assert.Equal("codex_quota", operation);
                Assert.NotNull(loadedIdentity);
                Assert.False(string.IsNullOrWhiteSpace(loadedIdentity.CoreVersion));
                Assert.Equal(3u, loadedIdentity.CoreAbiVersion);
                Assert.Matches("^[0-9a-f]{64}$", loadedIdentity.CoreSourceSha256);
                Assert.True(equivalent);
                Assert.Null(category);
                Assert.True(legacyMicros >= 0);
                Assert.True(rustMicros >= 0);
                comparisons++;
            });

        Assert.Equal(1, comparisons);
    }
}

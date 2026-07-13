using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using DomainCore = uniffi.openburnbar_domain_ffi.OpenburnbarDomainFfiMethods;
using DomainQuotaParseResult = uniffi.openburnbar_domain_ffi.QuotaParseResult;
using DomainQuotaParseStatus = uniffi.openburnbar_domain_ffi.QuotaParseStatus;

namespace OpenBurnBar.App.Presentation.Quota;

internal static class DomainCoreQuotaBridge
{
    private const string RequireNativeVariable = "OPENBURNBAR_REQUIRE_DOMAIN_CORE_NATIVE";

    internal static ProviderQuotaSnapshot? Apply(
        string operation,
        Func<DomainQuotaParseResult> rust,
        Func<ProviderQuotaSnapshot?> legacy,
        DateTimeOffset fetchedAt,
        string managementUrl,
        bool mapMalformedSnapshot,
        DomainCoreQuotaMigrationMode? requestedMode = null,
        bool? requireNative = null)
    {
        var mode = requestedMode ?? ClaudeStatuslineQuotaDomainCore.ResolveMode(
            Environment.GetEnvironmentVariable("OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE"));
        if (mode == DomainCoreQuotaMigrationMode.Legacy)
        {
            return legacy();
        }

        if (!TryInvoke(rust, out var result))
        {
            if (requireNative ?? NativeRequired())
            {
                throw new InvalidOperationException(
                    $"Domain-core native library is required for {operation}, but it could not be loaded.");
            }

            Trace.TraceWarning("domain_core.{0}.native_unavailable mode={1}", operation, mode);
            return legacy();
        }

        var rustSnapshot = MapResult(result!, fetchedAt, managementUrl, mapMalformedSnapshot);
        if (mode == DomainCoreQuotaMigrationMode.Rust)
        {
            return rustSnapshot;
        }

        var legacySnapshot = legacy();
        if (!Equivalent(legacySnapshot, rustSnapshot))
        {
            Trace.TraceWarning(
                "domain_core.{0}.shadow_mismatch core={1} legacy_count={2} rust_count={3}",
                operation,
                DomainCore.DomainCoreVersion(),
                legacySnapshot?.Buckets.Count ?? 0,
                rustSnapshot?.Buckets.Count ?? 0);
        }

        return legacySnapshot;
    }

    private static bool TryInvoke(Func<DomainQuotaParseResult> rust, out DomainQuotaParseResult? result)
    {
        result = null;
        try
        {
            if (DomainCore.DomainCoreAbiVersion() != 2)
            {
                return false;
            }

            result = rust();
            return true;
        }
        catch (Exception error) when (
            error is DllNotFoundException
                or EntryPointNotFoundException
                or BadImageFormatException
                or TypeInitializationException)
        {
            return false;
        }
    }

    private static ProviderQuotaSnapshot? MapResult(
        DomainQuotaParseResult result,
        DateTimeOffset fetchedAt,
        string managementUrl,
        bool mapMalformedSnapshot)
    {
        var shouldMap = result.status switch
        {
            DomainQuotaParseStatus.Parsed => true,
            DomainQuotaParseStatus.Empty => false,
            DomainQuotaParseStatus.Malformed => mapMalformedSnapshot,
            _ => throw new ArgumentOutOfRangeException(nameof(result), result.status, "Unknown domain-core parse status."),
        };
        if (!shouldMap)
        {
            return null;
        }

        var snapshot = result.snapshot;
        return new ProviderQuotaSnapshot
        {
            Provider = snapshot.provider,
            FetchedAt = fetchedAt,
            Source = snapshot.source switch
            {
                uniffi.openburnbar_domain_ffi.QuotaSourceKind.OfficialApi => ProviderQuotaSourceKind.OfficialApi,
                uniffi.openburnbar_domain_ffi.QuotaSourceKind.LocalCli => ProviderQuotaSourceKind.LocalCli,
                uniffi.openburnbar_domain_ffi.QuotaSourceKind.LocalSession => ProviderQuotaSourceKind.LocalSession,
                uniffi.openburnbar_domain_ffi.QuotaSourceKind.ManualEstimate => ProviderQuotaSourceKind.ManualEstimate,
                uniffi.openburnbar_domain_ffi.QuotaSourceKind.Unavailable => ProviderQuotaSourceKind.Unavailable,
                _ => throw new ArgumentOutOfRangeException(nameof(result), snapshot.source, "Unknown domain-core source kind."),
            },
            Confidence = snapshot.confidence switch
            {
                uniffi.openburnbar_domain_ffi.QuotaConfidence.Exact => ProviderQuotaConfidence.Exact,
                uniffi.openburnbar_domain_ffi.QuotaConfidence.Estimated => ProviderQuotaConfidence.Estimated,
                uniffi.openburnbar_domain_ffi.QuotaConfidence.Unavailable => ProviderQuotaConfidence.Unavailable,
                _ => throw new ArgumentOutOfRangeException(nameof(result), snapshot.confidence, "Unknown domain-core confidence."),
            },
            ManagementUrl = managementUrl,
            StatusMessage = snapshot.statusMessage,
            Buckets = snapshot.buckets.Select(MapBucket).ToArray(),
        };
    }

    private static ProviderQuotaBucket MapBucket(uniffi.openburnbar_domain_ffi.QuotaBucket bucket)
    {
        return new ProviderQuotaBucket
        {
            Key = bucket.key,
            Label = bucket.label,
            WindowKind = bucket.windowKind switch
            {
                uniffi.openburnbar_domain_ffi.QuotaWindowKind.RollingHours => ProviderQuotaWindowKind.RollingHours,
                uniffi.openburnbar_domain_ffi.QuotaWindowKind.RollingDays => ProviderQuotaWindowKind.RollingDays,
                uniffi.openburnbar_domain_ffi.QuotaWindowKind.Daily => ProviderQuotaWindowKind.Daily,
                uniffi.openburnbar_domain_ffi.QuotaWindowKind.Weekly => ProviderQuotaWindowKind.Weekly,
                uniffi.openburnbar_domain_ffi.QuotaWindowKind.Monthly => ProviderQuotaWindowKind.Monthly,
                uniffi.openburnbar_domain_ffi.QuotaWindowKind.Lifetime => ProviderQuotaWindowKind.Lifetime,
                uniffi.openburnbar_domain_ffi.QuotaWindowKind.Custom => ProviderQuotaWindowKind.Custom,
                _ => throw new ArgumentOutOfRangeException(nameof(bucket), bucket.windowKind, "Unknown domain-core window kind."),
            },
            UsedValue = bucket.usedValue,
            LimitValue = bucket.limitValue,
            RemainingValue = bucket.remainingValue,
            UsedPercent = bucket.usedPercent,
            ResetsAt = bucket.resetsAtUnix is double unix ? DateTimeOffset.UnixEpoch.AddSeconds(unix) : null,
            Unit = bucket.unit switch
            {
                uniffi.openburnbar_domain_ffi.QuotaUnit.Percent => ProviderQuotaUnit.Percent,
                uniffi.openburnbar_domain_ffi.QuotaUnit.Requests => ProviderQuotaUnit.Requests,
                uniffi.openburnbar_domain_ffi.QuotaUnit.Tokens => ProviderQuotaUnit.Tokens,
                uniffi.openburnbar_domain_ffi.QuotaUnit.Sessions => ProviderQuotaUnit.Sessions,
                uniffi.openburnbar_domain_ffi.QuotaUnit.Lines => ProviderQuotaUnit.Lines,
                uniffi.openburnbar_domain_ffi.QuotaUnit.Files => ProviderQuotaUnit.Files,
                uniffi.openburnbar_domain_ffi.QuotaUnit.Count => ProviderQuotaUnit.Count,
                uniffi.openburnbar_domain_ffi.QuotaUnit.Currency => ProviderQuotaUnit.Currency,
                _ => throw new ArgumentOutOfRangeException(nameof(bucket), bucket.unit, "Unknown domain-core quota unit."),
            },
            IsEstimated = bucket.isEstimated,
        };
    }

    private static bool Equivalent(ProviderQuotaSnapshot? legacy, ProviderQuotaSnapshot? rust)
    {
        if (legacy is null || rust is null)
        {
            return legacy is null && rust is null;
        }

        return legacy.Provider == rust.Provider
            && legacy.Source == rust.Source
            && legacy.Confidence == rust.Confidence
            && legacy.ManagementUrl == rust.ManagementUrl
            && legacy.StatusMessage == rust.StatusMessage
            && Equivalent(legacy.Buckets, rust.Buckets);
    }

    private static bool Equivalent(
        IReadOnlyList<ProviderQuotaBucket> legacy,
        IReadOnlyList<ProviderQuotaBucket> rust)
    {
        return legacy.Count == rust.Count && legacy.Zip(rust).All(pair =>
            pair.First.Key == pair.Second.Key
            && pair.First.Label == pair.Second.Label
            && pair.First.WindowKind == pair.Second.WindowKind
            && Close(pair.First.UsedValue, pair.Second.UsedValue)
            && Close(pair.First.LimitValue, pair.Second.LimitValue)
            && Close(pair.First.RemainingValue, pair.Second.RemainingValue)
            && Close(pair.First.UsedPercent, pair.Second.UsedPercent)
            && Close(pair.First.ResetsAt?.ToUnixTimeMilliseconds(), pair.Second.ResetsAt?.ToUnixTimeMilliseconds())
            && pair.First.Unit == pair.Second.Unit
            && pair.First.IsEstimated == pair.Second.IsEstimated);
    }

    private static bool NativeRequired() =>
        string.Equals(Environment.GetEnvironmentVariable(RequireNativeVariable), "1", StringComparison.Ordinal);

    private static bool Close(double? left, double? right) =>
        left is null && right is null
        || left is double l && right is double r && Math.Abs(l - r) <= 0.000001;

    private static bool Close(long? left, long? right) =>
        left is null && right is null
        || left is long l && right is long r && Math.Abs(l - r) <= 1;
}

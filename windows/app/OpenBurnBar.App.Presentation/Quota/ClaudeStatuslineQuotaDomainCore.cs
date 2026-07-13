using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Text;
using DomainCore = uniffi.openburnbar_domain_ffi.OpenburnbarDomainFfiMethods;
using DomainQuotaBucket = uniffi.openburnbar_domain_ffi.QuotaBucket;
using DomainQuotaParseStatus = uniffi.openburnbar_domain_ffi.QuotaParseStatus;

namespace OpenBurnBar.App.Presentation.Quota;

internal enum DomainCoreQuotaMigrationMode
{
    Legacy,
    Shadow,
    Rust,
}

internal static class ClaudeStatuslineQuotaDomainCore
{
    private const string ModeVariable = "OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE";

    internal static ProviderQuotaSnapshot Apply(string json, ProviderQuotaSnapshot legacy)
    {
        return Apply(json, () => legacy, legacy.FetchedAt, legacy.StatusMessage,
            ResolveMode(Environment.GetEnvironmentVariable(ModeVariable)));
    }

    internal static ProviderQuotaSnapshot Apply(
        string json,
        ProviderQuotaSnapshot legacy,
        DomainCoreQuotaMigrationMode mode)
    {
        return Apply(json, () => legacy, legacy.FetchedAt, legacy.StatusMessage, mode);
    }

    internal static ProviderQuotaSnapshot Apply(
        string json,
        Func<ProviderQuotaSnapshot> legacy,
        DateTimeOffset fetchedAt,
        string statusMessage,
        DomainCoreQuotaMigrationMode? requestedMode = null)
    {
        var mode = requestedMode ?? ResolveMode(Environment.GetEnvironmentVariable(ModeVariable));
        if (mode == DomainCoreQuotaMigrationMode.Legacy)
        {
            return legacy();
        }

        if (!TryParseBuckets(json, out var rustBuckets))
        {
            Trace.TraceWarning("domain_core.claude_quota.native_unavailable mode={0}", mode);
            return legacy();
        }

        var rust = new ProviderQuotaSnapshot
        {
            Provider = ClaudeStatuslineQuotaParser.ProviderToken,
            FetchedAt = fetchedAt,
            Source = ProviderQuotaSourceKind.LocalCli,
            Confidence = ProviderQuotaConfidence.Exact,
            ManagementUrl = ClaudeStatuslineQuotaParser.ManagementUrl,
            StatusMessage = statusMessage,
            Buckets = rustBuckets,
        };

        if (mode == DomainCoreQuotaMigrationMode.Shadow)
        {
            var legacySnapshot = legacy();
            if (!Equivalent(legacySnapshot.Buckets, rustBuckets))
            {
                Trace.TraceWarning(
                    "domain_core.claude_quota.shadow_mismatch core={0} legacy_count={1} rust_count={2}",
                    DomainCore.DomainCoreVersion(),
                    legacySnapshot.Buckets.Count,
                    rustBuckets.Count);
            }
            return legacySnapshot;
        }

        return rust;
    }

    internal static DomainCoreQuotaMigrationMode ResolveMode(string? raw)
    {
        return raw?.Trim().ToLowerInvariant() switch
        {
            "shadow" => DomainCoreQuotaMigrationMode.Shadow,
            "rust" => DomainCoreQuotaMigrationMode.Rust,
            _ => DomainCoreQuotaMigrationMode.Legacy,
        };
    }

    private static bool TryParseBuckets(string json, out IReadOnlyList<ProviderQuotaBucket> buckets)
    {
        buckets = ProviderQuotaSnapshot.NoBuckets;
        try
        {
            if (DomainCore.DomainCoreAbiVersion() != 1)
            {
                return false;
            }

            var result = DomainCore.ParseClaudeStatuslineQuota(Encoding.UTF8.GetBytes(json));
            if (result.status != DomainQuotaParseStatus.Parsed)
            {
                return true;
            }

            buckets = result.snapshot.buckets.Select(MapBucket).ToArray();
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

    private static ProviderQuotaBucket MapBucket(DomainQuotaBucket bucket)
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

    private static bool Equivalent(
        IReadOnlyList<ProviderQuotaBucket> legacy,
        IReadOnlyList<ProviderQuotaBucket> rust)
    {
        if (legacy.Count != rust.Count)
        {
            return false;
        }

        return legacy.Zip(rust).All(pair =>
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

    private static bool Close(double? left, double? right) =>
        left is null && right is null
        || left is double l && right is double r && Math.Abs(l - r) <= 0.000001;

    private static bool Close(long? left, long? right) =>
        left is null && right is null
        || left is long l && right is long r && Math.Abs(l - r) <= 1;
}

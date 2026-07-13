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
        return Apply(json, legacy, ResolveMode(Environment.GetEnvironmentVariable(ModeVariable)));
    }

    internal static ProviderQuotaSnapshot Apply(
        string json,
        ProviderQuotaSnapshot legacy,
        DomainCoreQuotaMigrationMode mode)
    {
        if (mode == DomainCoreQuotaMigrationMode.Legacy)
        {
            return legacy;
        }

        if (!TryParseBuckets(json, out var rustBuckets))
        {
            Trace.TraceWarning("domain_core.claude_quota.native_unavailable mode={0}", mode);
            return legacy;
        }

        if (mode == DomainCoreQuotaMigrationMode.Shadow)
        {
            if (!legacy.Buckets.SequenceEqual(rustBuckets))
            {
                Trace.TraceWarning(
                    "domain_core.claude_quota.shadow_mismatch core={0} legacy_count={1} rust_count={2}",
                    DomainCore.DomainCoreVersion(),
                    legacy.Buckets.Count,
                    rustBuckets.Count);
            }
            return legacy;
        }

        return legacy with { Buckets = rustBuckets };
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
            WindowKind = (ProviderQuotaWindowKind)(int)bucket.windowKind,
            UsedValue = bucket.usedValue,
            LimitValue = bucket.limitValue,
            RemainingValue = bucket.remainingValue,
            UsedPercent = bucket.usedPercent,
            ResetsAt = bucket.resetsAtUnix is double unix ? DateTimeOffset.UnixEpoch.AddSeconds(unix) : null,
            Unit = (ProviderQuotaUnit)(int)bucket.unit,
            IsEstimated = bucket.isEstimated,
        };
    }
}

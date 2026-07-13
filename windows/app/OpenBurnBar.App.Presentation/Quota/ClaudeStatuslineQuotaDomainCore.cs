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
        if (mode == DomainCoreQuotaMigrationMode.Shadow)
        {
            return ApplyShadow(json, legacy);
        }

        var rustStarted = Stopwatch.GetTimestamp();
        if (!TryParseBuckets(json, out var rustBuckets))
        {
            Trace.TraceWarning("domain_core.claude_quota.native_unavailable mode={0}", mode);
            throw new InvalidOperationException("Domain-core Claude quota is unavailable in explicit Rust mode.");
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
        var rustMicros = ElapsedMicros(rustStarted);

        _ = rustMicros;
        return rust;
    }

    private static ProviderQuotaSnapshot ApplyShadow(string json, Func<ProviderQuotaSnapshot> legacy)
    {
        var legacyStarted = Stopwatch.GetTimestamp();
        var legacySnapshot = legacy();
        var legacyMicros = ElapsedMicros(legacyStarted);
        var rustStarted = Stopwatch.GetTimestamp();
        IReadOnlyList<ProviderQuotaBucket> rustBuckets = ProviderQuotaSnapshot.NoBuckets;
        string? mismatchCategory = null;
        try
        {
            if (DomainCore.DomainCoreAbiVersion() != 3)
            {
                mismatchCategory = "native_unavailable";
            }
            else
            {
                var result = DomainCore.ParseClaudeStatuslineQuota(Encoding.UTF8.GetBytes(json));
                if (result.status == DomainQuotaParseStatus.Malformed)
                {
                    mismatchCategory = "invalid_result";
                }
                else if (result.status == DomainQuotaParseStatus.Parsed)
                {
                    rustBuckets = result.snapshot.buckets.Select(MapBucket).ToArray();
                }
                if (mismatchCategory is null && !Equivalent(legacySnapshot.Buckets, rustBuckets))
                {
                    mismatchCategory = "result_mismatch";
                }
            }
        }
        catch (Exception error) when (IsNativeUnavailable(error))
        {
            mismatchCategory = "native_unavailable";
        }
        catch
        {
            mismatchCategory = "native_error";
        }
        var rustMicros = ElapsedMicros(rustStarted);
        DomainCoreQuotaShadowEvidence.RecordComparison(
            "claude_quota",
            SafeCoreVersion(),
            mismatchCategory is null,
            mismatchCategory,
            legacyMicros,
            rustMicros);
        return legacySnapshot;
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
            if (DomainCore.DomainCoreAbiVersion() != 3)
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

    private static bool IsNativeUnavailable(Exception error) =>
        error is DllNotFoundException
            or EntryPointNotFoundException
            or BadImageFormatException
            or TypeInitializationException;

    private static string SafeCoreVersion()
    {
        try { return DomainCore.DomainCoreVersion(); }
        catch { return "0.0.0-unavailable"; }
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

    private static long ElapsedMicros(long started) =>
        Math.Clamp((long)Stopwatch.GetElapsedTime(started).TotalMicroseconds, 0, 600_000_000);
}

using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.MemorySearch.Memory;

// PORTED (faithful) from
//   AgentLens/Services/Memory/MemoryExtractionSettingsSnapshot.swift
//   AgentLens/Services/Memory/MemoryExtractionEngine.swift  (makeSettingsSnapshot / localFirstProviderOrder / effectiveDailyCapUSD)
//
// Local-only is a HARD default in v1 (transcript egress to cloud is disallowed): the provider
// order is filtered to the on-device providers only, and if none survive it forces [Local].

/// <summary>Summary/extraction provider id. Swift: <c>SummaryProviderID</c> (the subset relevant to
/// on-device filtering plus the cloud ids the snapshot carries model names for).</summary>
public enum MemorySummaryProvider
{
    Local,
    Mlx,
    Ollama,
    MiniMax,
    OpenRouter,
    Zai,
}

/// <summary>
/// Immutable settings snapshot the extraction engine runs against. Swift:
/// <c>struct MemoryExtractionSettingsSnapshot</c>. Build it via <see cref="Build"/> to apply the
/// same clamps/derivations the Swift engine's <c>makeSettingsSnapshot</c> applies.
/// </summary>
public sealed record MemoryExtractionSettingsSnapshot(
    IReadOnlyList<MemorySummaryProvider> ProviderOrder,
    string LocalBaseUrl,
    string LocalModel,
    string MlxBaseUrl,
    string MlxModel,
    string MiniMaxModel,
    string OpenRouterPrimaryModel,
    string OpenRouterFallbackModel,
    string ZaiModel,
    string OllamaBaseUrl,
    string OllamaModel,
    double RequestTimeoutSeconds,
    int MaxPromptChars,
    int MaxOutputTokens,
    double DailyCapUsd,
    int RetryCount,
    int MaxCandidatesPerJob,
    string PromptVersion)
{
    /// <summary>The pinned prompt version. Swift: <c>ChatSessionController.memoryPromptVersion</c>.</summary>
    public const string DefaultPromptVersion = "openburnbar-prompt-v1";

    /// <summary>
    /// Builds a snapshot applying the engine's clamps/derivations. Swift:
    /// <c>makeSettingsSnapshot</c>. <paramref name="summaryProviderOrder"/> is filtered to on-device
    /// providers (else [Local]); timeout/cap/prompt-chars/output-tokens are clamped; retry floored at 0.
    /// </summary>
    public static MemoryExtractionSettingsSnapshot Build(
        IReadOnlyList<MemorySummaryProvider> summaryProviderOrder,
        string localBaseUrl,
        string localModel,
        string mlxBaseUrl,
        string mlxModel,
        string miniMaxModel,
        string openRouterPrimaryModel,
        string openRouterFallbackModel,
        string zaiModel,
        string ollamaBaseUrl,
        string ollamaModel,
        double configuredRequestTimeoutSeconds,
        int summaryMaxPromptChars,
        int summaryMaxOutputTokens,
        double? summaryDailyCapUsd,
        int summaryRetryCount)
    {
        return new MemoryExtractionSettingsSnapshot(
            ProviderOrder: LocalFirstProviderOrder(summaryProviderOrder),
            LocalBaseUrl: localBaseUrl,
            LocalModel: localModel,
            MlxBaseUrl: mlxBaseUrl,
            MlxModel: mlxModel,
            MiniMaxModel: miniMaxModel,
            OpenRouterPrimaryModel: openRouterPrimaryModel,
            OpenRouterFallbackModel: openRouterFallbackModel,
            ZaiModel: zaiModel,
            OllamaBaseUrl: ollamaBaseUrl,
            OllamaModel: ollamaModel,
            RequestTimeoutSeconds: EffectiveRequestTimeout(configuredRequestTimeoutSeconds),
            MaxPromptChars: MemoryExtractionPolicy.ClampedPromptChars(summaryMaxPromptChars),
            MaxOutputTokens: MemoryExtractionPolicy.ClampedOutputTokens(summaryMaxOutputTokens),
            DailyCapUsd: EffectiveDailyCapUsd(summaryDailyCapUsd),
            RetryCount: Math.Max(summaryRetryCount, 0),
            MaxCandidatesPerJob: MemoryExtractionPolicy.MaxCandidatesPerJob,
            PromptVersion: DefaultPromptVersion);
    }

    /// <summary>Keeps only on-device providers {Local, Mlx, Ollama} preserving order and deduped;
    /// forces [Local] when none survive. Swift: <c>localFirstProviderOrder(_:)</c>.</summary>
    public static IReadOnlyList<MemorySummaryProvider> LocalFirstProviderOrder(
        IReadOnlyList<MemorySummaryProvider> order)
    {
        ArgumentNullException.ThrowIfNull(order);
        var result = new List<MemorySummaryProvider>();
        var seen = new HashSet<MemorySummaryProvider>();
        foreach (var provider in order)
        {
            if (IsOnDevice(provider) && seen.Add(provider))
            {
                result.Add(provider);
            }
        }

        if (result.Count == 0)
        {
            result.Add(MemorySummaryProvider.Local);
        }

        return result;
    }

    /// <summary>configured &gt; 0 ? configured : 60. Swift: <c>effectiveRequestTimeout</c>.</summary>
    public static double EffectiveRequestTimeout(double configured) =>
        configured > 0 ? configured : MemoryExtractionPolicy.DefaultRequestTimeoutSeconds;

    /// <summary>nil → 0.50; ==0 → 0 (explicit no-spend); else min(cap, 0.50). Swift:
    /// <c>effectiveDailyCapUSD</c>.</summary>
    public static double EffectiveDailyCapUsd(double? summaryCap)
    {
        if (summaryCap is not double cap)
        {
            return MemoryExtractionPolicy.DefaultDailyCapUsd;
        }

        if (cap == 0)
        {
            return 0;
        }

        return Math.Min(cap, MemoryExtractionPolicy.DefaultDailyCapUsd);
    }

    private static bool IsOnDevice(MemorySummaryProvider provider) => provider switch
    {
        MemorySummaryProvider.Local => true,
        MemorySummaryProvider.Mlx => true,
        MemorySummaryProvider.Ollama => true,
        _ => false,
    };
}

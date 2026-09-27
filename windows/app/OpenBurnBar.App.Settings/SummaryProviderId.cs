// PORTED (portable, unit-tested) from:
//   AgentLens/Models/Settings/SummaryProviderID.swift
//   AgentLens/Services/Settings/Stores/SummarySettings.swift
//     (summaryProviderOrder parse + init-time default/clamp rules)
//
// Dependency-free (System-only). The summary provider order is a CSV of raw
// values; the parse is case-insensitive, dedupes (first wins), and appends any
// missing provider in allCases order so the result is always a complete
// permutation. An empty parse resolves to the default order.

using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Settings;

/// <summary>Summarization provider. Mirrors the macOS <c>SummaryProviderID</c>.</summary>
public enum SummaryProviderId
{
    Local,
    Mlx,
    MiniMax,
    OpenRouter,
    Zai,
    Ollama,
}

/// <summary>Metadata + order codec for <see cref="SummaryProviderId"/>, parity with Swift.</summary>
public static class SummaryProviderMetadata
{
    /// <summary>Swift default CSV (<c>summaryProviderOrderCSV</c> initial value).</summary>
    public const string DefaultCsv = "local,mlx,minimax,openrouter,zai,ollama";

    /// <summary>Swift default order (== declaration order).</summary>
    public static readonly SummaryProviderId[] DefaultOrder =
    {
        SummaryProviderId.Local,
        SummaryProviderId.Mlx,
        SummaryProviderId.MiniMax,
        SummaryProviderId.OpenRouter,
        SummaryProviderId.Zai,
        SummaryProviderId.Ollama,
    };

    /// <summary>The persisted raw value (Swift <c>rawValue</c>).</summary>
    public static string RawValue(this SummaryProviderId provider) => provider switch
    {
        SummaryProviderId.Local => "local",
        SummaryProviderId.Mlx => "mlx",
        SummaryProviderId.MiniMax => "minimax",
        SummaryProviderId.OpenRouter => "openrouter",
        SummaryProviderId.Zai => "zai",
        SummaryProviderId.Ollama => "ollama",
        _ => throw new ArgumentOutOfRangeException(nameof(provider), provider, null),
    };

    /// <summary>Parse a persisted raw value, or <c>null</c> if unknown. Swift:
    /// <c>SummaryProviderID(rawValue:)</c>.</summary>
    public static SummaryProviderId? FromRawValue(string? raw)
    {
        foreach (SummaryProviderId provider in Enum.GetValues(typeof(SummaryProviderId)))
        {
            if (string.Equals(provider.RawValue(), raw, StringComparison.Ordinal))
            {
                return provider;
            }
        }

        return null;
    }

    /// <summary>
    /// Swift <c>SummarySettings.summaryProviderOrder</c>: tokens are trimmed +
    /// lowercased, unknowns dropped; an empty parse resolves to
    /// <see cref="DefaultOrder"/>; otherwise the parse is deduped (first wins)
    /// and any missing providers are appended in <c>allCases</c> order.
    /// </summary>
    public static IReadOnlyList<SummaryProviderId> Parse(string csv)
    {
        SummaryProviderId[] parsed = csv
            .Split(',')
            .Select(part => part.Trim().ToLowerInvariant())
            .Select(FromRawValue)
            .Where(provider => provider is not null)
            .Select(provider => provider!.Value)
            .ToArray();
        if (parsed.Length == 0)
        {
            return DefaultOrder;
        }

        List<SummaryProviderId> deduped = parsed.Distinct().ToList();
        foreach (SummaryProviderId provider in Enum.GetValues(typeof(SummaryProviderId)))
        {
            if (!deduped.Contains(provider))
            {
                deduped.Add(provider);
            }
        }

        return deduped;
    }

    /// <summary>Swift <c>setSummaryProviderOrder(_:)</c> persistence shape.</summary>
    public static string Encode(IReadOnlyList<SummaryProviderId> order) =>
        string.Join(",", order.Select(provider => provider.RawValue()));
}

/// <summary>
/// Swift <c>SummarySettings.init</c> defaults + clamp rules for
/// already-persisted values. Each sanitizer takes the stored value (<c>null</c>
/// when the key was never persisted) and returns the effective value.
/// </summary>
public static class SummarySettingsDefaults
{
    public const bool AutoSessionSummariesEnabled = true;
    public const string OpenRouterPrimaryModel = "qwen/qwen3.5-9b";
    public const string OpenRouterFallbackModel = "openai/gpt-5-nano";
    public const string MiniMaxModel = "gpt-5.5";
    public const string ZaiModel = "glm-5-turbo";
    public const string OllamaModel = "llama3.2";
    public const string OllamaBaseUrl = "http://127.0.0.1:11434";
    public const string LocalModel = "qwen3.5:9b";
    public const string LocalBaseUrl = "http://127.0.0.1:11434";
    public const string MlxModel = "mlx-community/Qwen3-4B-4bit";
    public const string MlxBaseUrl = "http://127.0.0.1:8080";
    public const int MaxPromptChars = 60_000;
    public const int MaxOutputTokens = 280;
    public const int RetryCount = 1;
    public const int BatchSize = 25;
    public const int FirstLoadBatchSize = 120;
    public const double RequestTimeoutSeconds = 20;
    public const int MaxConcurrency = 8;
    public const int TimeLimitMinutes = 0;

    public static int SanitizeMaxPromptChars(int? stored) =>
        stored is null ? MaxPromptChars : (stored.Value >= 4_000 ? stored.Value : MaxPromptChars);

    public static int SanitizeMaxOutputTokens(int? stored) =>
        stored is null ? MaxOutputTokens : (stored.Value >= 120 ? stored.Value : MaxOutputTokens);

    public static int SanitizeRetryCount(int? stored) =>
        stored is null ? RetryCount : Math.Max(stored.Value, 0);

    public static int SanitizeBatchSize(int? stored) =>
        stored is null ? BatchSize : Math.Max(stored.Value, 1);

    public static int SanitizeFirstLoadBatchSize(int? stored) =>
        stored is null ? FirstLoadBatchSize : Math.Max(stored.Value, 1);

    public static double SanitizeRequestTimeoutSeconds(double? stored) =>
        stored is null ? RequestTimeoutSeconds : (stored.Value > 0 ? stored.Value : RequestTimeoutSeconds);

    public static int SanitizeMaxConcurrency(int? stored) =>
        stored is null ? MaxConcurrency : Math.Max(stored.Value, 1);

    public static int SanitizeTimeLimitMinutes(int? stored) =>
        stored is null ? TimeLimitMinutes : Math.Max(stored.Value, 0);
}

/// <summary>
/// Swift <c>ChatBackendSettings.init</c> endpoint + kill-switch defaults.
/// </summary>
public static class ChatBackendDefaults
{
    public const string OpenClawGatewayBaseUrl = "http://127.0.0.1:18789";
    public const string HermesGatewayBaseUrl = "http://127.0.0.1:8642";
    public const string PiAgentGatewayBaseUrl = "http://127.0.0.1:8765";

    /// <summary>Swift <c>HermesRealtimeRelayProtocol.defaultHostedRelayURLString</c> (unset).</summary>
    public const string RealtimeRelayUrl = "";
    public const bool MediaBlobTransferEnabled = true;
    public const bool ComputerUseKillSwitch = true;
    public const bool ComputerUsePhoneControlRespectsDenyRegions = true;
    public const bool MediaKillSwitch = true;
    public const bool WarRoomKillSwitch = true;
}

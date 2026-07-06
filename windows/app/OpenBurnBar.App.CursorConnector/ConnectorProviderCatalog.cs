using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.CursorConnector;

// ── Provider catalog ─────────────────────────────────────────────────────────
//
// Windows peer of the ConnectorProvider metadata + model-support heuristics in
// CursorConnectorModels.swift and CursorConnectorManager.swift. On the Mac the
// values come from the bundled BurnBarCatalog when present and fall back to the
// hard-coded literals below when it isn't. On Windows the bundled catalog is not
// wired into this portable layer, so the connector uses the FALLBACK path — which
// is exactly the deterministic, testable behaviour the Swift code applies when
// `OpenBurnBarConnectorCatalogLookup.isCatalogAvailable == false`.

/// <summary>Provider metadata + model-support parity helpers.</summary>
public static class ConnectorProviderCatalog
{
    /// <summary>Swift <c>fallbackDisplayName</c>.</summary>
    public static string DisplayName(ConnectorProvider provider) => provider switch
    {
        ConnectorProvider.Zai => "Z.ai",
        ConnectorProvider.Minimax => "MiniMax",
        ConnectorProvider.Ollama => "Ollama Cloud",
        _ => throw new ArgumentOutOfRangeException(nameof(provider)),
    };

    /// <summary>Swift <c>fallbackBaseURL</c>.</summary>
    public static string DefaultBaseURL(ConnectorProvider provider) => provider switch
    {
        ConnectorProvider.Zai => "https://api.z.ai/api/coding/paas/v4",
        ConnectorProvider.Minimax => "https://api.minimax.io/v1",
        ConnectorProvider.Ollama => "https://ollama.com/api",
        _ => throw new ArgumentOutOfRangeException(nameof(provider)),
    };

    /// <summary>Swift <c>fallbackSuggestedModels</c>.</summary>
    public static IReadOnlyList<string> SuggestedModels(ConnectorProvider provider) => provider switch
    {
        ConnectorProvider.Zai => new[] { "glm-5", "glm-5-turbo" },
        ConnectorProvider.Minimax => new[] { "MiniMax-M2.7-highspeed" },
        ConnectorProvider.Ollama => new[] { "deepseek-v4-flash", "gpt-oss:120b", "gpt-oss:20b" },
        _ => throw new ArgumentOutOfRangeException(nameof(provider)),
    };

    /// <summary>
    /// Swift <c>CursorConnectorManager.supportedModel(_:provider:)</c> fallback
    /// heuristics (catalog-unavailable branch).
    /// </summary>
    public static bool SupportedModel(string model, ConnectorProvider provider)
    {
        var normalized = model.Trim();
        if (normalized.Length == 0)
        {
            return false;
        }

        var lowercased = normalized.ToLowerInvariant();
        return provider switch
        {
            ConnectorProvider.Zai => lowercased.Contains("glm") || lowercased.Contains("z.ai"),
            ConnectorProvider.Minimax => lowercased.Contains("minimax"),
            ConnectorProvider.Ollama =>
                lowercased.Contains("ollama")
                || lowercased.Contains(":cloud")
                || lowercased.Contains("-cloud")
                || lowercased.Contains("gpt-oss")
                || lowercased.Contains("deepseek")
                || lowercased.Contains("qwen"),
            _ => false,
        };
    }

    /// <summary>
    /// Swift <c>CursorConnectorManager.supportedModel(_:)</c> — supported by any
    /// provider.
    /// </summary>
    public static bool SupportedModel(string model)
    {
        var normalized = model.Trim();
        if (normalized.Length == 0)
        {
            return false;
        }

        foreach (var provider in ConnectorProviderRawValue.AllCases)
        {
            if (SupportedModel(normalized, provider))
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>
    /// Swift <c>CursorConnectorManager.provider(forBaseURL:)</c> fallback mapping.
    /// </summary>
    public static ConnectorProvider? ProviderForBaseURL(string baseURL)
    {
        var normalized = baseURL.ToLowerInvariant();
        if (normalized.Contains("z.ai"))
        {
            return ConnectorProvider.Zai;
        }

        if (normalized.Contains("minimax"))
        {
            return ConnectorProvider.Minimax;
        }

        if (normalized.Contains("ollama")
            || normalized.Contains("localhost:11434")
            || normalized.Contains("127.0.0.1:11434"))
        {
            return ConnectorProvider.Ollama;
        }

        return null;
    }
}

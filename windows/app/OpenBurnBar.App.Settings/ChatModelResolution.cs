// PORTED (portable, unit-tested) from:
//   AgentLens/Services/SettingsManager.swift
//     SettingsManager.resolvedHermesChatModel(override:gatewayAdvertisedModel:)
//   AgentLens/Services/Settings/Stores/ChatBackendSettings.swift
//     ChatBackendSettings.resolvedPiChatModel(override:gatewayAdvertisedModel:)
//
// Dependency-free (System-only). The chat model override chain is pure string
// logic: explicit override wins, then the gateway-advertised model, then the
// backend fallback. Blank (after trimming) counts as absent on both inputs.

namespace OpenBurnBar.App.Settings;

/// <summary>Chat model override-chain resolution, parity with Swift.</summary>
public static class ChatModelResolution
{
    /// <summary>
    /// Swift <c>resolvedHermesChatModel</c>: explicit override wins, then the
    /// gateway-advertised model, then the <c>"hermes"</c> fallback.
    /// </summary>
    public static string ResolvedHermesChatModel(string @override, string? gatewayAdvertisedModel)
    {
        string trimmed = @override.Trim();
        if (trimmed.Length > 0)
        {
            return trimmed;
        }

        string? advertised = gatewayAdvertisedModel?.Trim();
        if (!string.IsNullOrEmpty(advertised))
        {
            return advertised!;
        }

        return "hermes";
    }

    /// <summary>
    /// Swift <c>resolvedPiChatModel</c>: same chain with the <c>"pi"</c> fallback.
    /// </summary>
    public static string ResolvedPiChatModel(string @override, string? gatewayAdvertisedModel)
    {
        string trimmed = @override.Trim();
        if (trimmed.Length > 0)
        {
            return trimmed;
        }

        string? advertised = gatewayAdvertisedModel?.Trim();
        if (!string.IsNullOrEmpty(advertised))
        {
            return advertised!;
        }

        return "pi";
    }
}

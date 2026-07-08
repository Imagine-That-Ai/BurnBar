// Parity source: AgentLens/Services/Cast/CastDiscovery.swift (inferSupportsDisplay)

using System;

namespace OpenBurnBar.Integrations.Cast.Discovery;

/// <summary>
/// Best-guess "this device can render web pages" heuristic. A device is marked
/// audio-only only when we are confident, because a false negative (a Nest Hub
/// hidden as a speaker) is far worse than a single <c>NOT_FOUND</c> retry on a
/// Mini. Byte-faithful port of Swift <c>inferSupportsDisplay</c>.
/// </summary>
public static class CastCapabilities
{
    /// <summary>The <c>ca</c> capability bit that means the device has video output.</summary>
    public const int VideoOutBit = 0x04;

    /// <summary>
    /// Signals, in priority order:
    /// <list type="number">
    ///   <item><c>ca</c> bit 0x04 (video_out) → definitively a display.</item>
    ///   <item>name/model contains hub/tv/display/chromecast → display.</item>
    ///   <item>name/model contains mini/audio/speaker/home-max → audio-only.</item>
    ///   <item>otherwise default to allowing the cast attempt.</item>
    /// </list>
    /// </summary>
    public static bool InferSupportsDisplay(int capabilityFlags, string model, string serviceName)
    {
        if ((capabilityFlags & VideoOutBit) != 0)
        {
            return true;
        }

        var combined = $"{model} {serviceName}".ToLowerInvariant();
        if (combined.Contains("hub", StringComparison.Ordinal)
            || combined.Contains("tv", StringComparison.Ordinal)
            || combined.Contains("display", StringComparison.Ordinal)
            || combined.Contains("chromecast", StringComparison.Ordinal))
        {
            return true;
        }

        if (combined.Contains("mini", StringComparison.Ordinal)
            || combined.Contains("audio", StringComparison.Ordinal)
            || combined.Contains("speaker", StringComparison.Ordinal)
            || combined.Contains("home-max", StringComparison.Ordinal))
        {
            return false;
        }

        return true; // unknown — let the user try
    }
}

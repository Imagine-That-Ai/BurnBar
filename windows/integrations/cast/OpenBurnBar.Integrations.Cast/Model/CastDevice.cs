// Parity source: AgentLens/Services/Cast/CastDevice.swift (struct CastDevice)

using System;

namespace OpenBurnBar.Integrations.Cast.Model;

/// <summary>
/// Icon-friendly bucket for a Cast device, collapsing model strings into a
/// small set of UI glyph categories. Port of Swift <c>CastDevice.IconKind</c>.
/// </summary>
public enum CastIconKind
{
    /// <summary>A Google Nest Hub (7").</summary>
    NestHub,

    /// <summary>A Google Nest Hub Max (10").</summary>
    NestHubMax,

    /// <summary>A Chromecast dongle / Chromecast with Google TV.</summary>
    Chromecast,

    /// <summary>An audio-only Nest speaker (Nest Mini / Nest Audio).</summary>
    NestSpeaker,

    /// <summary>Anything else that announces <c>_googlecast._tcp</c>.</summary>
    Generic,
}

/// <summary>
/// Concrete representation of a Cast-capable device discovered on the LAN.
/// Deduplicated on <see cref="ServiceName"/> (the mDNS instance name), which
/// survives IP changes. Port of Swift <c>CastDevice</c> (Hashable/Codable value
/// type) — modeled here as an immutable record with value equality.
/// </summary>
public sealed record CastDevice
{
    /// <summary>
    /// Stable mDNS service name, e.g.
    /// <c>Google-Nest-Hub-dec04a601c00269a3...</c>. Canonical identity; survives
    /// IP changes.
    /// </summary>
    public required string ServiceName { get; init; }

    /// <summary>Friendly name shown in the wizard UI ("Living Room Hub").</summary>
    public required string FriendlyName { get; init; }

    /// <summary>Last-known LAN IP; refreshed on every re-discovery (DHCP churn).</summary>
    public required string Host { get; init; }

    /// <summary>Cast TLS port — 8009 in practice, device-overridable by protocol.</summary>
    public required int Port { get; init; }

    /// <summary>Hardware model from the <c>md</c> TXT record.</summary>
    public required string Model { get; init; }

    /// <summary>The <c>id</c> TXT field — Google-assigned per-device UUID.</summary>
    public required string Identifier { get; init; }

    /// <summary>Last time discovery observed this device (UTC).</summary>
    public DateTimeOffset LastSeenAt { get; init; } = DateTimeOffset.UtcNow;

    /// <summary>
    /// Whether this device likely renders web content. Audio-only devices return
    /// <c>NOT_FOUND</c> when DashCast tries to launch; defaults to
    /// <see langword="true"/> so a false negative never silently hides a Hub.
    /// </summary>
    public bool SupportsDisplay { get; init; } = true;

    /// <summary>Convenience UI bucket — collapses the model string to an icon kind.</summary>
    public CastIconKind IconKind
    {
        get
        {
            var lower = Model.ToLowerInvariant();
            if (lower.Contains("nest hub max"))
            {
                return CastIconKind.NestHubMax;
            }

            if (lower.Contains("nest hub"))
            {
                return CastIconKind.NestHub;
            }

            if (lower.Contains("chromecast"))
            {
                return CastIconKind.Chromecast;
            }

            if (lower.Contains("nest mini") || lower.Contains("nest audio"))
            {
                return CastIconKind.NestSpeaker;
            }

            return CastIconKind.Generic;
        }
    }
}

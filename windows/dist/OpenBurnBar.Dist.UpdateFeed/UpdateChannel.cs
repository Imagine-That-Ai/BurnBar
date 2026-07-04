// Update delivery surface enums (Phase 5 · signed distribution).
//
// Pure (System only). Kept tiny + separate so the canonicalizer, verifier, feed parser,
// and tests share a single vocabulary for platform + channel.

namespace OpenBurnBar.Dist.UpdateFeed;

/// <summary>
/// The processor architecture / runtime-identifier family a Windows release artifact targets.
/// Mirrors the app csproj RuntimeIdentifiers (win-x86 / win-x64 / win-arm64).
/// </summary>
public enum UpdatePlatform
{
    /// <summary>win-x64.</summary>
    WinX64,

    /// <summary>win-arm64 (the free Win11-ARM CI leg + Copilot+ PCs).</summary>
    WinArm64,

    /// <summary>win-x86 (32-bit fallback).</summary>
    WinX86,
}

/// <summary>
/// The release channel a feed entry belongs to. The direct-download updater only ever
/// offers <see cref="Stable"/> to end users; <see cref="Beta"/> is opt-in.
/// </summary>
public enum UpdateChannel
{
    /// <summary>The public, default channel.</summary>
    Stable,

    /// <summary>Opt-in pre-release channel.</summary>
    Beta,
}

/// <summary>Canonical wire tokens for <see cref="UpdatePlatform"/> / <see cref="UpdateChannel"/>.
/// These strings are part of the SIGNED canonical descriptor, so they must never change
/// silently — a change is a signature-breaking format change (bump the schema version).</summary>
public static class UpdateEnumTokens
{
    /// <summary>Stable wire token for a platform. Throws on an undefined enum value
    /// (fail-closed: an unknown platform must never canonicalize to an empty/ambiguous token).</summary>
    public static string ToToken(this UpdatePlatform platform) => platform switch
    {
        UpdatePlatform.WinX64 => "win-x64",
        UpdatePlatform.WinArm64 => "win-arm64",
        UpdatePlatform.WinX86 => "win-x86",
        _ => throw new System.ArgumentOutOfRangeException(nameof(platform), platform, "Unknown update platform"),
    };

    /// <summary>Stable wire token for a channel. Throws on an undefined enum value.</summary>
    public static string ToToken(this UpdateChannel channel) => channel switch
    {
        UpdateChannel.Stable => "stable",
        UpdateChannel.Beta => "beta",
        _ => throw new System.ArgumentOutOfRangeException(nameof(channel), channel, "Unknown update channel"),
    };

    /// <summary>Parse a platform token. Returns false (fail-closed) on any unrecognized token.</summary>
    public static bool TryParsePlatform(string? token, out UpdatePlatform platform)
    {
        switch (token)
        {
            case "win-x64":
                platform = UpdatePlatform.WinX64;
                return true;
            case "win-arm64":
                platform = UpdatePlatform.WinArm64;
                return true;
            case "win-x86":
                platform = UpdatePlatform.WinX86;
                return true;
            default:
                platform = default;
                return false;
        }
    }

    /// <summary>Parse a channel token. Returns false (fail-closed) on any unrecognized token.</summary>
    public static bool TryParseChannel(string? token, out UpdateChannel channel)
    {
        switch (token)
        {
            case "stable":
                channel = UpdateChannel.Stable;
                return true;
            case "beta":
                channel = UpdateChannel.Beta;
                return true;
            default:
                channel = default;
                return false;
        }
    }
}

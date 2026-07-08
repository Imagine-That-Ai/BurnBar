// PORTED (hand-authored, parity-with-Swift) from:
//   AgentLens/Views/Components/UpdateBannerCard.swift
//     — UpdatePhase copy (title/subtitle/icon), isActionable, the offer-action set
//
// Pure, platform-agnostic (`System` only) so it compiles + runs on macOS and is asserted by
// windows/tests/components/UpdateBannerModelTests.cs. The WinUI control
// (Components/UpdateBannerCard) renders this state. The `DirectDownloadUpdateChecker`
// service that drives the phase is a Windows update-service follow-up (out of Bucket A);
// this models the PRESENTATION so all three surfaces (flyout/dashboard/settings) share copy.
//
// ── Accepted drift ─────────────────────────────────────────────────────────────
// macOS offers three channels: directDMG / homebrew / source. On Windows the analogous
// channels are Direct download (.msix/.exe) / winget / source — named per-platform here,
// same three-arm shape.

using System;

namespace OpenBurnBar.App.Components;

/// <summary>Lifecycle phase of the updater. Swift: <c>UpdatePhase</c>.</summary>
public enum UpdatePhaseKind
{
    Idle,
    Checking,
    UpToDate,
    Available,
    Downloading,
    Verifying,
    Installing,
    Relaunching,
    Failed,
}

/// <summary>Update delivery channel. Swift: <c>UpdateOffer</c> (directDMG/homebrew/source),
/// renamed to the Windows channels.</summary>
public enum UpdateOfferKind
{
    /// <summary>Direct download (.msix / .exe). Swift analog: <c>.directDMG</c>.</summary>
    DirectDownload,
    /// <summary>winget package manager. Swift analog: <c>.homebrew</c>.</summary>
    Winget,
    /// <summary>Build-from-source (git pull + rebuild). Swift: <c>.source</c>.</summary>
    Source,
}

/// <summary>
/// The presentational state of the update banner — the phase plus the optional per-phase
/// payload (offer channel, download progress, failure message, version pill text, commits-
/// behind count + default branch for the source channel). All copy resolvers below are a
/// faithful port of <c>UpdateBannerCard</c>'s Swift computed copy.
/// </summary>
public sealed record UpdateBannerState
{
    public UpdatePhaseKind Phase { get; init; } = UpdatePhaseKind.Idle;
    public UpdateOfferKind? Offer { get; init; }
    /// <summary>0…1 download progress; only meaningful for <see cref="UpdatePhaseKind.Downloading"/>.</summary>
    public double DownloadProgress { get; init; }
    public string? FailureMessage { get; init; }
    /// <summary>Version pill text, e.g. "v3.4.1". Swift: <c>offer.pillText</c>.</summary>
    public string? PillText { get; init; }
    /// <summary>Security-critical direct-download release. Swift: <c>release.critical</c>.</summary>
    public bool IsCritical { get; init; }
    /// <summary>For the source channel — commits behind + branch. Swift: <c>status.behindBy</c>.</summary>
    public int CommitsBehind { get; init; }
    public string DefaultBranch { get; init; } = "main";

    /// <summary>Whether the banner should render at all. Swift: <c>phase.isActionable</c> —
    /// actionable when there is something for the user to see or do.</summary>
    public bool IsActionable => Phase switch
    {
        UpdatePhaseKind.Idle or UpdatePhaseKind.Checking or UpdatePhaseKind.UpToDate => false,
        _ => true,
    };

    /// <summary>Header title. Swift: <c>UpdateBannerCard.title(for:channel:)</c>.</summary>
    public string Title => Phase switch
    {
        UpdatePhaseKind.Available => Offer == UpdateOfferKind.Source ? "New commits available" : "Update available",
        UpdatePhaseKind.Downloading => "Downloading update",
        UpdatePhaseKind.Verifying => "Verifying update",
        UpdatePhaseKind.Installing => "Installing update",
        UpdatePhaseKind.Relaunching => "Relaunching",
        UpdatePhaseKind.Failed => "Update didn't finish",
        _ => string.Empty,
    };

    /// <summary>Subtitle. Swift: <c>UpdateBannerCard.subtitle(for:channel:)</c> (only the
    /// <c>.available</c> phase carries one).</summary>
    public string? Subtitle
    {
        get
        {
            if (Phase != UpdatePhaseKind.Available || Offer is null)
            {
                return null;
            }

            return Offer switch
            {
                UpdateOfferKind.DirectDownload => IsCritical
                    ? "A security fix is ready. It'll be verified, installed, and relaunched for you."
                    : "A new version is ready. It'll be verified, installed, and relaunched for you.",
                UpdateOfferKind.Winget => "A newer version is available. Update it through winget.",
                UpdateOfferKind.Source => CommitsBehind == 1
                    ? $"Your build is 1 commit behind {DefaultBranch}."
                    : $"Your build is {CommitsBehind} commits behind {DefaultBranch}.",
                _ => null,
            };
        }
    }

    /// <summary>Combined accessibility label. Swift: <c>UpdateBannerCard.accessibilityLabel</c>.</summary>
    public string AccessibilityLabel => Subtitle is { Length: > 0 } s ? $"{Title}. {s}" : Title;

    /// <summary>Header Segoe glyph. Swift stand-in for <c>UpdateBannerCard.icon(for:)</c>.</summary>
    public string IconGlyph => Phase switch
    {
        UpdatePhaseKind.Failed => GlyphWarning,
        UpdatePhaseKind.Downloading => GlyphDownload,
        UpdatePhaseKind.Verifying => GlyphShield,
        UpdatePhaseKind.Installing or UpdatePhaseKind.Relaunching => GlyphSparkle,
        _ => GlyphDownload,
    };

    /// <summary>The indeterminate progress-phase label, or null. Swift: the
    /// <c>indeterminate(_:)</c> phases.</summary>
    public string? IndeterminateLabel => Phase switch
    {
        UpdatePhaseKind.Verifying => "Verifying signature…",
        UpdatePhaseKind.Installing => "Installing…",
        UpdatePhaseKind.Relaunching => "Relaunching…",
        _ => null,
    };

    // Segoe MDL2 Assets / Segoe Fluent Icons codepoints (confident).
    private const string GlyphWarning = "\uE7BA";  // Warning
    private const string GlyphDownload = "\uE896"; // Download
    private const string GlyphShield = "\uEA18";   // Shield / verified
    private const string GlyphSparkle = "\uE895";  // Sparkle / installed
}

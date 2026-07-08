// The Engine Room (Daemon) tab does NOT hide on Windows — it renders the WPD-0006
// per-capability substitution matrix (docs/windows-port/decisions/0006-windows-daemon-strategy.md).
//
// WPD-0006 decided Option 2: no monolithic daemon port for v1. Each macOS
// OpenBurnBarDaemon capability gets a per-capability Tier-C disposition. This file
// models one matrix row + its disposition vocabulary; DaemonSubstitutionMatrix.cs
// carries the 34 rows verbatim, and DaemonSettingsViewModel projects them for the tab.

namespace OpenBurnBar.App.Settings.ViewModels.Daemon;

/// <summary>
/// A daemon capability's Windows-v1 disposition (WPD-0006 "Dispositions" legend).
/// </summary>
public enum DaemonSubstitutionDisposition
{
    /// <summary>SUB-DONE — C#-substituted-already.</summary>
    SubstitutedAlready,

    /// <summary>SUB-BUILD — C#-substitute-to-build (wave named).</summary>
    SubstituteToBuild,

    /// <summary>DEFER — v1.1-deferred (named, with revive path).</summary>
    Deferred,

    /// <summary>N/A — not-applicable-on-Windows.</summary>
    NotApplicable,
}

/// <summary>Display + grouping metadata for <see cref="DaemonSubstitutionDisposition"/>.</summary>
public static class DaemonSubstitutionDispositionMetadata
{
    /// <summary>The short code exactly as WPD-0006 prints it (e.g. <c>SUB-DONE</c>).</summary>
    public static string Code(DaemonSubstitutionDisposition disposition) => disposition switch
    {
        DaemonSubstitutionDisposition.SubstitutedAlready => "SUB-DONE",
        DaemonSubstitutionDisposition.SubstituteToBuild => "SUB-BUILD",
        DaemonSubstitutionDisposition.Deferred => "DEFER",
        DaemonSubstitutionDisposition.NotApplicable => "N/A",
        _ => throw new ArgumentOutOfRangeException(nameof(disposition), disposition, null),
    };

    /// <summary>A one-line human label for the disposition.</summary>
    public static string Label(DaemonSubstitutionDisposition disposition) => disposition switch
    {
        DaemonSubstitutionDisposition.SubstitutedAlready => "Substituted already",
        DaemonSubstitutionDisposition.SubstituteToBuild => "Substitute to build",
        DaemonSubstitutionDisposition.Deferred => "Deferred to v1.1 (revive path named)",
        DaemonSubstitutionDisposition.NotApplicable => "Not applicable on Windows",
        _ => throw new ArgumentOutOfRangeException(nameof(disposition), disposition, null),
    };

    /// <summary>
    /// Whether the capability is available (or partly available) on Windows v1 today.
    /// SUB-DONE is live; every other disposition is not-yet or never for v1.
    /// </summary>
    public static bool IsLiveOnV1(DaemonSubstitutionDisposition disposition) =>
        disposition == DaemonSubstitutionDisposition.SubstitutedAlready;
}

/// <summary>
/// One row of the WPD-0006 capability matrix: a daemon duty and its Windows-v1
/// disposition. <see cref="RemainderDisposition"/> captures the hybrid rows (24, 27)
/// whose core is SUB-DONE with a named SUB-BUILD remainder; <see cref="Qualifier"/>
/// carries the parenthetical scope note WPD-0006 prints next to the disposition
/// (e.g. "transport primitive", "seam", "app-scoped", "SWIFT-REUSE on revive").
/// </summary>
public sealed record DaemonSubstitutionRow(
    int Number,
    string Capability,
    DaemonSubstitutionDisposition Disposition,
    string Rationale,
    string Tracking,
    DaemonSubstitutionDisposition? RemainderDisposition = null,
    string? Qualifier = null)
{
    /// <summary>The primary disposition's short code (e.g. <c>SUB-DONE</c>).</summary>
    public string DispositionCode => DaemonSubstitutionDispositionMetadata.Code(Disposition);

    /// <summary>
    /// The disposition badge as WPD-0006 renders it — primary code, an optional
    /// parenthetical qualifier, and, for hybrid rows, the SUB-BUILD remainder.
    /// e.g. <c>SUB-DONE (core) / SUB-BUILD (full loop)</c> style becomes
    /// <c>SUB-DONE (core) / SUB-BUILD</c>.
    /// </summary>
    public string DispositionBadge
    {
        get
        {
            var primary = Qualifier is null ? DispositionCode : $"{DispositionCode} ({Qualifier})";
            return RemainderDisposition is { } remainder
                ? $"{primary} / {DaemonSubstitutionDispositionMetadata.Code(remainder)}"
                : primary;
        }
    }

    /// <summary>Whether this capability is live (or partly live) on Windows v1 today.</summary>
    public bool IsLiveOnV1 => DaemonSubstitutionDispositionMetadata.IsLiveOnV1(Disposition);
}

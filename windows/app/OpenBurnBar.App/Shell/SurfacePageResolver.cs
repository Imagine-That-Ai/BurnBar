using System;

namespace OpenBurnBar.App.Shell;

/// <summary>
/// Maps a <see cref="NavDestination.Key"/> to the real <c>Page</c> type that renders it,
/// defaulting to the placeholder <see cref="SurfaceStubPage"/> for surfaces not yet ported.
/// This is the seam the Phase-3 surface lanes plug their pages into as they replace the stubs
/// one destination at a time; <see cref="AppShell"/> routes the content Frame through it.
/// </summary>
public static class SurfacePageResolver
{
    /// <summary>The real page type for a destination key, or the stub when none is registered.</summary>
    public static Type Resolve(string key) => key switch
    {
        "budget" => typeof(OpenBurnBar.App.Budget.BudgetPage),
        _ => typeof(SurfaceStubPage),
    };
}

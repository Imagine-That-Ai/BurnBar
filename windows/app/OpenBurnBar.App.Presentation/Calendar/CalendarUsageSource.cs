using System;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.Dashboard;

namespace OpenBurnBar.App.Presentation.Calendar;

/// <summary>
/// Resolves the Calendar surface's usage rows preferring signal over samples —
/// the direct analog of <see cref="DashboardUsageSummarySource"/> (itself the
/// <c>QuotaAccountsSource</c> analog):
/// <list type="number">
///   <item>LIVE local SQLCipher <c>token_usage</c> rows in the grid window (on-device, highest signal);</item>
///   <item>the signed-in cloud usage feed (<c>users/{uid}/usage</c>) when local has no rows;</item>
///   <item>an explicitly enabled, labeled sample (<c>OPENBURNBAR_SAMPLE_MODE</c>);</item>
///   <item>an honest empty (fail-closed) state.</item>
/// </list>
/// Pure + fully injectable so the whole precedence ladder — including "cloud is
/// not consulted when local already has data" and "fail-closed when signed out" —
/// is unit-tested on the authoring host with no WinUI or live network. Typed
/// loader failures (corrupt storage, auth) propagate; they are never converted
/// to a legitimate empty result.
/// </summary>
public static class CalendarUsageSource
{
    /// <param name="loadLocal">Reads the local SQLCipher rows for the window (never null result).</param>
    /// <param name="loadCloud">
    /// Reads the signed-in cloud usage rows, or <c>null</c> when signed out / not configured.
    /// A <c>null</c> delegate OR a <c>null</c>/no-data result both mean "no cloud data" (fail-closed).
    /// </param>
    /// <param name="sample">Produces the labeled demo rows; only used when sample mode is on.</param>
    /// <param name="sampleModeEnabled">Whether <c>OPENBURNBAR_SAMPLE_MODE</c> is set.</param>
    public static async Task<CalendarUsageData> ResolveAsync(
        Func<CalendarUsageData> loadLocal,
        Func<CancellationToken, Task<CalendarUsageData?>>? loadCloud = null,
        Func<CalendarUsageData>? sample = null,
        bool sampleModeEnabled = false,
        CancellationToken cancellationToken = default)
    {
        if (loadLocal is null)
        {
            throw new ArgumentNullException(nameof(loadLocal));
        }

        CalendarUsageData local = loadLocal();
        if (local.HasData)
        {
            return local with { Origin = DashboardUsageOrigin.Local };
        }

        if (loadCloud is not null)
        {
            CalendarUsageData? cloud = await loadCloud(cancellationToken).ConfigureAwait(false);
            if (cloud is { HasData: true })
            {
                return cloud with { Origin = DashboardUsageOrigin.Cloud };
            }
        }

        if (sampleModeEnabled && sample is not null)
        {
            return sample() with { Origin = DashboardUsageOrigin.Sample };
        }

        return CalendarUsageData.Empty;
    }
}

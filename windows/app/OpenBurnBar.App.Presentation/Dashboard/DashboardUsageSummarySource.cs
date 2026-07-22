using System;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.Presentation.Dashboard;

/// <summary>
/// Resolves the Dashboard headline usage summary preferring signal over samples, the
/// direct analog of the Quota surface's <c>QuotaAccountsSource</c>:
/// <list type="number">
///   <item>LIVE local SQLCipher <c>token_usage</c> aggregates (on-device, highest signal);</item>
///   <item>the signed-in cloud usage feed (<c>users/{uid}/usage</c>) when local has no rows;</item>
///   <item>an explicitly enabled, labeled sample (<c>OPENBURNBAR_SAMPLE_MODE</c>);</item>
///   <item>an honest empty (fail-closed) state.</item>
/// </list>
/// Pure + fully injectable so the whole precedence ladder — including "cloud is not
/// consulted when local already has data" and "fail-closed when signed out" — is
/// unit-tested on macOS with no WinUI or live network.
/// </summary>
public static class DashboardUsageSummarySource
{
    /// <param name="loadLocal">Reads the local SQLCipher summary (never null result).</param>
    /// <param name="loadCloud">
    /// Reads the signed-in cloud usage summary, or <c>null</c> when signed out / not configured.
    /// A <c>null</c> delegate OR a <c>null</c>/no-data result both mean "no cloud data" (fail-closed).
    /// </param>
    /// <param name="sample">Produces the labeled demo summary; only used when sample mode is on.</param>
    /// <param name="sampleModeEnabled">Whether <c>OPENBURNBAR_SAMPLE_MODE</c> is set.</param>
    public static async Task<DashboardUsageSummary> ResolveAsync(
        Func<DashboardUsageSummary> loadLocal,
        Func<CancellationToken, Task<DashboardUsageSummary?>>? loadCloud = null,
        Func<DashboardUsageSummary>? sample = null,
        bool sampleModeEnabled = false,
        CancellationToken cancellationToken = default)
    {
        if (loadLocal is null)
        {
            throw new ArgumentNullException(nameof(loadLocal));
        }

        DashboardUsageSummary local = loadLocal();
        if (local.HasData)
        {
            return local with { Origin = DashboardUsageOrigin.Local };
        }

        if (loadCloud is not null)
        {
            DashboardUsageSummary? cloud = await loadCloud(cancellationToken).ConfigureAwait(false);
            if (cloud is { HasData: true })
            {
                return cloud with { Origin = DashboardUsageOrigin.Cloud };
            }
        }

        if (sampleModeEnabled && sample is not null)
        {
            return sample() with { Origin = DashboardUsageOrigin.Sample };
        }

        return new DashboardUsageSummary(
            0,
            0,
            0,
            false,
            DashboardUsageOrigin.Empty,
            local.Window);
    }
}

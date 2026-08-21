using System;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.CloudSync;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Presentation.Dashboard;
using OpenBurnBar.App.Settings.Winui;
using OpenBurnBar.App.Settings.ViewModels;

namespace OpenBurnBar.App.Dashboard;

/// <summary>
/// Composition root for the Dashboard headline summary. Prefers LIVE local SQLCipher
/// <c>token_usage</c>, then the signed-in cloud usage feed (<c>users/{uid}/usage</c> via
/// the OAuth-backed gateway on <see cref="WinAppCloudSyncHost.Root"/> — the payoff of the
/// #1304 credential gate), then a labeled sample, then an honest empty state. This is the
/// direct analog of <c>QuotaAccountsSource</c>. The pure precedence ladder lives in
/// <see cref="DashboardUsageSummarySource"/> (unit-tested on macOS); this thin Windows
/// composition binds the real seams together.
/// </summary>
internal static class DashboardUsageProvider
{
    public static event EventHandler? Changed;

    public static void NotifyChanged() => Changed?.Invoke(null, EventArgs.Empty);

    public static Task<DashboardUsageSummary> LoadAsync(CancellationToken cancellationToken = default)
    {
        GeneralSettingsSnapshot settings = WindowsGeneralSettingsComposition.Load();
        DashboardUsageWindow window = WindowsGeneralSettingsComposition.DashboardWindow(settings.TimeRange);
        return DashboardUsageSummarySource.ResolveAsync(
            loadLocal: () => OpenBurnBar.App.Storage.WindowsStorageDevHost.LoadDashboardUsageSummary(window),
            loadCloud: token => LoadCloudAsync(window, token),
            sample: () => DashboardUsageSampleData.Summary() with { Window = window },
            sampleModeEnabled: RuntimeDataMode.SampleModeEnabled,
            cancellationToken: cancellationToken);
    }

    /// <summary>
    /// Synchronous convenience for XAML <c>Loaded</c> handlers and the Insights
    /// <c>Lazy&lt;DashboardUsageSummary&gt;</c> resolver that cannot await.
    /// </summary>
    public static DashboardUsageSummary Load() => LoadAsync().GetAwaiter().GetResult();

    private static async Task<DashboardUsageSummary?> LoadCloudAsync(
        DashboardUsageWindow window,
        CancellationToken cancellationToken)
    {
        CloudSyncCompositionRoot? root = WinAppCloudSyncHost.Root;
        if (root is null || string.IsNullOrWhiteSpace(root.FirebaseUid))
        {
            // Signed out / not configured: no cloud delegate result — the resolver falls
            // through to sample (if enabled) or the honest empty state (fail-closed).
            return null;
        }

        try
        {
            var store = new CloudSyncUsageSummaryStore(root.Gateway, root.FirebaseUid);
            return await store.LoadSummaryAsync(window, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            OpenBurnBar.App.Diagnostics.AppDiagnostics.LogException("dashboard.cloud-usage", ex);
            return null;
        }
    }
}

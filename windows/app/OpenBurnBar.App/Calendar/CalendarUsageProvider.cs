using System;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.CloudSync;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Presentation.Calendar;

namespace OpenBurnBar.App.Calendar;

/// <summary>
/// Composition root for the Calendar surface's usage rows. Prefers LIVE local
/// SQLCipher <c>token_usage</c> rows in the visible grid window, then the
/// signed-in cloud usage feed (<c>users/{uid}/usage</c> via the OAuth-backed
/// gateway on <see cref="WinAppCloudSyncHost.Root"/>), then a labeled sample,
/// then an honest empty state — the direct analog of
/// <c>DashboardUsageProvider</c>. The pure precedence ladder lives in
/// <see cref="CalendarUsageSource"/> (unit-tested on macOS); this thin Windows
/// composition binds the real seams together. Typed storage/cloud failures are
/// logged or propagated, never converted to a legitimate empty dataset.
/// </summary>
internal static class CalendarUsageProvider
{
    /// <summary>
    /// Loads the rows for the grid window <paramref name="gridStartUtc"/> (inclusive)
    /// … <paramref name="gridEndUtcExclusive"/>; the sample tier covers
    /// <paramref name="visibleMonth"/> (local month the user is looking at).
    /// </summary>
    public static Task<CalendarUsageData> LoadAsync(
        DateTimeOffset gridStartUtc,
        DateTimeOffset gridEndUtcExclusive,
        DateOnly visibleMonth,
        CancellationToken cancellationToken = default)
    {
        TimeZoneInfo local = TimeZoneInfo.Local;
        return CalendarUsageSource.ResolveAsync(
            loadLocal: () => OpenBurnBar.App.Storage.WindowsStorageDevHost.LoadCalendarUsageRows(
                gridStartUtc,
                gridEndUtcExclusive),
            loadCloud: token => LoadCloudAsync(gridStartUtc, gridEndUtcExclusive, token),
            sample: () => CalendarUsageSampleData.Rows(visibleMonth, DateTimeOffset.UtcNow, local),
            sampleModeEnabled: RuntimeDataMode.SampleModeEnabled,
            cancellationToken: cancellationToken);
    }

    private static async Task<CalendarUsageData?> LoadCloudAsync(
        DateTimeOffset gridStartUtc,
        DateTimeOffset gridEndUtcExclusive,
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
            var store = new CloudSyncCalendarUsageStore(root.Gateway, root.FirebaseUid);
            return await store
                .LoadRowsAsync(gridStartUtc, gridEndUtcExclusive, cancellationToken)
                .ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            OpenBurnBar.App.Diagnostics.AppDiagnostics.LogException("calendar.cloud-usage", ex);
            return null;
        }
    }
}

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Diagnostics;
using OpenBurnBar.App.Presentation.Dashboard;
using OpenBurnBar.App.Presentation.Flyout;
using OpenBurnBar.App.UsageRuntime;
using OpenBurnBar.Storage;

namespace OpenBurnBar.App.Storage;

/// <summary>Process composition root for live Windows provider-log ingestion.</summary>
internal static class WindowsUsageRuntimeHost
{
    private static readonly object Gate = new();
    private static IWindowsUsageRuntime? _runtime;

    public static event EventHandler<TokenUsageAggregateSnapshot>? SnapshotChanged;
    public static event EventHandler<UsageRuntimeStatus>? StatusChanged;

    public static TokenUsageAggregateSnapshot Snapshot =>
        _runtime?.Snapshot ?? TokenUsageAggregateSnapshot.Empty;

    public static UsageRuntimeStatus Status =>
        _runtime?.Status ?? new UsageRuntimeStatus(UsageRuntimePhase.NotStarted, "Usage runtime has not started.");

    public static async Task StartAsync(CancellationToken cancellationToken = default)
    {
        IWindowsUsageRuntime runtime;
        lock (Gate)
        {
            if (_runtime is not null)
            {
                return;
            }

            var (databasePath, passphrase) = WindowsStorageDevHost.ResolveCredentials();
            string profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            string appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            runtime = new WindowsUsageRuntime(
                new WindowsUsageLogDiscovery(profile, appData),
                new JsonlUsageLogParser(),
                new SqlCipherUsageRuntimeStore(databasePath!, passphrase!));
            runtime.SnapshotChanged += OnSnapshotChanged;
            runtime.StatusChanged += OnStatusChanged;
            _runtime = runtime;
        }

        try
        {
            await runtime.StartAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch (Exception ex)
        {
            AppDiagnostics.LogException("usage-runtime.start", ex);
        }
    }

    public static async Task<UsageScanResult?> ScanAsync(CancellationToken cancellationToken = default)
    {
        IWindowsUsageRuntime? runtime = _runtime;
        if (runtime is null)
        {
            await StartAsync(cancellationToken).ConfigureAwait(false);
            runtime = _runtime;
        }
        return runtime is null ? null : await runtime.ScanAsync(cancellationToken).ConfigureAwait(false);
    }

    public static async Task StopAsync()
    {
        IWindowsUsageRuntime? runtime;
        lock (Gate)
        {
            runtime = _runtime;
            _runtime = null;
        }
        if (runtime is null) return;
        runtime.SnapshotChanged -= OnSnapshotChanged;
        runtime.StatusChanged -= OnStatusChanged;
        await runtime.DisposeAsync().ConfigureAwait(false);
    }

    public static DashboardCommandSnapshot DashboardSnapshot()
    {
        TokenUsageAggregateSnapshot snapshot = Snapshot;
        if (!snapshot.HasData) return DashboardCommandSnapshot.Empty;
        DashboardProviderSidebarRow[] providers = snapshot.Providers.Select(provider =>
            new DashboardProviderSidebarRow(
                provider.Id,
                provider.DisplayName,
                provider.CostUsd,
                provider.TotalTokens,
                provider.SessionCount,
                Metric(provider.CostUsd, provider.TotalTokens))).ToArray();
        DashboardModelSidebarRow[] models = snapshot.Models.Select(model =>
            new DashboardModelSidebarRow(
                model.Id,
                model.DisplayName,
                model.ProviderId,
                model.CostUsd,
                model.TotalTokens,
                model.SessionCount,
                Metric(model.CostUsd, model.TotalTokens))).ToArray();
        return new DashboardCommandSnapshot(
            snapshot.MonthCostUsd,
            snapshot.TotalTokens,
            snapshot.SessionCount,
            Metric(snapshot.MonthCostUsd, snapshot.TotalTokens),
            "This month",
            providers.Length,
            providers,
            models,
            DashboardUsageOrigin.Local);
    }

    public static FlyoutTraySnapshot FlyoutSnapshot()
    {
        TokenUsageAggregateSnapshot snapshot = Snapshot;
        if (!snapshot.HasData)
        {
            return FlyoutTraySnapshot.Empty with { FreshnessLabel = Status.Message };
        }
        DashboardCommandSnapshot dashboard = DashboardSnapshot();
        var insights = new List<FlyoutInsightCard>();
        if (dashboard.Providers.FirstOrDefault() is { } top)
        {
            insights.Add(new FlyoutInsightCard(
                $"{top.DisplayName} leads this window",
                $"{top.SessionCount} sessions and {FormatTokens(top.TotalTokens)} tokens.",
                "neutral"));
        }
        if (Status.FailedFiles > 0)
        {
            insights.Add(new FlyoutInsightCard(
                "Some logs need attention",
                $"{Status.FailedFiles} provider logs could not be read. Scan again after checking access.",
                "warning"));
        }
        return new FlyoutTraySnapshot(
            Metric(snapshot.TodayCostUsd, snapshot.TotalTokens),
            Metric(snapshot.WeekCostUsd, snapshot.TotalTokens),
            Metric(snapshot.MonthCostUsd, snapshot.TotalTokens),
            snapshot.SessionCount,
            Freshness(snapshot.LastActivityAt),
            snapshot.DailyCostSeries,
            dashboard.Providers,
            insights,
            DashboardUsageOrigin.Local);
    }

    private static void OnSnapshotChanged(object? sender, TokenUsageAggregateSnapshot snapshot) =>
        SnapshotChanged?.Invoke(sender, snapshot);

    private static void OnStatusChanged(object? sender, UsageRuntimeStatus status)
    {
        AppDiagnostics.LogEvent("usage-runtime.status", $"{status.Phase}: {status.Message}");
        StatusChanged?.Invoke(sender, status);
    }

    private static string Metric(double cost, long tokens) =>
        cost > 0 ? $"${cost:0.##}" : FormatTokens(tokens) + " tokens";

    private static string FormatTokens(long value) => value switch
    {
        >= 1_000_000 => (value / 1_000_000d).ToString("0.#M", CultureInfo.InvariantCulture),
        >= 1_000 => (value / 1_000d).ToString("0.#K", CultureInfo.InvariantCulture),
        _ => value.ToString(CultureInfo.InvariantCulture),
    };

    private static string Freshness(DateTimeOffset? at)
    {
        if (at is null) return "No activity yet";
        TimeSpan age = DateTimeOffset.UtcNow - at.Value.ToUniversalTime();
        if (age < TimeSpan.Zero || age < TimeSpan.FromMinutes(1)) return "Updated just now";
        if (age < TimeSpan.FromHours(1)) return $"Updated {(int)age.TotalMinutes}m ago";
        if (age < TimeSpan.FromDays(1)) return $"Updated {(int)age.TotalHours}h ago";
        return $"Updated {(int)age.TotalDays}d ago";
    }
}

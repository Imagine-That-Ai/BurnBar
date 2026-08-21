using System;
using System.Threading.Tasks;
using Microsoft.UI.Xaml.Controls;

namespace OpenBurnBar.App.Dashboard.Layouts;

/// <summary>
/// The refresh lifecycle every dashboard layout concept shares: load once when the
/// control is shown, follow <see cref="DashboardUsageProvider.Changed"/> for as long
/// as it stays loaded, and unsubscribe on unload so a swapped-out layout stops
/// touching the dispatcher.
/// </summary>
/// <remarks>
/// Layouts differ only in what they render, never in how they subscribe, so the
/// wiring lives here rather than being hand-rolled once per concept — one place to
/// fix if the unsubscribe is ever dropped, and nothing for a ninth layout to forget.
/// </remarks>
internal static class DashboardLayoutRefresh
{
    /// <summary>Bind <paramref name="refreshAsync"/> to <paramref name="view"/>'s load lifecycle.</summary>
    public static void BindUsageRefresh(this UserControl view, Func<Task> refreshAsync)
    {
        void OnUsageChanged(object? sender, EventArgs e) =>
            view.DispatcherQueue.TryEnqueue(() => _ = refreshAsync());

        view.Loaded += (_, _) =>
        {
            DashboardUsageProvider.Changed += OnUsageChanged;
            _ = refreshAsync();
        };

        view.Unloaded += (_, _) => DashboardUsageProvider.Changed -= OnUsageChanged;
    }
}

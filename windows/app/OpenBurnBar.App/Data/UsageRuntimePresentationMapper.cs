using System;
using OpenBurnBar.App.Presentation.Dashboard;
using OpenBurnBar.App.Presentation.Flyout;
using OpenBurnBar.App.Settings.Winui;
using OpenBurnBar.App.Settings.ViewModels;
using OpenBurnBar.App.UsageRuntime;

namespace OpenBurnBar.App.Data;

/// <summary>Adapts persisted WinUI settings to the portable usage projection.</summary>
internal static class UsageRuntimePresentationMapper
{
    public static FlyoutTraySnapshot ToFlyoutSnapshot(
        UsageRuntimeState state,
        GeneralSettingsSnapshot settings,
        DateTimeOffset? nowOverride = null) => UsageRuntimePresentationProjection.ToFlyoutSnapshot(
            state,
            WindowsGeneralSettingsComposition.DashboardWindow(settings.TimeRange),
            settings.UsageDisplayMode == GeneralUsageDisplayMode.Tokens,
            nowOverride);

    public static DashboardCommandSnapshot ToDashboardCommandSnapshot(
        UsageRuntimeState state,
        GeneralSettingsSnapshot settings,
        DateTimeOffset? nowOverride = null) => UsageRuntimePresentationProjection.ToDashboardCommandSnapshot(
            state,
            WindowsGeneralSettingsComposition.DashboardWindow(settings.TimeRange),
            settings.UsageDisplayMode == GeneralUsageDisplayMode.Tokens,
            nowOverride);
}

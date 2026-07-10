// The portable source of truth for "which Settings tab now resolves to a real, testable
// view-model" — the seam the WinUI SettingsPage consults instead of falling every tab
// through to SettingsPlaceholderPage.
//
// The macOS app has 16 settings tabs. On Windows, General / Updates / Data & Privacy
// (+ Appearance) already resolved to real leaf pages. This wave adds portable view-models
// for the placeholder tabs whose feature cores exist on main. The WinUI XAML leaf pages that x:Bind these view-models
// are bucket-B / dev-host-deferred; this catalog + the view-models + the manifest search
// coverage are the real, tested deliverable.

using System;
using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.Settings;
using OpenBurnBar.App.Settings.ViewModels.Agents;
using OpenBurnBar.App.Settings.ViewModels.Daemon;

namespace OpenBurnBar.App.Settings.ViewModels;

/// <summary>Whether a tab's view-model is live on v1 or waiting on data/OAuth (Wave 2).</summary>
public enum SettingsTabViewModelGating
{
    /// <summary>Fully live on Windows v1 (its feature core is substituted).</summary>
    Live,

    /// <summary>Real view-model, but its live data is OAuth/Wave-2 gated (a fake state drives tests).</summary>
    DataGated,
}

/// <summary>Describes the portable view-model that backs a settings tab.</summary>
public sealed record SettingsTabViewModelDescriptor(
    SettingsTab Tab,
    SettingsTabViewModelGating Gating,
    string ViewModelName,
    string MacOsOracle);

/// <summary>Maps a <see cref="SettingsTab"/> to the portable view-model this wave made real.</summary>
public static class SettingsTabViewModelCatalog
{
    private static readonly IReadOnlyList<SettingsTabViewModelDescriptor> AllDescriptors = new[]
    {
        new SettingsTabViewModelDescriptor(SettingsTab.Daemon, SettingsTabViewModelGating.Live,
            nameof(DaemonSettingsViewModel), "DaemonSettingsView.swift + WPD-0006"),
        new SettingsTabViewModelDescriptor(SettingsTab.Agents, SettingsTabViewModelGating.Live,
            nameof(AgentsSettingsViewModel), "AgentsSettingsView.swift"),
        new SettingsTabViewModelDescriptor(SettingsTab.ModelProxy, SettingsTabViewModelGating.Live,
            nameof(ModelProxySettingsViewModel), "ModelProxySettingsView.swift"),
        new SettingsTabViewModelDescriptor(SettingsTab.Alerts, SettingsTabViewModelGating.Live,
            nameof(AlertsSettingsViewModel), "AlertsAndNotificationsViews.swift"),
        new SettingsTabViewModelDescriptor(SettingsTab.Notifications, SettingsTabViewModelGating.Live,
            nameof(NotificationsSettingsViewModel), "AlertsAndNotificationsViews.swift"),
        new SettingsTabViewModelDescriptor(SettingsTab.TextExpansion, SettingsTabViewModelGating.Live,
            nameof(TextExpansionSettingsViewModel), "TextExpansionSettingsView.swift"),
        new SettingsTabViewModelDescriptor(SettingsTab.ComputerUse, SettingsTabViewModelGating.Live,
            nameof(ComputerUseSettingsViewModel), "ComputerUseSettingsView.swift"),
        new SettingsTabViewModelDescriptor(SettingsTab.Media, SettingsTabViewModelGating.Live,
            nameof(MediaSettingsViewModel), "MediaSettingsView.swift + Mercury file-transfer safety"),
        new SettingsTabViewModelDescriptor(SettingsTab.Pets, SettingsTabViewModelGating.Live,
            nameof(PetsSettingsViewModel), "SettingsView.swift (PetCompanionSettingsView)"),
        new SettingsTabViewModelDescriptor(SettingsTab.Account, SettingsTabViewModelGating.DataGated,
            nameof(AccountSettingsViewModel), "AccountSettingsView.swift"),
        new SettingsTabViewModelDescriptor(SettingsTab.Cloud, SettingsTabViewModelGating.DataGated,
            nameof(CloudSettingsViewModel), "CloudStoreSettingsView.swift"),
        new SettingsTabViewModelDescriptor(SettingsTab.DevicesAndSync, SettingsTabViewModelGating.DataGated,
            nameof(DevicesAndSyncSettingsViewModel), "DevicesAndSyncSettingsView.swift"),
    };

    /// <summary>Every tab this wave gives a portable view-model, in a stable order.</summary>
    public static IReadOnlyList<SettingsTabViewModelDescriptor> Descriptors => AllDescriptors;

    /// <summary>The set of tabs that now resolve to a real view-model.</summary>
    public static IReadOnlyCollection<SettingsTab> RealViewModelTabs { get; } =
        AllDescriptors.Select(d => d.Tab).ToHashSet();

    /// <summary>Tabs whose view-model is live on v1 (feature core substituted).</summary>
    public static IReadOnlyCollection<SettingsTab> LiveTabs { get; } =
        AllDescriptors.Where(d => d.Gating == SettingsTabViewModelGating.Live).Select(d => d.Tab).ToHashSet();

    /// <summary>Tabs whose view-model is real but data-gated on Wave-2 / OAuth.</summary>
    public static IReadOnlyCollection<SettingsTab> DataGatedTabs { get; } =
        AllDescriptors.Where(d => d.Gating == SettingsTabViewModelGating.DataGated).Select(d => d.Tab).ToHashSet();

    /// <summary>Whether <paramref name="tab"/> resolves to a real view-model.</summary>
    public static bool HasRealViewModel(SettingsTab tab) => RealViewModelTabs.Contains(tab);

    /// <summary>The descriptor for <paramref name="tab"/>, or null if it is still a placeholder.</summary>
    public static SettingsTabViewModelDescriptor? Descriptor(SettingsTab tab) =>
        AllDescriptors.FirstOrDefault(d => d.Tab == tab);

    /// <summary>
    /// Construct a sample view-model for <paramref name="tab"/> wired with in-memory fakes.
    /// Lets the WinUI shell (and coverage tests) obtain a real, bindable instance without
    /// the OS/data seams. Throws for a tab with no portable view-model.
    /// </summary>
    public static object CreateSample(SettingsTab tab) => tab switch
    {
        SettingsTab.Daemon => new DaemonSettingsViewModel(),
        SettingsTab.Agents => new AgentsSettingsViewModel(),
        SettingsTab.ModelProxy => new ModelProxySettingsViewModel(),
        SettingsTab.Alerts => new AlertsSettingsViewModel(),
        SettingsTab.Notifications => new NotificationsSettingsViewModel(),
        SettingsTab.TextExpansion => new TextExpansionSettingsViewModel(),
        SettingsTab.ComputerUse => new ComputerUseSettingsViewModel(),
        SettingsTab.Media => new MediaSettingsViewModel(),
        SettingsTab.Pets => new PetsSettingsViewModel(),
        SettingsTab.Account => new AccountSettingsViewModel(),
        SettingsTab.Cloud => new CloudSettingsViewModel(),
        SettingsTab.DevicesAndSync => new DevicesAndSyncSettingsViewModel(),
        _ => throw new ArgumentOutOfRangeException(nameof(tab), tab, "No portable view-model for this tab."),
    };
}

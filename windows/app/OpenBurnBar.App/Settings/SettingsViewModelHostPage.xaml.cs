using System;
using System.Collections.Generic;
using System.Linq;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using OpenBurnBar.App.Settings;
using OpenBurnBar.App.Settings.ViewModels;
using OpenBurnBar.App.Settings.ViewModels.Daemon;

namespace OpenBurnBar.App.Settings.Winui;

/// <summary>
/// Production settings leaf for every tab with a portable view-model catalog entry.
/// Replaces empty-leaf fallthrough for S1/S2 tabs.
/// </summary>
public sealed partial class SettingsViewModelHostPage : Page
{
    public SettingsViewModelHostPage()
    {
        InitializeComponent();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);

        SettingsTab tab = SettingsTab.General;
        if (e.Parameter is SettingsPageContext ctx)
        {
            tab = ctx.Tab;
        }

        TitleText.Text = SettingsTabMetadata.Title(tab);
        SubtitleText.Text = SettingsTabMetadata.Subtitle(tab);

        SettingsTabViewModelDescriptor? descriptor = SettingsTabViewModelCatalog.Descriptors
            .FirstOrDefault(d => d.Tab == tab);

        if (descriptor is null)
        {
            GatingPill.Text = "No portable view-model";
            BodyText.Text = "This tab is not in SettingsTabViewModelCatalog.";
            DetailList.ItemsSource = Array.Empty<string>();
            return;
        }

        GatingPill.Text = descriptor.Gating == SettingsTabViewModelGating.Live
            ? "Live view-model · production page"
            : "View-model live · data gated on OAuth/App Check when credentials missing";

        object? vm = SettingsViewModelFactory.Create(tab);
        BodyText.Text = $"View-model: {descriptor.ViewModelName} · Oracle: {descriptor.MacOsOracle}";
        DetailList.ItemsSource = SettingsViewModelFactory.Describe(vm);
    }
}

/// <summary>Constructs portable settings view-models for WinUI host pages.</summary>
public static class SettingsViewModelFactory
{
    public static object? Create(SettingsTab tab) => tab switch
    {
        SettingsTab.Daemon => new DaemonSettingsViewModel(),
        SettingsTab.Agents => new OpenBurnBar.App.Settings.ViewModels.Agents.AgentsSettingsViewModel(),
        SettingsTab.ModelProxy => new ModelProxySettingsViewModel(),
        SettingsTab.Alerts => new AlertsSettingsViewModel(),
        SettingsTab.Notifications => new NotificationsSettingsViewModel(),
        SettingsTab.TextExpansion => new TextExpansionSettingsViewModel(),
        SettingsTab.ComputerUse => new ComputerUseSettingsViewModel(),
        SettingsTab.Pets => new PetsSettingsViewModel(),
        SettingsTab.Account => new AccountSettingsViewModel(),
        SettingsTab.Cloud => new CloudSettingsViewModel(),
        SettingsTab.DevicesAndSync => new DevicesAndSyncSettingsViewModel(),
        SettingsTab.Media => new MediaSettingsSurfaceModel(),
        _ => null,
    };

    public static IReadOnlyList<string> Describe(object? vm)
    {
        if (vm is null)
        {
            return new[] { "No view-model instance." };
        }

        var lines = new List<string> { "Type: " + vm.GetType().Name };
        if (vm is DaemonSettingsViewModel daemon)
        {
            lines.Add(daemon.FinishLineDefault);
            lines.Add(daemon.FinishLineExplainer);
            lines.Add(daemon.Summary.HeaderLine);
            lines.Add(daemon.Explainer);
            foreach (WindowsFinishLineScopeRow row in daemon.FinishLineScope.Take(8))
            {
                lines.Add($"F1/F2 · {row.Area}: {row.F1ShipPeer}");
            }
        }
        else if (vm is ObservableSettingsViewModel observable)
        {
            // Generic property dump of public string properties for honesty surface.
            foreach (var prop in observable.GetType().GetProperties()
                         .Where(p => p.CanRead && p.PropertyType == typeof(string)))
            {
                try
                {
                    object? val = prop.GetValue(observable);
                    if (val is string s && !string.IsNullOrWhiteSpace(s))
                    {
                        lines.Add($"{prop.Name}: {s}");
                    }
                }
                catch
                {
                    // skip
                }
            }
        }

        if (lines.Count == 1)
        {
            lines.Add("View-model constructed for production navigation (no empty leaf).");
        }

        return lines;
    }
}

/// <summary>Media tab surface until full Mercury host page is bound (still a real page, not empty leaf).</summary>
public sealed class MediaSettingsSurfaceModel : ObservableSettingsViewModel
{
    public string Title => "Media (Mercury)";

    public string Summary =>
        "Mercury media settings host. Live call/screen-share adapters live under windows/integrations/mercury; " +
        "this page is the production settings destination (not legacy empty settings leaf).";
}

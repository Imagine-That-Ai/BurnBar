using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Cli;
using OpenBurnBar.App.Presentation.Switcher;

namespace OpenBurnBar.App.Switcher;

/// <summary>
/// The account-switcher surface (Windows). Renders the provider-grouped profile sections from
/// the portable <see cref="SwitcherSettingsViewModel"/> (unit-tested on macOS) and routes the
/// row + section commands (make-primary, reorder, pause/resume, change-account, edit, delete,
/// add) back to it. Designed to be hosted as the "switcher" destination inside the AppShell.
///
/// The profile create/edit form and the account destination picker are ContentDialogs. The
/// account-change flow opens the chosen sign-in URL; the live re-scan / OAuth capture that the
/// macOS app performs afterwards is a Windows dev-host integration (SwitcherDiscoveryService).
/// </summary>
public sealed partial class SwitcherSettingsView : UserControl
{
    private ISwitcherProfileStore? _profileStore;

    public SwitcherSettingsView()
    {
        InitializeComponent();
        Unloaded += (_, _) => LiveShell.Detach();
    }

    public SwitcherSettingsViewModel? ViewModel { get; private set; }

    /// <summary>Bind a view-model and refresh compiled bindings. Caller invokes <see cref="SwitcherSettingsViewModel.Load"/>.</summary>
    public void SetModel(SwitcherSettingsViewModel viewModel, ISwitcherProfileStore profileStore)
    {
        ViewModel = viewModel ?? throw new ArgumentNullException(nameof(viewModel));
        _profileStore = profileStore ?? throw new ArgumentNullException(nameof(profileStore));
        Bindings.Update();
    }

    private static SwitcherProfileRowViewModel? RowFrom(object sender) =>
        (sender as FrameworkElement)?.DataContext as SwitcherProfileRowViewModel;

    private static SwitcherGroupViewModel? GroupFrom(object sender) =>
        (sender as FrameworkElement)?.DataContext as SwitcherGroupViewModel;

    // ── Row commands ──────────────────────────────────────────────────────────

    private void OnMakePrimary(object sender, RoutedEventArgs e)
    {
        if (ViewModel is { } vm && RowFrom(sender) is { } row)
        {
            vm.MakePrimary(row.Profile, row.Group);
        }
    }

    private void OnLaunchShell(object sender, RoutedEventArgs e)
    {
        ShellErrorBar.IsOpen = false;
        if (_profileStore is null || RowFrom(sender) is not { } row)
        {
            return;
        }

        try
        {
            SwitcherShellLaunchPlan plan = SwitcherShellLaunchPlanner.CreateForProfile(
                _profileStore,
                row.Profile.Id,
                sourceEnvironment: Environment.GetEnvironmentVariables()
                    .Cast<System.Collections.DictionaryEntry>()
                    .ToDictionary(
                        entry => (string)entry.Key,
                        entry => entry.Value?.ToString(),
                        StringComparer.OrdinalIgnoreCase));
            LiveShell.Visibility = Visibility.Visible;
            LiveShell.Attach(ConPtyCliStream.Create(plan), autoStart: true);
        }
        catch (Exception ex)
        {
            OpenBurnBar.App.Diagnostics.AppDiagnostics.LogException("switcher.shell.launch", ex);
            ShellErrorBar.Message = ex.Message;
            ShellErrorBar.IsOpen = true;
        }
    }

    private void OnMoveUp(object sender, RoutedEventArgs e)
    {
        if (ViewModel is { } vm && RowFrom(sender) is { } row)
        {
            vm.MoveWithinGroup(row.Profile, row.Group, moveUp: true);
        }
    }

    private void OnMoveDown(object sender, RoutedEventArgs e)
    {
        if (ViewModel is { } vm && RowFrom(sender) is { } row)
        {
            vm.MoveWithinGroup(row.Profile, row.Group, moveUp: false);
        }
    }

    private void OnTogglePause(object sender, RoutedEventArgs e)
    {
        if (ViewModel is { } vm && RowFrom(sender) is { } row)
        {
            vm.ToggleDisabled(row.Profile, row.Group);
        }
    }

    private async void OnChangeAccount(object sender, RoutedEventArgs e)
    {
        if (ViewModel is null || RowFrom(sender) is not { } row)
        {
            return;
        }

        var destinations = SwitcherDestinationPlanner.AvailableAccountChangeDestinations(row.Profile).ToList();
        if (destinations.Count == 0 &&
            SwitcherDestinationPlanner.DefaultAccountChangeDestination(row.Profile) is { } fallback)
        {
            destinations.Add(fallback);
        }

        if (destinations.Count == 0)
        {
            return;
        }

        var picker = new AccountDestinationPickerDialog(row.Profile.DisplayName, destinations)
        {
            XamlRoot = XamlRoot,
        };

        await picker.ShowAsync();
        if (picker.SelectedDestination is { } destination)
        {
            await Windows.System.Launcher.LaunchUriAsync(new Uri(destination.Url()));
        }
    }

    private async void OnEdit(object sender, RoutedEventArgs e)
    {
        if (ViewModel is null || RowFrom(sender) is not { } row)
        {
            return;
        }

        var form = SwitcherProfileForm.LoadFrom(row.Profile);
        await ShowFormDialogAsync(form, "Edit Profile", row.Profile);
    }

    private async void OnDelete(object sender, RoutedEventArgs e)
    {
        if (ViewModel is not { } vm || RowFrom(sender) is not { } row)
        {
            return;
        }

        var confirm = new ContentDialog
        {
            Title = "Delete profile",
            Content = $"This will permanently delete the profile '{row.Profile.DisplayName}'. This action cannot be undone.",
            PrimaryButtonText = "Delete",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = XamlRoot,
        };

        if (await confirm.ShowAsync() == ContentDialogResult.Primary)
        {
            vm.DeleteProfile(row.Profile);
        }
    }

    // ── Section + header commands ────────────────────────────────────────────

    private async void OnAddAccount(object sender, RoutedEventArgs e)
    {
        if (ViewModel is null || GroupFrom(sender) is not { } group)
        {
            return;
        }

        var form = new SwitcherProfileForm();
        form.Reset();
        if (group.IsCli && group.CliType is { } cliType)
        {
            form.TargetKind = SwitcherProfileTargetKind.Cli;
            form.CliType = cliType;
        }
        else if (group.BrowserType is { } browserType)
        {
            form.TargetKind = SwitcherProfileTargetKind.Browser;
            form.BrowserType = browserType;
        }

        await ShowFormDialogAsync(form, $"Add {group.Label} account", original: null);
    }

    private async void OnManualAdd(object sender, RoutedEventArgs e)
    {
        var form = new SwitcherProfileForm();
        form.Reset();
        await ShowFormDialogAsync(form, "New Profile", original: null);
    }

    private async Task ShowFormDialogAsync(SwitcherProfileForm form, string title, SwitcherProfileRecord? original)
    {
        if (ViewModel is not { } vm)
        {
            return;
        }

        SwitcherFormValidationResult Submit(SwitcherProfileForm f) =>
            original is null ? vm.CreateProfile(f) : vm.SaveProfile(original, f);

        var dialog = new ProfileFormDialog(form, Submit)
        {
            Title = title,
            XamlRoot = XamlRoot,
        };

        await dialog.ShowAsync();
    }
}

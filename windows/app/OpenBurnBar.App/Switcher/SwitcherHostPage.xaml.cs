using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Presentation.Switcher;
using OpenBurnBar.App.Storage;

namespace OpenBurnBar.App.Switcher;

/// <summary>
/// Nav-frame host for <see cref="SwitcherSettingsView"/>. Registered as the "switcher" destination
/// in <see cref="OpenBurnBar.App.Shell.SurfacePageResolver"/>. Builds a
/// <see cref="SwitcherSettingsViewModel"/> over the configured profile store and loads it.
/// Missing credentials produce an empty editable store; sample profiles require
/// <c>OPENBURNBAR_SAMPLE_MODE=1</c>.
/// </summary>
public sealed partial class SwitcherHostPage : Page
{
    public SwitcherHostPage()
    {
        InitializeComponent();
        Loaded += OnLoaded;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        Loaded -= OnLoaded;

        ISwitcherProfileStore store = WindowsStorageDevHost.CreateSwitcherProfileStore();
        var viewModel = new SwitcherSettingsViewModel(store);
        SwitcherView.SetModel(viewModel, store);
        viewModel.Load();
    }
}

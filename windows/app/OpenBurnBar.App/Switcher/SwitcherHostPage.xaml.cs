using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Presentation.Switcher;

namespace OpenBurnBar.App.Switcher;

/// <summary>
/// Nav-frame host for <see cref="SwitcherSettingsView"/>. Registered as the "switcher" destination
/// in <see cref="OpenBurnBar.App.Shell.SurfacePageResolver"/>. Builds a
/// <see cref="SwitcherSettingsViewModel"/> over the portable, unit-tested
/// <see cref="SwitcherSampleData"/> dev-host store, binds it into the surface, and loads it — the
/// Windows analog of BudgetPage seeding an <c>InMemoryBudgetRuleStore</c>. When the encrypted
/// profile store lands, this is the single line that swaps the store.
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

        var viewModel = new SwitcherSettingsViewModel(SwitcherSampleData.CreateDevHostStore());
        SwitcherView.SetModel(viewModel);
        viewModel.Load();
    }
}

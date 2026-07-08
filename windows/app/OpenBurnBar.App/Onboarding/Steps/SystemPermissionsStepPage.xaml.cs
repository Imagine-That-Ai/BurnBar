using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace OpenBurnBar.App.Onboarding;

/// <summary>System-permissions step. Windows peer of
/// <c>OnboardingSystemPermissionsView.swift</c>. Informational until the Windows PAL wires
/// real grant checks; the footer's "Continue (set up later)" reflects the unresolved
/// state exactly like macOS defers unresolved permissions.</summary>
public sealed partial class SystemPermissionsStepPage : Page
{
    public SystemPermissionsStepPage()
    {
        InitializeComponent();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        // No live grant source yet: leave SystemPermissionsResolved = false so the footer
        // shows "Continue (set up later)" — the honest Windows default for this step.
    }
}

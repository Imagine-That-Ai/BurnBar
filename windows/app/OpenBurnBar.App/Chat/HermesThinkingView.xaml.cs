using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace OpenBurnBar.App.Chat;

/// <summary>
/// Code-behind for the Hermes thinking droplets. Windows peer of
/// AgentLens/Views/Chat/HermesThinkingView.swift. The staggered opacity pulse
/// runs while the control is loaded and stops when it unloads, so a completed
/// turn does not leave an animation timer running.
/// </summary>
public sealed partial class HermesThinkingView : UserControl
{
    public HermesThinkingView()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    private void OnLoaded(object sender, RoutedEventArgs e) => PulseStoryboard.Begin();

    private void OnUnloaded(object sender, RoutedEventArgs e) => PulseStoryboard.Stop();
}

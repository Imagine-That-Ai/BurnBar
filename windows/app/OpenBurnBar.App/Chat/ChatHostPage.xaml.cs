using Microsoft.UI.Xaml.Controls;

namespace OpenBurnBar.App.Chat;

/// <summary>
/// Nav-frame host for <see cref="ChatSurfaceView"/>. Registered as the "chat" destination in
/// <see cref="OpenBurnBar.App.Shell.SurfacePageResolver"/>; the AppShell content Frame navigates to
/// this Page and the surface takes over the canvas. The surface is self-contained (owns its
/// <see cref="ChatSurfaceViewModel"/> + Pretext host), so this host only satisfies the Frame's Page
/// contract — no per-navigation wiring.
/// </summary>
public sealed partial class ChatHostPage : Page
{
    public ChatHostPage()
    {
        InitializeComponent();
    }
}

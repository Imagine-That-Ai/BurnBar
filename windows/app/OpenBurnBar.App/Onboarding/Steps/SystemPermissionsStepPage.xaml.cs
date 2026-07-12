using System;
using System.IO;
using System.Linq;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using OpenBurnBar.App.Storage;
using OpenBurnBar.App.UsageRuntime;
using Microsoft.Windows.AppNotifications;
using Windows.Graphics.Capture;

namespace OpenBurnBar.App.Onboarding;

/// <summary>Windows-native readiness probes for storage, logs, notifications, UIA, and capture.</summary>
public sealed partial class SystemPermissionsStepPage : Page
{
    private OnboardingContext? _context;

    public SystemPermissionsStepPage()
    {
        InitializeComponent();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _context = e.Parameter as OnboardingContext;
        RefreshCapabilities();
    }

    private void Refresh_Click(object sender, RoutedEventArgs e) => RefreshCapabilities();

    private void RefreshCapabilities()
    {
        CapabilityRows.Children.Clear();
        bool storageReady = WindowsStorageDevHost.Status.IsReady;
        AddRow(
            "Encrypted local storage",
            storageReady ? "Ready" : "Needs recovery",
            storageReady
                ? "SQLCipher storage and the protected key are available."
                : WindowsStorageDevHost.Status.RecoveryState?.Message ?? "Storage has not initialized.",
            storageReady);

        WindowsUsagePaths usagePaths = WindowsUsagePaths.ForCurrentUser();
        string[] detectedRoots = usagePaths.WatchDirectories.Where(Directory.Exists).ToArray();
        bool logsDetected = detectedRoots.Length > 0;
        bool logsReadable = detectedRoots.All(CanEnumerate);
        AddRow(
            "Agent log access",
            logsDetected ? (logsReadable ? "Ready" : "Access blocked") : "No providers detected",
            logsDetected
                ? "OpenBurnBar can watch supported provider log folders."
                : "Install or run a supported agent, then refresh this status.",
            !logsDetected || logsReadable);

        bool notifications = ProbeNotifications();
        AddRow(
            "App notifications",
            notifications ? "Supported" : "Unavailable",
            notifications
                ? "Windows app notifications can be registered for alerts and finished sessions."
                : "Notifications are unavailable for this Windows runtime or app identity.",
            notifications);

        bool interactive = Environment.UserInteractive;
        AddRow(
            "UI Automation and input",
            interactive ? "Interactive session ready" : "Session unavailable",
            interactive
                ? "Automation runs in your signed-in desktop and still requires per-action approval."
                : "Sign in to an interactive Windows desktop before enabling Computer Use.",
            interactive);

        bool capture = GraphicsCaptureSession.IsSupported();
        AddRow(
            "Screen capture",
            capture ? "Supported" : "Unavailable",
            capture
                ? "Windows Graphics Capture is available; each capture still uses the Windows picker and consent flow."
                : "This Windows build or graphics stack does not support screen capture.",
            capture);

        if (_context?.Model is { } model)
        {
            model.SystemPermissionsResolved = storageReady && logsReadable && interactive;
        }
    }

    private void AddRow(string title, string status, string detail, bool ready)
    {
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var body = new StackPanel { Spacing = 4 };
        body.Children.Add(new TextBlock { Text = title, FontSize = 13.5, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        body.Children.Add(new TextBlock { Text = detail, Opacity = 0.7, FontSize = 12, TextWrapping = TextWrapping.Wrap });
        Grid.SetColumn(body, 0);
        var badge = new TextBlock
        {
            Text = status,
            FontSize = 11,
            Opacity = ready ? 0.82 : 1,
            VerticalAlignment = VerticalAlignment.Top,
        };
        AutomationProperties.SetName(badge, $"{title}: {status}");
        Grid.SetColumn(badge, 1);
        grid.Children.Add(body);
        grid.Children.Add(badge);
        CapabilityRows.Children.Add(new Border
        {
            Style = (Style)Application.Current.Resources["LiquidGlassSurfaceStyle"],
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(14),
            Child = grid,
        });
    }

    private static bool CanEnumerate(string path)
    {
        try
        {
            using var enumerator = Directory.EnumerateFileSystemEntries(path).GetEnumerator();
            _ = enumerator.MoveNext();
            return true;
        }
        catch (IOException)
        {
            return false;
        }
        catch (UnauthorizedAccessException)
        {
            return false;
        }
    }

    private static bool ProbeNotifications()
    {
        try
        {
            return AppNotificationManager.IsSupported();
        }
        catch
        {
            return false;
        }
    }
}

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace OpenBurnBar.App.Onboarding;

/// <summary>Completion step. Windows peer of <c>OnboardingCompleteView.swift</c>: a summary
/// of what was found + the "Open Dashboard" / "Stay in the tray" exits. Both exits finalize
/// the wizard (persisting the outcome) before invoking the host callback.</summary>
public sealed partial class CompleteStepPage : Page
{
    private OnboardingContext? _context;

    public CompleteStepPage()
    {
        InitializeComponent();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _context = e.Parameter as OnboardingContext;
        if (_context is null)
        {
            return;
        }

        int sessions = _context.SessionCount;
        int providers = _context.ProviderCount;
        int tracked = _context.Model.SelectedProviders.Count;

        Headline.Text = sessions > 0
            ? $"Found {sessions} session{Plural(sessions)} across {providers} provider{Plural(providers)}"
            : "You're all set";
        Subtitle.Text =
            $"OpenBurnBar is now tracking {tracked} agent{Plural(tracked)}. Your dashboard, session logs, and Hermes chat are ready.";
        EmptyNote.Visibility = sessions == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private static string Plural(int count) => count == 1 ? string.Empty : "s";

    private void OnOpenDashboard(object sender, RoutedEventArgs e)
    {
        _context?.Model.Finalize();
        _context?.OpenDashboard?.Invoke();
    }

    private void OnStayInTray(object sender, RoutedEventArgs e)
    {
        _context?.Model.Finalize();
        _context?.Dismiss?.Invoke();
    }
}

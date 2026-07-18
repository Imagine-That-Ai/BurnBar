using System;
using System.Collections.Generic;
using Microsoft.UI.Xaml;
using OpenBurnBar.App.Interop;
using OpenBurnBar.App.Theme;

namespace OpenBurnBar.App.Onboarding;

/// <summary>
/// Standalone host window for the onboarding wizard — the Windows peer of the macOS
/// 520x620 first-run window. Owns the <see cref="OnboardingWizardModel"/>, seeds it from
/// the host's detection + settings, and hosts the <see cref="OnboardingPage"/>. The glass
/// window backdrop routes through the LiquidGlass chokepoint so it honors the transparency
/// preference like every other surface. The appearance follows the shared
/// <see cref="ThemeService"/> (registered below, same as <see cref="MainWindow"/>).
/// </summary>
public sealed partial class OnboardingWindow : Window
{
    private readonly OnboardingWizardModel _model = new();
    private readonly OnboardingPage _page = new();

    public OnboardingWindow(ThemeService theme)
    {
        InitializeComponent();

        WindowChrome.TryApplyMica(this);
        LiquidGlass.ApplyWindowBackdrop(this, LiquidGlassEnvironment.Current);

        var appWindow = WindowChrome.GetAppWindow(this);
        appWindow.Resize(new Windows.Graphics.SizeInt32(520, 620));

        RootHost.Children.Add(_page);

        // Same appearance ownership as MainWindow: the shared theme service pushes
        // RequestedTheme + backdrop onto this window and re-applies on every change.
        theme.Register(this);
    }

    /// <summary>Raised when the wizard chooses "Open Dashboard".</summary>
    public event EventHandler? OpenDashboardRequested;

    /// <summary>The finalized outcome (selected providers + chat backends), available after
    /// the wizard completes for the host to apply to real settings.</summary>
    public OnboardingCompletionResult? Result { get; private set; }

    /// <summary>
    /// Seed the wizard and show the first step. The host passes the providers it detected
    /// (pre-selected, detected-first) and the existing chat-backend settings so the wizard
    /// opens in the same state the macOS <c>onAppear</c> produced.
    /// </summary>
    public void Begin(
        IReadOnlyCollection<AgentProviderBrand> detectedProviders,
        IReadOnlyCollection<ChatBackendId> existingBackends,
        ChatBackendId? currentEngine,
        int sessionCount = 0,
        int providerCount = 0)
    {
        _model.SetDetectedProviders(detectedProviders);
        _model.PreselectDetectedProviders();
        _model.SeedChatBackends(existingBackends, currentEngine);

        var context = new OnboardingContext(_model)
        {
            SessionCount = sessionCount,
            ProviderCount = providerCount,
            OpenDashboard = OnOpenDashboard,
            Dismiss = OnDismiss,
            ShowHermesSetup = ShowHermesSetup,
            // Resolve the real HWND so step-page file pickers get a real owner
            // (WindowChrome.GetHandle pattern — fixes the dead-picker bug).
            WindowHandleProvider = () => WindowChrome.GetHandle(this),
        };

        _page.Start(context);
    }

    private void OnOpenDashboard()
    {
        Result = _model.Finalize();
        OpenDashboardRequested?.Invoke(this, EventArgs.Empty);
        Close();
    }

    private void OnDismiss()
    {
        Result = _model.Finalize();
        Close();
    }

    private void ShowHermesSetup()
    {
        var dialog = new HermesSetupDialog { XamlRoot = _page.XamlRoot };
        _ = dialog.ShowAsync();
    }
}

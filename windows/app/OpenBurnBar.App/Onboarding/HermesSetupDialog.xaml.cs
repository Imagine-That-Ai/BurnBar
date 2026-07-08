using System;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace OpenBurnBar.App.Onboarding;

/// <summary>
/// Prepare-Hermes wizard dialog. Windows peer of <c>HermesSetupWizardView.swift</c>, driven
/// by the portable, unit-tested <see cref="HermesSetupModel"/>. The three steps advance in
/// place (the dialog stays open until "Finish" on the Chat step). Live probe/config I/O is
/// injected via the optional action callbacks; when unset the panels simply reflect the
/// model's current derived state.
/// </summary>
public sealed partial class HermesSetupDialog : ContentDialog
{
    private static readonly Color NeutralColor = Color.FromArgb(0xFF, 0x9A, 0xA0, 0xAA);
    private static readonly Color WarnColor = Color.FromArgb(0xFF, 0xF5, 0x9E, 0x0B);
    private static readonly Color BlockedColor = Color.FromArgb(0xFF, 0xEE, 0x18, 0x03);
    private static readonly Color ReadyColor = Color.FromArgb(0xFF, 0x22, 0xC5, 0x5E);

    private readonly HermesSetupModel _model = new();

    public HermesSetupDialog()
    {
        InitializeComponent();
        Loaded += (_, _) => Refresh();
    }

    /// <summary>The state machine, exposed so the host can drive live checks + call
    /// <see cref="Refresh"/> after mutating it.</summary>
    public HermesSetupModel Model => _model;

    /// <summary>Optional live "check CLI + API server" action (host-provided I/O).</summary>
    public Func<HermesSetupModel, Task>? CheckPrepareAsync { get; set; }

    /// <summary>Optional live "make the gateway reachable" action.</summary>
    public Func<HermesSetupModel, Task>? MakeReachableAsync { get; set; }

    /// <summary>Optional live "run verification chat" action; returns the response text.</summary>
    public Func<HermesSetupModel, Task<string>>? RunVerificationAsync { get; set; }

    /// <summary>Re-render every panel from the model's current state.</summary>
    public void Refresh()
    {
        StepLabel.Text = _model.CurrentStep.StepLabel();
        Title = _model.CurrentStep.Headline();

        PreparePanel.Visibility = Vis(_model.CurrentStep == HermesSetupStep.Prepare);
        ConnectPanel.Visibility = Vis(_model.CurrentStep == HermesSetupStep.Connect);
        ChatPanel.Visibility = Vis(_model.CurrentStep == HermesSetupStep.Chat);

        CliStatus.Text = _model.HermesCliInstalled switch
        {
            true => "Hermes CLI: found" + (string.IsNullOrEmpty(_model.HermesCliPath) ? string.Empty : $" ({_model.HermesCliPath})"),
            false => "Hermes CLI: not found — install it, then Check again",
            null => "Hermes CLI: not checked yet",
        };
        ApiServerStatus.Text = (_model.ApiServerEnabled, _model.HasApiServerKey) switch
        {
            (true, true) => "API server: enabled with a key",
            (true, false) => "API server: enabled, but no key yet",
            (false, _) => "API server: not enabled",
            (null, _) => "API server: not checked yet",
        };

        GatewayReachabilityState reach = _model.Reachability;
        ReachabilityEyebrow.Text = reach.Eyebrow();
        ReachabilityHeadline.Text = reach.Headline();
        ReachabilityDetail.Text = reach.Detail();
        ReachabilityDot.Background = new SolidColorBrush(AccentColor(reach.Accent()));
        string? action = reach.PrimaryActionLabel();
        ReachabilityAction.Visibility = Vis(action is not null);
        if (action is not null)
        {
            ReachabilityAction.Content = action;
        }

        // Primary button label + gating per step.
        PrimaryButtonText = _model.CurrentStep == HermesSetupStep.Chat ? "Finish" : "Continue";
        IsPrimaryButtonEnabled = _model.CurrentStep switch
        {
            HermesSetupStep.Prepare => _model.CanContinueFromPrepare,
            HermesSetupStep.Connect => _model.CanContinueFromConnect,
            _ => true,
        };
        IsSecondaryButtonEnabled = _model.CurrentStep != HermesSetupStep.Prepare;
    }

    private void OnPrimaryClicked(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        if (_model.CurrentStep == HermesSetupStep.Chat)
        {
            return; // allow the dialog to close on Finish
        }

        args.Cancel = true; // stay open; advance a step
        _model.NavigateForward();
        Refresh();
    }

    private void OnSecondaryClicked(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        args.Cancel = true; // stay open; go back a step
        _model.NavigateBack();
        Refresh();
    }

    private async void OnCheckPrepare(object sender, RoutedEventArgs e)
    {
        if (CheckPrepareAsync is not null)
        {
            await CheckPrepareAsync(_model);
        }

        Refresh();
    }

    private async void OnMakeReachable(object sender, RoutedEventArgs e)
    {
        if (MakeReachableAsync is not null)
        {
            await MakeReachableAsync(_model);
        }

        Refresh();
    }

    private async void OnRunVerification(object sender, RoutedEventArgs e)
    {
        if (RunVerificationAsync is not null)
        {
            string response = await RunVerificationAsync(_model);
            VerificationResult.Text = string.IsNullOrWhiteSpace(response)
                ? "Hermes returned an empty response. The gateway might still be initializing — try again."
                : response;
            VerificationResultBox.Visibility = Visibility.Visible;
        }

        Refresh();
    }

    private static Color AccentColor(GatewayReachabilityAccent accent) => accent switch
    {
        GatewayReachabilityAccent.Ready => ReadyColor,
        GatewayReachabilityAccent.Warning => WarnColor,
        GatewayReachabilityAccent.Blocked => BlockedColor,
        _ => NeutralColor,
    };

    private static Visibility Vis(bool visible) => visible ? Visibility.Visible : Visibility.Collapsed;
}

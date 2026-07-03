using System;
using Microsoft.UI.Xaml.Controls;

namespace OpenBurnBar.App.Onboarding;

/// <summary>
/// First-run analytics opt-in. Windows peer of <c>AnalyticsConsentPromptView.swift</c>:
/// analytics is OFF by default; this records the user's decision. The host persists the
/// result (starting/stopping the analytics SDK) via <see cref="DecisionMade"/> or by
/// reading <see cref="Granted"/> after <c>ShowAsync</c>.
/// </summary>
public sealed partial class AnalyticsConsentDialog : ContentDialog
{
    public AnalyticsConsentDialog()
    {
        InitializeComponent();
    }

    /// <summary><c>true</c> when the user chose "Enable analytics".</summary>
    public bool Granted { get; private set; }

    /// <summary>Raised with the user's decision (<c>true</c> = grant).</summary>
    public event EventHandler<bool>? DecisionMade;

    private void OnEnableClicked(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        Granted = true;
        DecisionMade?.Invoke(this, true);
    }

    private void OnDeclineClicked(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        Granted = false;
        DecisionMade?.Invoke(this, false);
    }
}

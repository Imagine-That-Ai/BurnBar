using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Presentation.DataControlCenter;

namespace OpenBurnBar.App.DataControlCenter;

/// <summary>
/// The panic dialog. Revokes access at the chosen scope (sync-only / everything) after the user
/// types the exact scope word, then shows the teardown tally. Wax-crimson, double-confirm — parity
/// with the macOS <c>PanicRevokeSheet</c>.
/// </summary>
public sealed partial class PanicRevokeDialog : ContentDialog
{
    private readonly DataControlCenterViewModel _viewModel;
    private bool _completed;

    public PanicRevokeDialog(DataControlCenterViewModel viewModel)
    {
        _viewModel = viewModel;
        InitializeComponent();
        PrimaryButtonClick += OnRevokeClick;
        UpdateScope();
    }

    private RevokeScope Scope => ScopeAll.IsChecked == true ? RevokeScope.All : RevokeScope.Sync;

    private string ConfirmWord => Scope == RevokeScope.All ? "REVOKE ALL" : "REVOKE SYNC";

    private void OnScopeChanged(object sender, RoutedEventArgs e)
    {
        if (ConfirmBox is null)
        {
            return;
        }

        ConfirmBox.Text = string.Empty;
        UpdateScope();
    }

    private void UpdateScope()
    {
        ScopeExplanation.Text = Scope == RevokeScope.All
            ? "Immediately revokes every MCP client, paired device, escrow device, and provider connection. Your sealed data stays sealed, but nothing can reach it until you re-pair."
            : "Immediately stops cloud sync and revokes paired devices and MCP clients. Provider credentials and escrow stay intact.";
        ConfirmPrompt.Text = $"Type {ConfirmWord} to confirm";
        UpdatePrimaryEnabled();
    }

    private void OnConfirmChanged(object sender, TextChangedEventArgs e) => UpdatePrimaryEnabled();

    private void UpdatePrimaryEnabled() =>
        IsPrimaryButtonEnabled = !_completed && !_viewModel.IsMutating && ConfirmBox.Text == ConfirmWord;

    private async void OnRevokeClick(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        args.Cancel = true;
        var deferral = args.GetDeferral();
        try
        {
            var result = await _viewModel.RevokeAllAccessAsync(Scope);
            if (result is { } tally)
            {
                _completed = true;
                ConfirmGroup.Visibility = Visibility.Collapsed;
                ResultGroup.Visibility = Visibility.Visible;
                ResultText.Text = $"{tally.McpClients} MCP clients · {tally.Devices} devices · {tally.EscrowDevices} escrow devices · {tally.Providers} providers";
                IsPrimaryButtonEnabled = false;
                CloseButtonText = "Done";
            }

            ShowError(_viewModel.ActionError);
        }
        finally
        {
            deferral.Complete();
        }
    }

    private void ShowError(string? message)
    {
        if (string.IsNullOrEmpty(message))
        {
            ErrorText.Visibility = Visibility.Collapsed;
        }
        else
        {
            ErrorText.Text = message;
            ErrorText.Visibility = Visibility.Visible;
        }
    }
}

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Presentation.DataControlCenter;

namespace OpenBurnBar.App.DataControlCenter;

/// <summary>
/// The delete-domain confirmation. Type-DELETE-to-confirm permanent deletion via the portable
/// <see cref="DataControlCenterViewModel"/>; end-to-end domains get the "genuine, irreversible
/// ciphertext deletion" copy. Parity with the macOS <c>DeleteDomainSheet</c>.
/// </summary>
public sealed partial class DeleteDomainDialog : ContentDialog
{
    private readonly DataControlCenterViewModel _viewModel;
    private readonly DataDomain _domain;
    private bool _completed;

    public DeleteDomainDialog(DataControlCenterViewModel viewModel, DataDomain domain)
    {
        _viewModel = viewModel;
        _domain = domain;
        InitializeComponent();

        TitleText.Text = $"Delete {domain.Title}";
        WarningText.Text = domain.EncryptionTier == EncryptionTier.EndToEnd
            ? $"This permanently deletes the ciphertext for {domain.Title}. Because it's sealed end-to-end, this is genuine, irreversible deletion."
            : $"This permanently deletes everything in {domain.Title}. This cannot be undone.";

        PrimaryButtonClick += OnDeleteClick;
        IsPrimaryButtonEnabled = false;
    }

    private void OnConfirmChanged(object sender, TextChangedEventArgs e) =>
        IsPrimaryButtonEnabled = !_completed && !_viewModel.IsMutating && ConfirmBox.Text == "DELETE";

    private async void OnDeleteClick(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        args.Cancel = true;
        var deferral = args.GetDeferral();
        try
        {
            var result = await _viewModel.DeleteDomainAsync(_domain.Id);
            if (result is { } tally)
            {
                _completed = true;
                ConfirmGroup.Visibility = Visibility.Collapsed;
                ResultGroup.Visibility = Visibility.Visible;
                ResultText.Text = $"Deleted {tally.FirestoreDocs} records and {tally.StorageObjects} files.";
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

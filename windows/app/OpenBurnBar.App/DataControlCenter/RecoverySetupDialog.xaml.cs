using System.Collections.Generic;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Presentation.DataControlCenter;

namespace OpenBurnBar.App.DataControlCenter;

/// <summary>
/// The recovery setup dialog. Registers a recovery key or a split-knowledge recovery contact via
/// the portable <see cref="DataControlCenterViewModel"/>. The recovery-key crypto envelope is a
/// dev-host seam (the CloudVault key-wrap), so this dialog forwards the raw key in the payload; the
/// contact path is fully portable.
/// </summary>
public sealed partial class RecoverySetupDialog : ContentDialog
{
    private readonly DataControlCenterViewModel _viewModel;

    public RecoverySetupDialog(DataControlCenterViewModel viewModel)
    {
        _viewModel = viewModel;
        InitializeComponent();
        ExistingList.ItemsSource = viewModel.RecoveryMethods;
        PrimaryButtonClick += OnRegisterClick;
        Loaded += OnLoaded;
        UpdatePrimaryEnabled();
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        await _viewModel.RefreshRecoveryAsync();
        ExistingGroup.Visibility = _viewModel.RecoveryMethods.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private bool IsKeyMethod => MethodKey.IsChecked == true;

    private void OnMethodChanged(object sender, RoutedEventArgs e)
    {
        if (KeyForm is null || ContactForm is null)
        {
            return; // Checked can fire during InitializeComponent before fields exist
        }

        KeyForm.Visibility = IsKeyMethod ? Visibility.Visible : Visibility.Collapsed;
        ContactForm.Visibility = IsKeyMethod ? Visibility.Collapsed : Visibility.Visible;
        UpdatePrimaryEnabled();
    }

    private void OnFormChanged(object sender, TextChangedEventArgs e) => UpdatePrimaryEnabled();

    private void UpdatePrimaryEnabled()
    {
        IsPrimaryButtonEnabled = !_viewModel.IsMutating && (IsKeyMethod
            ? !string.IsNullOrWhiteSpace(RecoveryKeyBox.Text)
            : !string.IsNullOrWhiteSpace(ContactEmailBox.Text));
    }

    private async void OnRegisterClick(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        // Keep the dialog open so the user can register additional methods (parity with the sheet).
        args.Cancel = true;
        var deferral = args.GetDeferral();
        try
        {
            string? recoveryId;
            if (IsKeyMethod)
            {
                recoveryId = await _viewModel.SetupRecoveryAsync(
                    RecoveryKind.RecoveryKey,
                    new Dictionary<string, object?> { ["recoveryKey"] = RecoveryKeyBox.Text });
                if (recoveryId is not null)
                {
                    RecoveryKeyBox.Text = string.Empty;
                }
            }
            else
            {
                recoveryId = await _viewModel.SetupRecoveryAsync(
                    RecoveryKind.RecoveryContact,
                    new Dictionary<string, object?>
                    {
                        ["contactEmail"] = ContactEmailBox.Text,
                        ["contactLabel"] = ContactLabelBox.Text,
                    });
                if (recoveryId is not null)
                {
                    ContactEmailBox.Text = string.Empty;
                    ContactLabelBox.Text = string.Empty;
                }
            }

            ExistingGroup.Visibility = _viewModel.RecoveryMethods.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
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

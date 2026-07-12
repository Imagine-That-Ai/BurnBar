using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Presentation.Switcher;

namespace OpenBurnBar.App.Switcher;

/// <summary>
/// Create/edit dialog for a switcher profile. Reads and writes the portable
/// <see cref="SwitcherProfileForm"/> (validation + record construction live there, unit-tested
/// on macOS). Save runs the injected submit callback (VM create/save); a validation failure
/// keeps the dialog open and surfaces the form's error text.
/// </summary>
public sealed partial class ProfileFormDialog : ContentDialog
{
    private readonly SwitcherProfileForm _form;
    private readonly Func<SwitcherProfileForm, SwitcherFormValidationResult> _onSubmit;
    private readonly SwitcherCLIProfileType[] _cliTypes =
        (SwitcherCLIProfileType[])Enum.GetValues(typeof(SwitcherCLIProfileType));

    public ProfileFormDialog(
        SwitcherProfileForm form,
        Func<SwitcherProfileForm, SwitcherFormValidationResult> onSubmit)
    {
        _form = form ?? throw new ArgumentNullException(nameof(form));
        _onSubmit = onSubmit ?? throw new ArgumentNullException(nameof(onSubmit));
        InitializeComponent();
        Seed();
    }

    private void Seed()
    {
        foreach (var type in _cliTypes)
        {
            CliTypeCombo.Items.Add(new ComboBoxItem { Content = type.DisplayName() });
        }

        NameBox.Text = _form.Name;
        ProfileIdentifierBox.Text = _form.ProfileIdentifier;
        WorkingDirBox.Text = _form.WorkingDirectory;
        ArgsBox.Text = _form.AdditionalArgs;
        EnvBox.Text = _form.EnvKeys;

        BrowserTypeCombo.SelectedIndex = _form.BrowserType == SwitcherBrowserProfileType.Safari ? 1 : 0;
        CliTypeCombo.SelectedIndex = Array.IndexOf(_cliTypes, _form.CliType);
        TargetKindCombo.SelectedIndex = _form.IsBrowser ? 0 : 1;

        UpdatePanels();
    }

    private void UpdatePanels()
    {
        BrowserPanel.Visibility = _form.IsBrowser ? Visibility.Visible : Visibility.Collapsed;
        CliPanel.Visibility = _form.IsCli ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnTargetKindChanged(object sender, SelectionChangedEventArgs e)
    {
        _form.TargetKind = TargetKindCombo.SelectedIndex == 0
            ? SwitcherProfileTargetKind.Browser
            : SwitcherProfileTargetKind.Cli;
        UpdatePanels();
    }

    private void OnBrowserTypeChanged(object sender, SelectionChangedEventArgs e)
    {
        _form.BrowserType = BrowserTypeCombo.SelectedIndex == 1
            ? SwitcherBrowserProfileType.Safari
            : SwitcherBrowserProfileType.Chrome;
    }

    private void OnCliTypeChanged(object sender, SelectionChangedEventArgs e)
    {
        int index = CliTypeCombo.SelectedIndex;
        if (index >= 0 && index < _cliTypes.Length)
        {
            _form.CliType = _cliTypes[index];
        }
    }

    private void OnNameChanged(object sender, TextChangedEventArgs e) => _form.Name = NameBox.Text;

    private void OnProfileIdentifierChanged(object sender, TextChangedEventArgs e) =>
        _form.ProfileIdentifier = ProfileIdentifierBox.Text;

    private void OnWorkingDirChanged(object sender, TextChangedEventArgs e) =>
        _form.WorkingDirectory = WorkingDirBox.Text;

    private void OnArgsChanged(object sender, TextChangedEventArgs e) =>
        _form.AdditionalArgs = ArgsBox.Text;

    private void OnEnvChanged(object sender, TextChangedEventArgs e) => _form.EnvKeys = EnvBox.Text;

    private void OnPrimary(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        var result = _onSubmit(_form);
        if (result.IsValid)
        {
            return;
        }

        // Keep the dialog open and surface the form's error text.
        args.Cancel = true;
        SetError(DuplicateErrorText, result.DuplicateError);
        SetError(ValidationErrorText, result.ValidationError);
    }

    private static void SetError(TextBlock target, string? message)
    {
        target.Text = message ?? string.Empty;
        target.Visibility = string.IsNullOrEmpty(message) ? Visibility.Collapsed : Visibility.Visible;
    }
}

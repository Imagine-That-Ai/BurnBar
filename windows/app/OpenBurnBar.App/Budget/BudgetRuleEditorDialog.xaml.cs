using System.Threading.Tasks;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Presentation.Budget;

namespace OpenBurnBar.App.Budget;

/// <summary>The outcome of the rule editor dialog.</summary>
public enum BudgetRuleEditorResult
{
    Cancel,
    Save,
    Delete,
}

/// <summary>
/// ContentDialog form over a <see cref="BudgetRuleEditorViewModel"/>. Shows the scope-specific
/// identity fields, mutates the view-model as the operator types, and gates the Save button on
/// <see cref="BudgetRuleEditorViewModel.CanSave"/> — the Windows realization of the Swift
/// editor's <c>saveDisabled</c>. Existing rules also get a Delete (secondary) button.
/// </summary>
public sealed partial class BudgetRuleEditorDialog : ContentDialog
{
    private readonly BudgetRuleEditorViewModel _viewModel;
    private bool _initializing;

    public BudgetRuleEditorDialog(BudgetRuleEditorViewModel viewModel)
    {
        _viewModel = viewModel;
        InitializeComponent();
        Initialize();
    }

    /// <summary>Show the dialog and map the button result to a <see cref="BudgetRuleEditorResult"/>.</summary>
    public async Task<BudgetRuleEditorResult> ShowEditorAsync()
    {
        ContentDialogResult result = await ShowAsync();
        return result switch
        {
            ContentDialogResult.Primary => BudgetRuleEditorResult.Save,
            ContentDialogResult.Secondary => BudgetRuleEditorResult.Delete,
            _ => BudgetRuleEditorResult.Cancel,
        };
    }

    private void Initialize()
    {
        _initializing = true;

        Title = _viewModel.IsNew ? "New rule" : _viewModel.Build().DisplayLabel;

        // Scope-specific identity fields.
        ProviderCard.Visibility = Show(_viewModel.IsCredentialScope);
        AccountCard.Visibility = Show(_viewModel.IsCredentialScope);
        ProjectCard.Visibility = Show(_viewModel.IsProjectScope);
        // The enabled toggle is meaningful when editing an existing rule.
        EnabledCard.Visibility = Show(!_viewModel.IsNew);

        ProviderBox.Text = _viewModel.ProviderId;
        AccountBox.Text = _viewModel.AccountId;
        ProjectBox.Text = _viewModel.ProjectName;
        LabelBox.Text = _viewModel.Label;
        AmountBox.Value = _viewModel.AmountUsd;
        PeriodBox.SelectedIndex = PeriodIndex(_viewModel.Period);
        BehaviorBox.SelectedIndex = BehaviorIndex(_viewModel.Behavior);
        EnabledSwitch.IsOn = _viewModel.IsEnabled;

        if (!_viewModel.IsNew)
        {
            SecondaryButtonText = "Delete";
        }

        _initializing = false;
        UpdateSaveEnabled();
    }

    private void OnFieldChanged(object sender, TextChangedEventArgs e)
    {
        if (_initializing)
        {
            return;
        }

        _viewModel.ProviderId = ProviderBox.Text;
        _viewModel.AccountId = AccountBox.Text;
        _viewModel.ProjectName = ProjectBox.Text;
        _viewModel.Label = LabelBox.Text;
        UpdateSaveEnabled();
    }

    private void OnAmountChanged(NumberBox sender, NumberBoxValueChangedEventArgs args)
    {
        if (_initializing)
        {
            return;
        }

        // NumberBox reports NaN when the field is cleared; treat that as 0 (invalid).
        _viewModel.AmountUsd = double.IsNaN(args.NewValue) ? 0 : args.NewValue;
        UpdateSaveEnabled();
    }

    private void OnPeriodChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_initializing)
        {
            return;
        }

        _viewModel.Period = PeriodBox.SelectedIndex switch
        {
            0 => BudgetPeriod.Day,
            1 => BudgetPeriod.Week,
            3 => BudgetPeriod.AllTime,
            _ => BudgetPeriod.Month,
        };
    }

    private void OnBehaviorChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_initializing)
        {
            return;
        }

        _viewModel.Behavior = BehaviorBox.SelectedIndex switch
        {
            1 => BudgetBehavior.HardBlock,
            2 => BudgetBehavior.WarnOnly,
            3 => BudgetBehavior.HardBlockWithFallback,
            _ => BudgetBehavior.WarnThenBlock,
        };
    }

    private void OnEnabledToggled(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        if (_initializing)
        {
            return;
        }

        _viewModel.IsEnabled = EnabledSwitch.IsOn;
    }

    private void UpdateSaveEnabled() => IsPrimaryButtonEnabled = _viewModel.CanSave;

    private static int PeriodIndex(BudgetPeriod period) => period switch
    {
        BudgetPeriod.Day => 0,
        BudgetPeriod.Week => 1,
        BudgetPeriod.Month => 2,
        BudgetPeriod.AllTime => 3,
        _ => 2,
    };

    private static int BehaviorIndex(BudgetBehavior behavior) => behavior switch
    {
        BudgetBehavior.WarnThenBlock => 0,
        BudgetBehavior.HardBlock => 1,
        BudgetBehavior.WarnOnly => 2,
        BudgetBehavior.HardBlockWithFallback => 3,
        _ => 0,
    };

    private static Microsoft.UI.Xaml.Visibility Show(bool visible) =>
        visible ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;
}

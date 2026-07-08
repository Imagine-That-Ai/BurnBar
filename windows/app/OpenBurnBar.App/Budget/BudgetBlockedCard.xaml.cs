using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using OpenBurnBar.App.Presentation.Budget;

namespace OpenBurnBar.App.Budget;

/// <summary>
/// The chat "budget limit reached" error card. Call <see cref="SetError"/> with a
/// <see cref="BudgetBlockedCardModel"/> and subscribe to the three action events. Mirrors the
/// Swift <c>BudgetBlockedCard</c> (raise +$25 / allow session / open settings).
/// </summary>
public sealed partial class BudgetBlockedCard : UserControl
{
    private BudgetBlockedCardModel? _model;
    private bool _raised;

    public BudgetBlockedCard()
    {
        InitializeComponent();
        var errorBrush = new SolidColorBrush(BudgetPalette.Error);
        AlertIcon.Foreground = errorBrush;
        UsedText.Foreground = errorBrush;
        Root.BorderBrush = new SolidColorBrush(Windows.UI.Color.FromArgb(0x59, BudgetPalette.Error.R, BudgetPalette.Error.G, BudgetPalette.Error.B));
    }

    /// <summary>The raised rule (amount + $25), ready to hand to <c>UpsertRuleAsync</c>.</summary>
    public event EventHandler<BudgetRule>? RaiseLimitRequested;

    /// <summary>The rule the operator chose to allow for this session.</summary>
    public event EventHandler<BudgetRule>? AllowSessionRequested;

    /// <summary>The operator asked to open Budget Settings.</summary>
    public event EventHandler? OpenSettingsRequested;

    /// <summary>Populate the card from a presented model.</summary>
    public void SetError(BudgetBlockedCardModel model)
    {
        _model = model;
        _raised = false;

        RuleLabelText.Text = model.RuleLabel;
        UsedText.Text = model.UsedText;
        LimitText.Text = model.LimitText;
        PeriodText.Text = model.PeriodLabel;
        ResetText.Text = model.ResetText;
        ResetText.Visibility = model.HasReset ? Visibility.Visible : Visibility.Collapsed;

        RaiseLabel.Text = model.RaiseButtonLabel;
        RaiseIcon.Glyph = ""; // Add
        RaiseButton.IsEnabled = true;
        RaiseButton.Foreground = new SolidColorBrush(BudgetPalette.Coral);
        AllowButton.Foreground = new SolidColorBrush(BudgetPalette.Purple);
    }

    private void Raise_Click(object sender, RoutedEventArgs e)
    {
        if (_model is null || _raised)
        {
            return;
        }

        _raised = true;
        RaiseLabel.Text = "Raised";
        RaiseIcon.Glyph = ""; // Checkmark
        RaiseButton.IsEnabled = false;
        RaiseButton.Foreground = new SolidColorBrush(BudgetPalette.Success);
        RaiseLimitRequested?.Invoke(this, _model.RaisedRule());
    }

    private void Allow_Click(object sender, RoutedEventArgs e)
    {
        if (_model is not null)
        {
            AllowSessionRequested?.Invoke(this, _model.Rule);
        }
    }

    private void Settings_Click(object sender, RoutedEventArgs e) =>
        OpenSettingsRequested?.Invoke(this, EventArgs.Empty);
}

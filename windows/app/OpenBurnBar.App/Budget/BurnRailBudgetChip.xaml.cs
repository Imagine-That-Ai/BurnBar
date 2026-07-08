using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using OpenBurnBar.App.Presentation.Budget;
using Windows.UI;

namespace OpenBurnBar.App.Budget;

/// <summary>
/// The top-rail budget chip. Call <see cref="SetState"/> with the output of
/// <see cref="BurnRailBudgetChipModel.Compute"/>; a <c>null</c> state hides the chip (the
/// Swift "below 50% stays hidden" rule). Tint + glyph + label all come from the portable model.
/// </summary>
public sealed partial class BurnRailBudgetChip : UserControl
{
    public BurnRailBudgetChip()
    {
        InitializeComponent();
    }

    /// <summary>Render (or hide) the chip for a computed state.</summary>
    public void SetState(BudgetChipState? state)
    {
        if (state is null)
        {
            Root.Visibility = Microsoft.UI.Xaml.Visibility.Collapsed;
            return;
        }

        Color tint = BudgetPalette.Severity(state.Severity);
        var tintBrush = new SolidColorBrush(tint);

        Icon.Glyph = BudgetFormat.SeverityGlyph(state.Severity);
        Icon.Foreground = tintBrush;
        AmountText.Text = state.AmountLabel;
        AmountText.Foreground = tintBrush;

        Root.Background = new SolidColorBrush(Color.FromArgb(0x1F, tint.R, tint.G, tint.B));
        Root.BorderBrush = new SolidColorBrush(Color.FromArgb(0x4D, tint.R, tint.G, tint.B));

        ToolTipService.SetToolTip(Root, state.Tooltip);
        AutomationProperties.SetName(this, state.AccessibilityLabel);

        Root.Visibility = Microsoft.UI.Xaml.Visibility.Visible;
    }
}

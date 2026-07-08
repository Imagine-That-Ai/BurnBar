using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace OpenBurnBar.App.Dashboard.Layouts;

/// <summary>
/// A floating glass stat tile: an accent hairline, a big value, and a caption. The
/// shared building block of the five concept layouts (Swift: the concept stat pills /
/// tiles under Layouts/Components/).
/// </summary>
public sealed partial class ConceptStatTile : UserControl
{
    public ConceptStatTile()
    {
        InitializeComponent();
    }

    public string Value
    {
        get => (string)GetValue(ValueProperty);
        set => SetValue(ValueProperty, value);
    }

    public static readonly DependencyProperty ValueProperty = DependencyProperty.Register(
        nameof(Value), typeof(string), typeof(ConceptStatTile), new PropertyMetadata(string.Empty));

    public string Caption
    {
        get => (string)GetValue(CaptionProperty);
        set => SetValue(CaptionProperty, value);
    }

    public static readonly DependencyProperty CaptionProperty = DependencyProperty.Register(
        nameof(Caption), typeof(string), typeof(ConceptStatTile), new PropertyMetadata(string.Empty));

    public Brush AccentBrush
    {
        get => (Brush)GetValue(AccentBrushProperty);
        set => SetValue(AccentBrushProperty, value);
    }

    public static readonly DependencyProperty AccentBrushProperty = DependencyProperty.Register(
        nameof(AccentBrush), typeof(Brush), typeof(ConceptStatTile), new PropertyMetadata(null));
}

using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using OpenBurnBar.App.Presentation.Chat;

namespace OpenBurnBar.App.Chat;

/// <summary>
/// Code-behind for the inline atom chip. Windows peer of the macOS
/// <c>HermesAtomChip</c>. The leading glyph is chosen from the atom's
/// <see cref="HermesAtomKind"/> (the Windows analog of the SF Symbol mapping),
/// and a tap raises <see cref="Invoked"/> so the host can route to the entity.
/// </summary>
public sealed partial class HermesAtomChip : UserControl
{
    public HermesAtomChip()
    {
        InitializeComponent();
    }

    /// Raised when the chip is tapped (peer of <c>HermesAtomRouter.open</c>).
    public event Action<HermesAtom>? Invoked;

    public HermesAtom? Atom
    {
        get => (HermesAtom?)GetValue(AtomProperty);
        set => SetValue(AtomProperty, value);
    }

    public static readonly DependencyProperty AtomProperty = DependencyProperty.Register(
        nameof(Atom), typeof(HermesAtom), typeof(HermesAtomChip),
        new PropertyMetadata(null, OnAtomChanged));

    public string Label
    {
        get => (string)GetValue(LabelProperty);
        set => SetValue(LabelProperty, value);
    }

    public static readonly DependencyProperty LabelProperty = DependencyProperty.Register(
        nameof(Label), typeof(string), typeof(HermesAtomChip),
        new PropertyMetadata(string.Empty, OnLabelChanged));

    private static void OnAtomChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((HermesAtomChip)d).ApplyAtom();

    private static void OnLabelChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((HermesAtomChip)d).ApplyLabel();

    private void ApplyLabel()
    {
        var text = Label;
        LabelText.Text = string.IsNullOrEmpty(text) ? (Atom?.FallbackLabel ?? string.Empty) : text;
    }

    private void ApplyAtom()
    {
        if (Atom is { } atom)
        {
            KindGlyph.Glyph = GlyphFor(atom.Kind);
        }
        ApplyLabel();
    }

    private void OnTapped(object sender, TappedRoutedEventArgs e)
    {
        if (Atom is { } atom)
        {
            Invoked?.Invoke(atom);
        }
    }

    private void OnPointerEntered(object sender, PointerRoutedEventArgs e) => ChipRoot.Opacity = 0.82;

    private void OnPointerExited(object sender, PointerRoutedEventArgs e) => ChipRoot.Opacity = 1.0;

    // Segoe MDL2 Assets glyphs keyed by atom kind (approximate — a design pass
    // finalizes icon parity, matching the shell's own note on approximate glyphs).
    private static string GlyphFor(HermesAtomKind kind) => kind switch
    {
        HermesAtomKind.Cost => "",     // Money
        HermesAtomKind.Session => "",  // History
        HermesAtomKind.Provider => "", // Connected drive
        HermesAtomKind.Model => "",    // KnowledgeArticle
        HermesAtomKind.Window => "",   // Calendar
        HermesAtomKind.Tool => "",     // Repair
        HermesAtomKind.Project => "",  // Folder
        HermesAtomKind.Tokens => "",   // Count / number
        HermesAtomKind.Quota => "",    // Speed gauge
        HermesAtomKind.Runtime => "",  // Streaming
        _ => "",                        // Link
    };
}

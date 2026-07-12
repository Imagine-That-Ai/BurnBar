using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media.Animation;

namespace OpenBurnBar.App.Components;

/// <summary>
/// A frosted-glass card with sheen + luminous edge. Windows peer of
/// <c>OpenBurnBarCore/.../UnifiedGlassCard.swift</c>. The plate routes through the
/// Liquid-Glass chokepoint (<c>theme:LiquidGlass.Surface</c>). Put content in the default
/// content slot; set <see cref="Interactive"/> for the hover scale.
/// </summary>
[ContentProperty(Name = nameof(CardContent))]
public sealed partial class UnifiedGlassCard : UserControl
{
    public UnifiedGlassCard()
    {
        InitializeComponent();
    }

    /// <summary>The hosted content. Mapped from nested XAML via <see cref="ContentPropertyAttribute"/>.</summary>
    public object? CardContent
    {
        get => GetValue(CardContentProperty);
        set => SetValue(CardContentProperty, value);
    }

    public static readonly DependencyProperty CardContentProperty = DependencyProperty.Register(
        nameof(CardContent), typeof(object), typeof(UnifiedGlassCard), new PropertyMetadata(null));

    /// <summary>Whether the card lifts slightly on hover. Swift: <c>UnifiedGlassCard.interactive</c>.</summary>
    public bool Interactive
    {
        get => (bool)GetValue(InteractiveProperty);
        set => SetValue(InteractiveProperty, value);
    }

    public static readonly DependencyProperty InteractiveProperty = DependencyProperty.Register(
        nameof(Interactive), typeof(bool), typeof(UnifiedGlassCard),
        new PropertyMetadata(false, OnInteractiveChanged));

    private static void OnInteractiveChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        var card = (UnifiedGlassCard)d;
        if ((bool)e.NewValue)
        {
            card.PointerEntered += card.OnPointerEnteredCard;
            card.PointerExited += card.OnPointerExitedCard;
        }
        else
        {
            card.PointerEntered -= card.OnPointerEnteredCard;
            card.PointerExited -= card.OnPointerExitedCard;
        }
    }

    private void OnPointerEnteredCard(object sender, RoutedEventArgs e) => AnimateScale(1.015);

    private void OnPointerExitedCard(object sender, RoutedEventArgs e) => AnimateScale(1.0);

    private void AnimateScale(double target)
    {
        // Swift: .scaleEffect(isHovered ? 1.015 : 1) with the hover animation.
        var storyboard = new Storyboard();
        foreach (string property in new[] { "ScaleX", "ScaleY" })
        {
            var animation = new DoubleAnimation
            {
                To = target,
                Duration = new Duration(System.TimeSpan.FromMilliseconds(140)),
                EnableDependentAnimation = true,
            };
            Storyboard.SetTarget(animation, RootScale);
            Storyboard.SetTargetProperty(animation, property);
            storyboard.Children.Add(animation);
        }

        storyboard.Begin();
    }
}

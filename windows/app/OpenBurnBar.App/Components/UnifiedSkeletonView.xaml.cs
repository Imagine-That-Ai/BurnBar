using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Windows.UI.ViewManagement;

namespace OpenBurnBar.App.Components;

/// <summary>
/// Ember-tinted shimmer loading placeholder. Windows peer of
/// <c>OpenBurnBarCore/.../UnifiedSkeletonView.swift</c>. The gradient sweeps left→right on a
/// 1.5s linear loop (Swift: <c>.linear(duration: 1.5).repeatForever</c>) and holds static when
/// Reduce Motion is on (Swift: <c>accessibilityReduceMotion</c>).
/// </summary>
public sealed partial class UnifiedSkeletonView : UserControl
{
    private static readonly UISettings SharedUiSettings = new();
    private Storyboard? _storyboard;

    public UnifiedSkeletonView()
    {
        InitializeComponent();
        Height = 16;
        Loaded += (_, _) => RestartIfPossible();
        Unloaded += (_, _) => _storyboard?.Stop();
    }

    /// <summary>Bar height in DIPs. Swift: <c>UnifiedSkeletonView.height</c> (default 16).</summary>
    public double BarHeight
    {
        get => (double)GetValue(BarHeightProperty);
        set => SetValue(BarHeightProperty, value);
    }

    public static readonly DependencyProperty BarHeightProperty = DependencyProperty.Register(
        nameof(BarHeight), typeof(double), typeof(UnifiedSkeletonView),
        new PropertyMetadata(16.0, OnBarHeightChanged));

    /// <summary>Corner radius. Swift: <c>UnifiedSkeletonView.cornerRadius</c> (default 8).</summary>
    public double Radius
    {
        get => (double)GetValue(RadiusProperty);
        set => SetValue(RadiusProperty, value);
    }

    public static readonly DependencyProperty RadiusProperty = DependencyProperty.Register(
        nameof(Radius), typeof(double), typeof(UnifiedSkeletonView),
        new PropertyMetadata(8.0, OnRadiusChanged));

    private static void OnBarHeightChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        var view = (UnifiedSkeletonView)d;
        view.Height = (double)e.NewValue;
    }

    private static void OnRadiusChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        var view = (UnifiedSkeletonView)d;
        view.TrackBorder.CornerRadius = new CornerRadius((double)e.NewValue);
    }

    private void OnRootSizeChanged(object sender, SizeChangedEventArgs e)
    {
        double width = e.NewSize.Width;
        if (width > 0)
        {
            // The shimmer band is 60% of the width, matching the Swift `geo.size.width * 0.6`.
            Shimmer.Width = width * 0.6;
            Shimmer.Height = e.NewSize.Height;
            RestartIfPossible();
        }
    }

    private bool ReduceMotion
    {
        get
        {
            try
            {
                return !SharedUiSettings.AnimationsEnabled;
            }
            catch (Exception)
            {
                return false;
            }
        }
    }

    private void RestartIfPossible()
    {
        _storyboard?.Stop();

        double width = ActualWidth;
        if (width <= 0 || ReduceMotion)
        {
            ShimmerTransform.X = 0;
            return;
        }

        var animation = new DoubleAnimation
        {
            From = -width * 0.6,
            To = width,
            Duration = new Duration(TimeSpan.FromSeconds(1.5)),
            RepeatBehavior = RepeatBehavior.Forever,
            EnableDependentAnimation = true,
        };

        Storyboard.SetTarget(animation, ShimmerTransform);
        Storyboard.SetTargetProperty(animation, "X");

        _storyboard = new Storyboard();
        _storyboard.Children.Add(animation);
        _storyboard.Begin();
    }
}

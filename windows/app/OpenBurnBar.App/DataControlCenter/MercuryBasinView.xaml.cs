using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Presentation.DataControlCenter;
using OpenBurnBar.App.Diagnostics;
using OpenBurnBar.App.Shell;

namespace OpenBurnBar.App.DataControlCenter;

/// <summary>
/// The mercury Basin UserControl. Hosts the Win2D <see cref="MercuryBasinHost"/> and exposes
/// <see cref="Fill"/> (0…1 sealed fraction) + <see cref="Caption"/>. The GPU swirl is Windows/CI-
/// deferred; the fill→surface + caption math is the portable, unit-tested BasinModel.
/// </summary>
public sealed partial class MercuryBasinView : UserControl
{
    private MercuryBasinHost? _host;

    public MercuryBasinView()
    {
        InitializeComponent();
        if (NativeCapability.IsWin2DEnabled(out _))
        {
            try
            {
                _host = new MercuryBasinHost();
                CanvasHostBorder.Child = _host.Control;
            }
            catch (Exception ex)
            {
                AppDiagnostics.LogException("datacontrol.mercury", ex);
                _host = null;
                CanvasHostBorder.Child = null;
            }
        }

        CaptionText.Text = BasinModel.SealedCaption(0);

        Loaded += (_, _) =>
        {
            if (_host is not null)
            {
                _host.Fill = Fill;
            }
        };
        Unloaded += (_, _) => _host?.Dispose();
    }

    /// <summary>The 0…1 sealed-data fraction driving the mercury fill height.</summary>
    public double Fill
    {
        get => (double)GetValue(FillProperty);
        set => SetValue(FillProperty, value);
    }

    public static readonly DependencyProperty FillProperty = DependencyProperty.Register(
        nameof(Fill),
        typeof(double),
        typeof(MercuryBasinView),
        new PropertyMetadata(0.0, OnFillChanged));

    /// <summary>The overlaid "NN% sealed" caption.</summary>
    public string Caption
    {
        get => (string)GetValue(CaptionProperty);
        set => SetValue(CaptionProperty, value);
    }

    public static readonly DependencyProperty CaptionProperty = DependencyProperty.Register(
        nameof(Caption),
        typeof(string),
        typeof(MercuryBasinView),
        new PropertyMetadata(string.Empty, OnCaptionChanged));

    /// <summary>Freeze the swirl for accessibilityReduceMotion.</summary>
    public bool ReduceMotion
    {
        get => _host?.ReduceMotion ?? false;
        set
        {
            if (_host is not null)
            {
                _host.ReduceMotion = value;
            }
        }
    }

    private static void OnFillChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is MercuryBasinView view)
        {
            if (view._host is not null)
            {
                view._host.Fill = (double)e.NewValue;
            }
            if (string.IsNullOrEmpty(view.Caption))
            {
                view.CaptionText.Text = BasinModel.SealedCaption((double)e.NewValue);
            }
        }
    }

    private static void OnCaptionChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is MercuryBasinView view && e.NewValue is string caption)
        {
            view.CaptionText.Text = string.IsNullOrEmpty(caption)
                ? BasinModel.SealedCaption(view.Fill)
                : caption;
        }
    }
}

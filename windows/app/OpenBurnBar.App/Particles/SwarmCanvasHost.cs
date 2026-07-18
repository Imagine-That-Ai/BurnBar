// WINDOWS-ONLY / CI-DEFERRED (Win2D + WinUI). See Win2DSubstrateDrawingSession.cs header.

using System;
using System.Diagnostics;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using OpenBurnBar.Particles.Model;
using OpenBurnBar.Particles.Substrates;
using WinColor = Windows.UI.Color;

namespace OpenBurnBar.App.Particles;

/// <summary>
/// The Win2D renderer HOST for the particle-engine substrate layer — the Windows
/// analog of the macOS <c>SwarmCanvasView</c> draw loop
/// (<c>OpenBurnBarCore/.../Views/SwarmCanvasView.swift</c> +
/// <c>SwarmCanvasView+Substrate.swift</c>).
/// </summary>
/// <remarks>
/// Owns a XAML <see cref="Image"/> backed by a Win2D <see cref="CanvasImageSource"/>
/// and redraws it from the compositor render tick. SurfaceImageSource participates in
/// normal XAML z-order, unlike the native CanvasControl/WebView surfaces that can cover
/// sibling dashboard content. Each frame it:
/// <list type="number">
///   <item>Asks <see cref="FrameProvider"/> for the current
///   <see cref="SwarmSubstrateFrame"/> — in production this decodes the per-frame
///   snapshot vended by Swift Core over FFI (see
///   <c>OpenBurnBar.Particles/Ffi/SwarmSubstrateFrameFfi.cs</c>); the C# side never
///   runs the simulation.</item>
///   <item>Wraps <c>args.DrawingSession</c> in a <see cref="Win2DSubstrateDrawingSession"/>.</item>
///   <item>Calls the active <see cref="ISwarmSubstrate"/>'s <c>Paint</c>. A
///   <c>false</c> return means "defer to plain dots" — the host then runs the
///   default dot pass (the analog of the engine's built-in dot loop).</item>
/// </list>
/// The parity-critical painters live in the platform-agnostic
/// <c>OpenBurnBar.Particles</c> lib (built + perf-verified on macOS); this host is
/// the thin GPU binding that only Windows/CI exercises live.
/// </remarks>
public sealed class SwarmCanvasHost : IDisposable
{
    private readonly GlowSpriteCache _sprites = new();
    private readonly ShaftSpriteCache _shafts = new();
    private readonly Stopwatch _clock = Stopwatch.StartNew();
    private CanvasDevice _device;
    private CanvasImageSource? _imageSource;
    private ISwarmSubstrate _substrate = new PlainDotsSubstrate();
    private bool _renderingSubscribed;
    private bool _paused;
    private bool _rendering;
    private bool _disposed;
    private TimeSpan _lastFrame;

    public SwarmCanvasHost()
    {
        _device = CanvasDevice.GetSharedDevice();
        _device.DeviceLost += OnDeviceLost;
        Control = new Image
        {
            Stretch = Stretch.Fill,
            IsHitTestVisible = false,
        };
        Control.Loaded += OnLoaded;
        Control.Unloaded += OnUnloaded;
        Control.SizeChanged += OnSizeChanged;
    }

    /// <summary>The airspace-free XAML element to place in the visual tree.</summary>
    public Image Control { get; }

    /// <summary>Stops invalidation while another backdrop is active or the page is hidden.</summary>
    public bool Paused
    {
        get => _paused;
        set
        {
            _paused = value;
            if (!value && Control.IsLoaded && _imageSource is null)
            {
                RecreateImageSource();
            }
        }
    }

    /// <summary>The active substrate painter (defaults to <see cref="PlainDotsSubstrate"/>).</summary>
    public ISwarmSubstrate Substrate
    {
        get => _substrate;
        set => _substrate = value ?? new PlainDotsSubstrate();
    }

    /// <summary>
    /// Supplies the current decoded frame for a given canvas size + elapsed time.
    /// In production this calls the Swift-Core FFI vend + <c>SwarmSubstrateFrameFfi.Decode</c>.
    /// </summary>
    public Func<Windows.Foundation.Size, TimeSpan, SwarmSubstrateFrame?>? FrameProvider { get; set; }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (_renderingSubscribed)
        {
            return;
        }

        CompositionTarget.Rendering += OnRendering;
        _renderingSubscribed = true;
        RecreateImageSource();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e) => UnsubscribeRendering();

    private void OnRendering(object? sender, object args)
    {
        if (_disposed || _paused || _rendering || Control.Visibility != Visibility.Visible || _imageSource is null)
        {
            return;
        }

        TimeSpan now = _clock.Elapsed;
        // The substrate field is ambient. Thirty frames per second keeps it fluid while
        // avoiding duplicate redraws on high-refresh displays.
        if (now - _lastFrame < TimeSpan.FromMilliseconds(30))
        {
            return;
        }

        _rendering = true;
        try
        {
            RenderFrame(now);
            _lastFrame = now;
        }
        catch (Exception ex) when (_device.IsDeviceLost(ex.HResult))
        {
            RecreateDevice();
        }
        finally
        {
            _rendering = false;
        }
    }

    private void RenderFrame(TimeSpan elapsed)
    {
        if (_imageSource is null)
        {
            return;
        }

        var size = new Windows.Foundation.Size(Control.ActualWidth, Control.ActualHeight);
        SwarmSubstrateFrame? frame = FrameProvider?.Invoke(size, elapsed);
        if (frame is null) return;

        using CanvasDrawingSession drawingSession = _imageSource.CreateDrawingSession(
            WinColor.FromArgb(0, 0, 0, 0));
        var session = new Win2DSubstrateDrawingSession(drawingSession, _sprites, _shafts);
        bool handled = _substrate.Paint(frame, session);
        if (!handled)
        {
            DrawPlainDots(frame, session);
        }
    }

    /// <summary>
    /// The default dot pass — the analog of the engine's built-in dot render that
    /// runs when a substrate returns <c>false</c> (i.e. plain dots). A simple
    /// filled circle per dot at its resolved color; the twinkle/glyph passes land
    /// with the full Dashboard port (Bucket C).
    /// </summary>
    private static void DrawPlainDots(SwarmSubstrateFrame frame, Win2DSubstrateDrawingSession session)
    {
        session.Blend = frame.Dark ? OpenBurnBar.Particles.Drawing.SubstrateBlend.Add : OpenBurnBar.Particles.Drawing.SubstrateBlend.Normal;
        SwarmSubstrateDot[] dots = frame.Dots;
        for (int i = 0; i < dots.Length; i++)
        {
            SwarmSubstrateDot d = dots[i];
            session.FillCircle(d.X, d.Y, d.Radius, d.Rgba);
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        UnsubscribeRendering();
        _device.DeviceLost -= OnDeviceLost;
        Control.Loaded -= OnLoaded;
        Control.Unloaded -= OnUnloaded;
        Control.SizeChanged -= OnSizeChanged;
        Control.Source = null;
        _imageSource = null;
    }

    private void OnSizeChanged(object sender, SizeChangedEventArgs e) => RecreateImageSource();

    private void RecreateImageSource()
    {
        if (_disposed)
        {
            return;
        }

        int width = (int)Math.Ceiling(Control.ActualWidth);
        int height = (int)Math.Ceiling(Control.ActualHeight);
        if (width < 1 || height < 1)
        {
            return;
        }

        Control.Source = null;
        _imageSource = new CanvasImageSource(_device, width, height, 96);
        Control.Source = _imageSource;
        _lastFrame = TimeSpan.Zero;
    }

    private void OnDeviceLost(CanvasDevice sender, object args)
    {
        if (!_disposed)
        {
            Control.DispatcherQueue.TryEnqueue(RecreateDevice);
        }
    }

    private void RecreateDevice()
    {
        if (_disposed)
        {
            return;
        }

        _device.DeviceLost -= OnDeviceLost;
        _device = CanvasDevice.GetSharedDevice();
        _device.DeviceLost += OnDeviceLost;
        RecreateImageSource();
    }

    private void UnsubscribeRendering()
    {
        if (!_renderingSubscribed)
        {
            return;
        }

        CompositionTarget.Rendering -= OnRendering;
        _renderingSubscribed = false;
    }
}

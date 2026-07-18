// WINDOWS-ONLY / CI-DEFERRED (Win2D + WinUI). See Win2DSubstrateDrawingSession.cs header.

using System;
using System.Diagnostics;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Controls;
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
/// Owns a XAML-composited <see cref="CanvasControl"/> and invalidates it from the
/// compositor render tick. This preserves the animated Win2D renderer without the
/// swap-chain airspace that can cover sibling XAML content. Each frame it:
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
    private ISwarmSubstrate _substrate = new PlainDotsSubstrate();
    private bool _renderingSubscribed;
    private bool _paused;

    public SwarmCanvasHost()
    {
        Control = new CanvasControl
        {
            ClearColor = WinColor.FromArgb(0, 0, 0, 0),
        };
        Control.Draw += OnDraw;
        Control.Loaded += OnLoaded;
        Control.Unloaded += OnUnloaded;
    }

    /// <summary>The XAML-composited Win2D element to place in the visual tree.</summary>
    public CanvasControl Control { get; }

    /// <summary>Stops invalidation while another backdrop is active or the page is hidden.</summary>
    public bool Paused
    {
        get => _paused;
        set
        {
            _paused = value;
            if (!value && Control.IsLoaded)
            {
                Control.Invalidate();
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
        Control.Invalidate();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e) => UnsubscribeRendering();

    private void OnRendering(object? sender, object args)
    {
        if (!_paused && Control.Visibility == Visibility.Visible)
        {
            Control.Invalidate();
        }
    }

    private void OnDraw(CanvasControl sender, CanvasDrawEventArgs args)
    {
        SwarmSubstrateFrame? frame = FrameProvider?.Invoke(sender.Size, _clock.Elapsed);
        if (frame is null) return;

        var session = new Win2DSubstrateDrawingSession(args.DrawingSession, _sprites, _shafts);
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
        UnsubscribeRendering();
        Control.Loaded -= OnLoaded;
        Control.Unloaded -= OnUnloaded;
        Control.Draw -= OnDraw;
        Control.RemoveFromVisualTree();
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

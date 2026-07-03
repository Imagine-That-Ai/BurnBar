// WINDOWS-ONLY / CI-DEFERRED (Win2D + WinUI). See Win2DSubstrateDrawingSession.cs header.

using System;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.UI;
using Microsoft.Graphics.Canvas.UI.Xaml;
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
/// Owns a <see cref="CanvasAnimatedControl"/> (hardware-accelerated, retained-mode,
/// vsync-driven — the WinUI 3 equivalent of SwiftUI's <c>TimelineView</c>-driven
/// <c>Canvas</c>). Each frame it:
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
    private ISwarmSubstrate _substrate = new PlainDotsSubstrate();

    public SwarmCanvasHost()
    {
        Control = new CanvasAnimatedControl
        {
            ClearColor = WinColor.FromArgb(0, 0, 0, 0),
        };
        Control.CreateResources += OnCreateResources;
        Control.Draw += OnDraw;
    }

    /// <summary>The XAML element to place in the visual tree.</summary>
    public CanvasAnimatedControl Control { get; }

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

    private void OnCreateResources(CanvasAnimatedControl sender, CanvasCreateResourcesEventArgs args)
    {
        // Sprites are baked lazily on first Resolve; nothing eager to load here yet.
    }

    private void OnDraw(ICanvasAnimatedControl sender, CanvasAnimatedDrawEventArgs args)
    {
        SwarmSubstrateFrame? frame = FrameProvider?.Invoke(sender.Size, args.Timing.TotalTime);
        if (frame is null) return;

        var session = new Win2DSubstrateDrawingSession(args.DrawingSession, _sprites);
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
        Control.CreateResources -= OnCreateResources;
        Control.Draw -= OnDraw;
        Control.RemoveFromVisualTree();
    }
}

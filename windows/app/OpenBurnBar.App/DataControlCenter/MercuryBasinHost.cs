// WINDOWS-ONLY / CI-DEFERRED (Win2D + WinUI). The GPU binding for the mercury Basin.
//
// The Windows analog of the macOS TimelineView + Canvas mercury swirl in
// AgentLens/Views/Settings/DataControlCenter/DataControlCenterBasin.swift. Like the particle
// SwarmCanvasHost, it owns a CanvasAnimatedControl (hardware-accelerated, vsync-driven — the WinUI
// equivalent of SwiftUI's TimelineView-driven Canvas) and, each frame, asks the platform-agnostic
// OpenBurnBar.App.Presentation.DataControlCenter.BasinModel for the meniscus polygon, sheen band,
// and drifting beads, then paints them with mercury-token gradients. The parity-critical GEOMETRY
// is the portable BasinModel (unit-tested on macOS); this host is the thin GPU paint only.

using System;
using System.Numerics;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Brushes;
using Microsoft.Graphics.Canvas.Geometry;
using Microsoft.Graphics.Canvas.UI.Xaml;
using OpenBurnBar.App.Presentation.DataControlCenter;
using WinColor = Windows.UI.Color;

namespace OpenBurnBar.App.DataControlCenter;

/// <summary>The Win2D renderer host for the mercury Basin.</summary>
public sealed class MercuryBasinHost : IDisposable
{
    // Mercury tokens (Theme/Tokens.xaml PensieveColorMercury*): bright / core / deep.
    private static readonly WinColor MercuryBright = WinColor.FromArgb(0xFF, 0xF4, 0xF6, 0xFB);
    private static readonly WinColor MercuryCore = WinColor.FromArgb(0xFF, 0xC7, 0xCF, 0xDD);
    private static readonly WinColor MercuryDeep = WinColor.FromArgb(0xFF, 0x8B, 0x94, 0xA8);

    private double _fill;
    private bool _reduceMotion;

    public MercuryBasinHost()
    {
        Control = new CanvasAnimatedControl
        {
            ClearColor = WinColor.FromArgb(0, 0, 0, 0),
        };
        Control.Draw += OnDraw;
    }

    /// <summary>The XAML element to place in the visual tree (behind the rim + caption overlays).</summary>
    public CanvasAnimatedControl Control { get; }

    /// <summary>Swirl period in seconds, from the Pensieve <c>motionSwirlSeconds</c> token (18).</summary>
    public double SwirlSeconds { get; set; } = BasinModel.DefaultSwirlSeconds;

    /// <summary>0…1 basin fill (the sealed-data fraction). Clamped when drawn.</summary>
    public double Fill
    {
        get => _fill;
        set => _fill = value;
    }

    /// <summary>When set, the swirl freezes at a representative phase (accessibilityReduceMotion).</summary>
    public bool ReduceMotion
    {
        get => _reduceMotion;
        set
        {
            _reduceMotion = value;
            Control.Paused = value;
        }
    }

    private void OnDraw(ICanvasAnimatedControl sender, CanvasAnimatedDrawEventArgs args)
    {
        var size = sender.Size;
        double width = size.Width;
        double height = size.Height;
        if (width <= 0 || height <= 0)
        {
            return;
        }

        double phase = BasinModel.SwirlPhase(args.Timing.TotalTime.TotalSeconds, SwirlSeconds, _reduceMotion);
        double surfaceY = BasinModel.SurfaceY(height, _fill);

        CanvasDrawingSession ds = args.DrawingSession;

        // ── Mercury body: the closed meniscus polygon, filled with a vertical mercury gradient. ──
        var outline = BasinModel.MercuryOutline(width, height, surfaceY, phase);
        var points = new Vector2[outline.Count];
        for (int i = 0; i < outline.Count; i++)
        {
            points[i] = new Vector2((float)outline[i].X, (float)outline[i].Y);
        }

        using (var body = CanvasGeometry.CreatePolygon(sender, points))
        using (var gradient = new CanvasLinearGradientBrush(sender, new[]
               {
                   new CanvasGradientStop { Position = 0f, Color = WithAlpha(MercuryBright, 0.92) },
                   new CanvasGradientStop { Position = 0.5f, Color = WithAlpha(MercuryCore, 0.80) },
                   new CanvasGradientStop { Position = 1f, Color = WithAlpha(MercuryDeep, 0.66) },
               })
               {
                   StartPoint = new Vector2((float)(width / 2), (float)surfaceY),
                   EndPoint = new Vector2((float)(width / 2), (float)height),
               })
        {
            ds.FillGeometry(body, gradient);
        }

        // ── Specular sheen: a thin bright band drifting across the surface. ──
        var sheen = BasinModel.SheenBand(width, surfaceY, phase);
        ds.FillRoundedRectangle(
            new Windows.Foundation.Rect(sheen.X, sheen.Y, sheen.Width, sheen.Height),
            2.5f, 2.5f,
            WithAlpha(MercuryBright, 0.42));

        // ── Drifting beads near the surface. ──
        foreach (var bead in BasinModel.Beads(width, surfaceY, phase))
        {
            ds.FillCircle(new Vector2((float)bead.X, (float)bead.Y), (float)bead.Radius, WithAlpha(MercuryBright, 0.5));
        }
    }

    private static WinColor WithAlpha(WinColor color, double alpha) =>
        WinColor.FromArgb((byte)Math.Clamp(alpha * 255, 0, 255), color.R, color.G, color.B);

    public void Dispose()
    {
        Control.Draw -= OnDraw;
        Control.RemoveFromVisualTree();
    }
}

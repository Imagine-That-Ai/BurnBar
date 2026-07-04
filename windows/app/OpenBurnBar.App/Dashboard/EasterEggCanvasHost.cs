// WINDOWS-ONLY / CI-DEFERRED (Win2D). The frame-stepped SIMULATION it draws lives in the
// portable OpenBurnBar.App.Dashboard lib (unit-tested on macOS, windows/tests/dashboard);
// this file is the thin Win2D binding — the analog of the SwiftUI TimelineView+Canvas in
// EasterEggEventCanvas.swift that steps EasterEggSimulation and draws its particle arrays.

using System;
using System.Numerics;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Brushes;
using Microsoft.Graphics.Canvas.Geometry;
using Microsoft.Graphics.Canvas.UI.Xaml;
using OpenBurnBar.App.Dashboard.EasterEgg;
using WinColor = Windows.UI.Color;

namespace OpenBurnBar.App.Dashboard;

/// <summary>
/// The SECOND Win2D <see cref="CanvasAnimatedControl"/> on the dashboard (the first is the
/// backdrop swarm): a hit-test-disabled overlay that idles paused at zero cost until the
/// <see cref="EasterEggController"/> presents an event, then steps + draws a
/// <see cref="EasterEggSimulation"/> for the event's lifetime and tears back down. Coins and
/// clouds are drawn procedurally to match the burnbar.ai <c>#bgFx</c> gradients; logo sprites
/// render as tinted marks for now (imageset parity is a later asset pass).
/// </summary>
public sealed class EasterEggCanvasHost : IDisposable
{
    private readonly CanvasAnimatedControl _control;
    private EasterEggSimulation? _sim;
    private EasterEggEvent? _event;
    private double? _startMs;
    private double _lastNowMs = -1;
    private bool _finishRaised;

    public EasterEggCanvasHost()
    {
        _control = new CanvasAnimatedControl
        {
            ClearColor = WinColor.FromArgb(0, 0, 0, 0),
            IsHitTestVisible = false,
            Paused = true,
        };
        _control.Draw += OnDraw;
    }

    /// <summary>The overlay control to place ABOVE the dashboard content.</summary>
    public CanvasAnimatedControl Control => _control;

    /// <summary>Raised (on the UI thread) once an event has fully played out.</summary>
    public event EventHandler<Guid>? Finished;

    /// <summary>Begin playing an event. Idempotent-safe: a new event supersedes any prior.</summary>
    public void Play(EasterEggEvent easterEgg, bool reduceMotion)
    {
        _event = easterEgg;
        _sim = new EasterEggSimulation(easterEgg.Kind, easterEgg.Edge, reduceMotion);
        _startMs = null;
        _lastNowMs = -1;
        _finishRaised = false;
        _control.Paused = false;
    }

    private void OnDraw(ICanvasAnimatedControl sender, CanvasAnimatedDrawEventArgs args)
    {
        EasterEggSimulation? sim = _sim;
        EasterEggEvent? ev = _event;
        if (sim is null || ev is null)
        {
            return;
        }

        double w = sender.Size.Width;
        double h = sender.Size.Height;
        double totalMs = args.Timing.TotalTime.TotalMilliseconds;

        if (_startMs is null)
        {
            _startMs = totalMs;
            sim.Begin(0, w, h);
            _lastNowMs = 0;
        }

        double now = totalMs - _startMs.Value;
        double dt = _lastNowMs >= 0 ? Math.Min(0.05, (now - _lastNowMs) / 1000.0) : 0.016;
        _lastNowMs = now;

        sim.UpdateSize(w, h);
        sim.Step(now, Math.Max(0, dt));

        Draw(args.DrawingSession, sim, now);

        // Time-based teardown (survives Reduce Motion, where the sim is inert).
        if (!_finishRaised && now >= ev.DurationSeconds * 1000.0)
        {
            _finishRaised = true;
            _control.Paused = true;
            Guid id = ev.Id;
            _sim = null;
            _event = null;
            _control.DispatcherQueue.TryEnqueue(() => Finished?.Invoke(this, id));
        }
    }

    private static void Draw(CanvasDrawingSession ds, EasterEggSimulation sim, double now)
    {
        switch (sim.Mode)
        {
            case SimulationMode.Storm:
                DrawStorm(ds, sim, now);
                break;
            case SimulationMode.Rain:
                DrawRain(ds, sim, now);
                break;
            case SimulationMode.Idle:
                break;
        }

        foreach (EdgeCoin coin in sim.EdgeCoins)
        {
            DrawToken(ds, coin.Token, coin.Alpha);
        }
    }

    // MARK: - Storm

    private static void DrawStorm(CanvasDrawingSession ds, EasterEggSimulation sim, double now)
    {
        double env = sim.StormEnvelope(now);
        if (env <= 0)
        {
            return;
        }

        foreach (Spark s in sim.Sparks)
        {
            double a = sim.SparkAlpha(s, now);
            if (a <= 0.01)
            {
                continue;
            }

            WinColor tint = SparkTint(s.Li, Clamp01(a));
            float scale = (float)(s.Size / 64.0);
            Matrix3x2 saved = ds.Transform;
            ds.Transform =
                Matrix3x2.CreateScale(scale, scale) *
                Matrix3x2.CreateRotation((float)s.Rot) *
                Matrix3x2.CreateTranslation((float)s.X, (float)s.Y);
            // Procedural crest mark: filled disc + a luminous ring (imageset parity later).
            ds.FillCircle(0, 0, 26, tint);
            ds.DrawCircle(0, 0, 30, WinColor.FromArgb((byte)(Clamp01(a) * 180), 255, 255, 255), 3f);
            ds.Transform = saved;
        }
    }

    // MARK: - Rain

    private static void DrawRain(CanvasDrawingSession ds, EasterEggSimulation sim, double now)
    {
        foreach (Cloud cl in sim.Clouds)
        {
            DrawCloud(ds, cl, now);
        }

        double fade = sim.RainFade(now);
        foreach (Token t in sim.Tokens)
        {
            DrawToken(ds, t, fade);
        }
    }

    /// <summary>Edge-on-flip coin render — a faithful port of Swift <c>drawToken</c>.</summary>
    private static void DrawToken(CanvasDrawingSession ds, in Token t, double alpha)
    {
        if (alpha <= 0)
        {
            return;
        }

        double flip = Math.Abs(Math.Cos(t.Flip));
        float rr = (float)t.R;
        double a = Clamp01(alpha);

        Matrix3x2 saved = ds.Transform;
        ds.Transform =
            Matrix3x2.CreateScale((float)Math.Max(0.12, flip), 1f) *
            Matrix3x2.CreateRotation((float)t.Tilt) *
            Matrix3x2.CreateTranslation((float)t.X, (float)t.Y);

        if (flip < 0.16)
        {
            // Edge-on: a thin rim bar.
            WinColor rim = t.Gold ? Hex("b8860b", a) : Hex("9aa3ad", a);
            ds.FillRectangle(-rr * 0.22f, -rr, rr * 0.44f, rr * 2f, rim);
            ds.Transform = saved;
            return;
        }

        // Face: radial gradient centred up-left.
        CanvasGradientStop[] stops = t.Gold
            ? new[]
            {
                new CanvasGradientStop { Position = 0f, Color = Hex("fff6d8", a) },
                new CanvasGradientStop { Position = 0.45f, Color = Hex("fdc42c", a) },
                new CanvasGradientStop { Position = 1f, Color = Hex("9a6b0a", a) },
            }
            : new[]
            {
                new CanvasGradientStop { Position = 0f, Color = Hex("ffffff", a) },
                new CanvasGradientStop { Position = 0.45f, Color = Hex("e3e9ee", a) },
                new CanvasGradientStop { Position = 1f, Color = Hex("929aa6", a) },
            };
        using (var face = new CanvasRadialGradientBrush(ds, stops)
        {
            Center = new Vector2(-rr * 0.35f, -rr * 0.4f),
            RadiusX = rr,
            RadiusY = rr,
        })
        {
            ds.FillEllipse(0, 0, rr, rr, face);
        }

        // Inner ring (rim).
        WinColor ringColor = t.Gold ? Hex("7c5208", a * 0.6) : Hex("7d858f", a * 0.6);
        ds.DrawEllipse(0, 0, rr * 0.82f, rr * 0.82f, ringColor, Math.Max(1f, rr * 0.13f));

        // Specular highlight.
        ds.FillEllipse(-rr * 0.32f, -rr * 0.34f, rr * 0.22f, rr * 0.22f,
            WinColor.FromArgb((byte)(a * 0.85 * 255), 255, 255, 255));

        ds.Transform = saved;
    }

    /// <summary>One fluffy cloud — a faithful port of Swift <c>drawCloud</c> (4 puffs + base).</summary>
    private static void DrawCloud(CanvasDrawingSession ds, in Cloud cl, double now)
    {
        double x = cl.X;
        double y = cl.Y + (Math.Sin((now * 0.0008) + cl.Seed) * 4.0);
        double w = cl.W;
        double h = w * 0.46;

        // Shadow.
        FillPuff(ds, x, y + (h * 0.3), w * 0.9, h * 0.7,
            WinColor.FromArgb((byte)(0.10 * 255), 44, 48, 56));

        // Body — vertical gradient, filled per-piece (a linear brush colours by position,
        // so overlapping fills match a single-path fill exactly).
        var bodyStops = new[]
        {
            new CanvasGradientStop { Position = 0f, Color = WinColor.FromArgb((byte)(0.94 * 255), 216, 220, 226) },
            new CanvasGradientStop { Position = 0.55f, Color = WinColor.FromArgb((byte)(0.92 * 255), 178, 184, 192) },
            new CanvasGradientStop { Position = 1f, Color = WinColor.FromArgb((byte)(0.90 * 255), 150, 156, 165) },
        };
        using (var body = new CanvasLinearGradientBrush(ds, bodyStops)
        {
            StartPoint = new Vector2((float)x, (float)(y - (h * 0.7))),
            EndPoint = new Vector2((float)x, (float)(y + (h * 0.7))),
        })
        {
            FillPuff(ds, x, y, w, h, body);
        }

        // Highlight crest.
        FillPuff(ds, x, y - (h * 0.2), w * 0.66, h * 0.5,
            WinColor.FromArgb((byte)(0.34 * 255), 255, 255, 255));
    }

    // 4 overlapping circles + a base rect, filled with a solid color.
    private static void FillPuff(CanvasDrawingSession ds, double x, double y, double w, double h, WinColor color)
    {
        ds.FillEllipse((float)(x - (w * 0.34)), (float)(y + (h * 0.05)), (float)(h * 0.50), (float)(h * 0.50), color);
        ds.FillEllipse((float)(x - (w * 0.12)), (float)(y - (h * 0.12)), (float)(h * 0.64), (float)(h * 0.64), color);
        ds.FillEllipse((float)(x + (w * 0.12)), (float)(y - (h * 0.16)), (float)(h * 0.68), (float)(h * 0.68), color);
        ds.FillEllipse((float)(x + (w * 0.34)), (float)(y + (h * 0.02)), (float)(h * 0.54), (float)(h * 0.54), color);
        ds.FillRectangle((float)(x - (w * 0.46)), (float)(y - 2), (float)(w * 0.92), (float)(h * 0.56), color);
    }

    // Filled with a brush overload.
    private static void FillPuff(CanvasDrawingSession ds, double x, double y, double w, double h, ICanvasBrush brush)
    {
        ds.FillEllipse((float)(x - (w * 0.34)), (float)(y + (h * 0.05)), (float)(h * 0.50), (float)(h * 0.50), brush);
        ds.FillEllipse((float)(x - (w * 0.12)), (float)(y - (h * 0.12)), (float)(h * 0.64), (float)(h * 0.64), brush);
        ds.FillEllipse((float)(x + (w * 0.12)), (float)(y - (h * 0.16)), (float)(h * 0.68), (float)(h * 0.68), brush);
        ds.FillEllipse((float)(x + (w * 0.34)), (float)(y + (h * 0.02)), (float)(h * 0.54), (float)(h * 0.54), brush);
        ds.FillRectangle((float)(x - (w * 0.46)), (float)(y - 2), (float)(w * 0.92), (float)(h * 0.56), brush);
    }

    // A small deterministic tint palette so storm crests read as varied brand marks
    // until the real imageset deck is wired.
    private static readonly WinColor[] SparkPalette =
    {
        WinColor.FromArgb(255, 250, 80, 83),   // ember
        WinColor.FromArgb(255, 139, 92, 246),  // violet
        WinColor.FromArgb(255, 66, 133, 244),  // azure
        WinColor.FromArgb(255, 16, 185, 129),  // jade
        WinColor.FromArgb(255, 245, 158, 11),  // amber
        WinColor.FromArgb(255, 168, 85, 247),  // orchid
        WinColor.FromArgb(255, 0, 229, 255),   // cyan
        WinColor.FromArgb(255, 236, 72, 153),  // rose
    };

    private static WinColor SparkTint(int li, double alpha)
    {
        WinColor c = SparkPalette[((li % SparkPalette.Length) + SparkPalette.Length) % SparkPalette.Length];
        return WinColor.FromArgb((byte)(Clamp01(alpha) * 255), c.R, c.G, c.B);
    }

    private static WinColor Hex(string hex, double alpha)
    {
        byte r = Convert.ToByte(hex.Substring(0, 2), 16);
        byte g = Convert.ToByte(hex.Substring(2, 2), 16);
        byte b = Convert.ToByte(hex.Substring(4, 2), 16);
        return WinColor.FromArgb((byte)(Clamp01(alpha) * 255), r, g, b);
    }

    private static double Clamp01(double x) => x < 0 ? 0 : x > 1 ? 1 : x;

    public void Dispose()
    {
        _control.Draw -= OnDraw;
        _control.RemoveFromVisualTree();
    }
}

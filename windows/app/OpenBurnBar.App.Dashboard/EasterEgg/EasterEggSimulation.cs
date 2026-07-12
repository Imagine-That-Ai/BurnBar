using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.Dashboard.EasterEgg;

/// <summary>The current takeover the field is running — port of <c>EasterEggSimulation.Mode</c>.</summary>
public enum SimulationMode
{
    Idle,
    Storm,
    Rain,
}

/// <summary>
/// One in-flight easter egg's mutable particle field — a faithful, drawing-free
/// C# port of the <c>EasterEggSimulation</c> in <c>EasterEggScene.swift</c>. The
/// Win2D host owns one of these per event and calls <see cref="Step(double,double)"/>
/// on every <c>CanvasAnimatedControl.Draw</c> tick, then draws the current particle
/// arrays; the tests step it directly and assert exact positions / collisions /
/// settle. All physics — spring-to-shape convergence, firework bursts, coin gravity
/// + air drag + restitution + wall / ledge / floor bounces + settle, and the
/// reverse-gravity boundary arc — lives here, identical to the macOS sibling.
/// </summary>
public sealed class EasterEggSimulation
{
    private enum StormPhaseKind
    {
        Burst,
        Converge,
    }

    private readonly struct Phase
    {
        public Phase(double at, StormPhaseKind kind)
        {
            At = at;
            Kind = kind;
        }

        public double At { get; }

        public StormPhaseKind Kind { get; }
    }

    private readonly EasterEggEdge _edge;
    private readonly bool _reduceMotion;
    private readonly IGlyphSampler _glyphs;

    private SeededGenerator _rng = new(SeededGenerator.SimulationSeed);

    // Canvas geometry (logical points).
    private double _sceneWidth = 1;
    private double _sceneHeight = 1;

    // Shared clock baseline (ms since the event started).
    private double _fxStart;
    private double _lastNow;

    // Storm state.
    private Spark[] _sparks = Array.Empty<Spark>();
    private Phase[] _phases = Array.Empty<Phase>();
    private int _phaseI;
    private int _shapeRotation;

    // Rain state.
    private Cloud[] _clouds = Array.Empty<Cloud>();
    private readonly List<Token> _tokens = new();
    private Ledge[] _rects = Array.Empty<Ledge>();
    private double _nextEmit;

    // Boundary state (coexists with any mode).
    private readonly List<EdgeCoin> _edgeCoins = new();

    public EasterEggSimulation(
        EasterEggKind kind,
        EasterEggEdge edge = EasterEggEdge.Top,
        bool reduceMotion = false,
        IGlyphSampler? glyphSampler = null)
    {
        Kind = kind;
        _edge = edge;
        _reduceMotion = reduceMotion;
        _glyphs = glyphSampler ?? new ProceduralGlyphSampler();
    }

    public EasterEggKind Kind { get; }

    public SimulationMode Mode { get; private set; } = SimulationMode.Idle;

    /// <summary>Number of distinct logo sprites the host deck exposes (drives <see cref="Spark.Li"/>).</summary>
    public int LogoCount { get; set; } = 8;

    /// <summary>Number of distinct crest sprites the host deck exposes (drives <see cref="Cloud.Crest"/>).</summary>
    public int CrestCount { get; set; } = 3;

    public double SceneWidth => _sceneWidth;

    public double SceneHeight => _sceneHeight;

    public double FxStart => _fxStart;

    public double LastNow => _lastNow;

    public IReadOnlyList<Spark> Sparks => _sparks;

    public IReadOnlyList<Cloud> Clouds => _clouds;

    public IReadOnlyList<Token> Tokens => _tokens;

    public IReadOnlyList<EdgeCoin> EdgeCoins => _edgeCoins;

    /// <summary>Whether the simulation still has work (a live takeover or any boundary coin).</summary>
    public bool IsActive => Mode != SimulationMode.Idle || _edgeCoins.Count > 0;

    // MARK: Lifecycle

    /// <summary>Begin the takeover/boundary for <see cref="Kind"/>. <paramref name="nowMs"/> is ms.</summary>
    public void Begin(double nowMs, double width, double height, IReadOnlyList<Ledge>? ledges = null)
    {
        _sceneWidth = Math.Max(width, 1);
        _sceneHeight = Math.Max(height, 1);
        _lastNow = nowMs;

        if (_reduceMotion)
        {
            return;
        }

        switch (Kind)
        {
            case EasterEggKind.LogoStorm:
                StartStorm(nowMs);
                break;
            case EasterEggKind.CloudTokenRain:
                _rects = ledges is null ? Array.Empty<Ledge>() : new List<Ledge>(ledges).ToArray();
                StartRain(nowMs);
                break;
            case EasterEggKind.Boundary:
                Boundary(_edge, nowMs);
                break;
        }
    }

    /// <summary>Keep the working geometry current (window resize between frames).</summary>
    public void UpdateSize(double width, double height)
    {
        _sceneWidth = Math.Max(width, 1);
        _sceneHeight = Math.Max(height, 1);
    }

    /// <summary>Advance one frame. <paramref name="nowMs"/> is ms, <paramref name="dt"/> is seconds.</summary>
    public void Step(double nowMs, double dt)
    {
        _lastNow = nowMs;
        switch (Mode)
        {
            case SimulationMode.Storm:
                UpdateStorm(nowMs, dt);
                break;
            case SimulationMode.Rain:
                UpdateRain(nowMs, dt);
                break;
            case SimulationMode.Idle:
                break;
        }

        // Boundary coins advance regardless of mode so they can coexist with a takeover.
        StepEdgeCoins(dt);
    }

    // MARK: Envelope helpers (shared by the host's draw pass and the tests)

    /// <summary>Global storm envelope: 350ms linear fade-in x 650ms linear fade-out.</summary>
    public double StormEnvelope(double now) =>
        Clamp01((now - _fxStart) / 350) * Clamp01((_fxStart + EasterEggFx.DurationMs - now) / 650);

    /// <summary>Per-spark alpha (envelope x twinkle) — the host multiplies sprite opacity by this.</summary>
    public double SparkAlpha(in Spark spark, double now) =>
        StormEnvelope(now) * (0.85 + (0.15 * Math.Sin((now * 0.012) + spark.Tw)));

    /// <summary>Rain fade: begins at +4300ms, fully gone by FXDUR+700 = 5700ms.</summary>
    public double RainFade(double now) =>
        now > _fxStart + 4300
            ? Clamp01((_fxStart + EasterEggFx.DurationMs + 700 - now) / 1000)
            : 1;

    // MARK: - DARK LOGO STORM

    private string PickShape()
    {
        string shape = EasterEggFx.Shapes[_shapeRotation % EasterEggFx.Shapes.Length];
        _shapeRotation++;
        return shape;
    }

    private void StartStorm(double now)
    {
        Mode = SimulationMode.Storm;
        _fxStart = now;
        _phaseI = 0;
        _shapeRotation = _rng.NextIndex(EasterEggFx.Shapes.Length);

        int logoCount = Math.Max(1, LogoCount);
        _sparks = new Spark[EasterEggFx.SparkCount];
        for (int i = 0; i < _sparks.Length; i++)
        {
            // Draw in the same order as the Swift Spark initializer for determinism.
            int li = _rng.NextIndex(logoCount);
            double x = _rng.NextDouble(0, _sceneWidth);
            double y = _rng.NextDouble(0, _sceneHeight);
            double size = _rng.NextDouble(22, 48);
            double rot = _rng.NextDouble(-0.5, 0.5);
            double vr = _rng.NextDouble(-2, 2);
            double tw = _rng.NextDouble(0, 6.28);
            _sparks[i] = new Spark
            {
                Li = li,
                X = x,
                Y = y,
                Vx = 0,
                Vy = 0,
                Size = size,
                Rot = rot,
                Vr = vr,
                Tw = tw,
                HasTarget = false,
            };
        }

        _phases = new[]
        {
            new Phase(now + 0, StormPhaseKind.Burst),
            new Phase(now + 1050, StormPhaseKind.Converge),
            new Phase(now + 2250, StormPhaseKind.Burst),
            new Phase(now + 3050, StormPhaseKind.Converge),
            new Phase(now + 4200, StormPhaseKind.Burst),
        };
    }

    /// <summary>Fireworks explosion: each spark radiates outward from a random burst centre.</summary>
    private void BurstAll()
    {
        double cx = _rng.NextDouble(_sceneWidth * 0.2, _sceneWidth * 0.8);
        double cy = _rng.NextDouble(_sceneHeight * 0.2, _sceneHeight * 0.62);
        for (int i = 0; i < _sparks.Length; i++)
        {
            _sparks[i].HasTarget = false;
            double ang = Math.Atan2(_sparks[i].Y - cy, _sparks[i].X - cx) + _rng.NextDouble(-0.5, 0.5);
            double sp = _rng.NextDouble(140, 460);
            _sparks[i].Vx = Math.Cos(ang) * sp;
            _sparks[i].Vy = (Math.Sin(ang) * sp) - _rng.NextDouble(20, 140); // slight upward bias
            _sparks[i].Vr = _rng.NextDouble(-3, 3);
        }
    }

    /// <summary>Convergence: assign each spark a spring target sampled from the glyph raster.</summary>
    private void ToShape(string text)
    {
        IReadOnlyList<Vec2> pts = _glyphs.Points(text);
        if (pts.Count == 0)
        {
            BurstAll();
            return;
        }

        int n = _sparks.Length;
        IReadOnlyList<Vec2> use = pts;
        if (pts.Count > n)
        {
            var down = new List<Vec2>(n);
            double stride = (double)pts.Count / n;
            for (int i = 0; i < n; i++)
            {
                down.Add(pts[(int)(i * stride)]);
            }

            use = down;
        }

        double cx = _sceneWidth * 0.5;
        double cy = _sceneHeight * 0.42;
        double sc = Math.Min(_sceneWidth, _sceneHeight) * 0.62;
        int count = use.Count;
        for (int j = 0; j < _sparks.Length; j++)
        {
            if (j < count)
            {
                Vec2 q = use[j % count];
                _sparks[j].HasTarget = true;
                _sparks[j].Target = new Vec2(cx + (q.X * sc), cy + (q.Y * sc));
            }
            else
            {
                _sparks[j].HasTarget = false;
            }
        }
    }

    private void UpdateStorm(double now, double dt)
    {
        while (_phaseI < _phases.Length && now >= _phases[_phaseI].At)
        {
            if (_phases[_phaseI].Kind == StormPhaseKind.Burst)
            {
                BurstAll();
            }
            else
            {
                ToShape(PickShape());
            }

            _phaseI++;
        }

        for (int i = 0; i < _sparks.Length; i++)
        {
            if (_sparks[i].HasTarget)
            {
                // Spring to target (stiffness 150, damping 24).
                double dx = _sparks[i].Target.X - _sparks[i].X;
                double dy = _sparks[i].Target.Y - _sparks[i].Y;
                _sparks[i].Vx += ((dx * 150) - (_sparks[i].Vx * 24)) * dt;
                _sparks[i].Vy += ((dy * 150) - (_sparks[i].Vy * 24)) * dt;
            }
            else
            {
                // Free firework: frame-rate-independent half-life decay + gentle sway.
                double decay = Math.Pow(0.5, dt);
                _sparks[i].Vx = (_sparks[i].Vx * decay) + (Math.Sin((now * 0.001) + _sparks[i].Tw) * 7 * dt);
                _sparks[i].Vy = (_sparks[i].Vy * decay) + (14 * dt);
            }

            _sparks[i].X += _sparks[i].Vx * dt;
            _sparks[i].Y += _sparks[i].Vy * dt;
            _sparks[i].Rot += _sparks[i].Vr * dt;
        }

        if (now > _fxStart + EasterEggFx.DurationMs)
        {
            Mode = SimulationMode.Idle;
            _sparks = Array.Empty<Spark>();
        }
    }

    // MARK: - LIGHT CLOUD TOKEN RAIN

    private void StartRain(double now)
    {
        Mode = SimulationMode.Rain;
        _fxStart = now;
        _tokens.Clear();
        _nextEmit = now + 150;

        int crestCount = Math.Max(1, CrestCount);
        int nc = EasterEggFx.CloudCount;
        _clouds = new Cloud[nc];
        for (int i = 0; i < nc; i++)
        {
            double x = ((i + 0.5) / nc * _sceneWidth) + _rng.NextDouble(-30, 30);
            double y = _rng.NextDouble(26, 120);
            double w = _rng.NextDouble(210, 360);
            double vx = _rng.NextDouble(-10, 10);
            double seed = _rng.NextDouble(0, 99);
            _clouds[i] = new Cloud
            {
                X = x,
                Y = y,
                W = w,
                Vx = vx,
                Crest = i % crestCount,
                Seed = seed,
            };
        }
    }

    /// <summary>Each cloud drops 2–4 coins beneath itself.</summary>
    private void Emit()
    {
        foreach (Cloud cl in _clouds)
        {
            int n = 2 + (int)(_rng.Next() % 3);
            for (int c = 0; c < n; c++)
            {
                bool gold = _rng.Next() % 2 == 0;
                double x = cl.X + _rng.NextDouble(-cl.W * 0.42, cl.W * 0.42);
                double vx = _rng.NextDouble(-40, 40);
                double vy = _rng.NextDouble(20, 90);
                double r = _rng.NextDouble(5, 11);
                double flip = _rng.NextDouble(0, 6.28);
                double vflipMag = _rng.NextDouble(5, 11);
                double vflip = vflipMag * (_rng.Next() % 2 == 0 ? 1 : -1);
                double tilt = _rng.NextDouble(0, 6.28);
                double vtilt = _rng.NextDouble(-3, 3);
                _tokens.Add(new Token
                {
                    X = x,
                    Y = cl.Y + (cl.W * 0.18),
                    Vx = vx,
                    Vy = vy,
                    R = r,
                    Gold = gold,
                    Flip = flip,
                    Vflip = vflip,
                    Tilt = tilt,
                    Vtilt = vtilt,
                    Rest = 0,
                });
            }
        }
    }

    private void UpdateRain(double now, double dt)
    {
        // Clouds drift + wrap.
        for (int i = 0; i < _clouds.Length; i++)
        {
            _clouds[i].X += _clouds[i].Vx * dt;
            if (_clouds[i].X < -_clouds[i].W)
            {
                _clouds[i].X = _sceneWidth + _clouds[i].W;
            }

            if (_clouds[i].X > _sceneWidth + _clouds[i].W)
            {
                _clouds[i].X = -_clouds[i].W;
            }
        }

        // Emission window: until +4000ms.
        if (now >= _nextEmit && now < _fxStart + 4000)
        {
            Emit();
            _nextEmit = now + _rng.NextDouble(85, 165);
        }

        double drag = Math.Pow(0.55, dt);
        for (int k = _tokens.Count - 1; k >= 0; k--)
        {
            Token t = _tokens[k];

            // Gravity + air drag.
            t.Vy += EasterEggFx.Gravity * dt;
            t.Vx *= drag;
            t.X += t.Vx * dt;
            t.Y += t.Vy * dt;
            t.Flip += t.Vflip * dt;
            t.Tilt += t.Vtilt * dt;

            double r = t.R;

            // Side walls (restitution 0.5).
            if (t.X < r)
            {
                t.X = r;
                t.Vx = Math.Abs(t.Vx) * 0.5;
                t.Vflip *= 0.85;
            }

            if (t.X > _sceneWidth - r)
            {
                t.X = _sceneWidth - r;
                t.Vx = -Math.Abs(t.Vx) * 0.5;
                t.Vflip *= 0.85;
            }

            // Ledge collisions: bounce off the top band of each UI rect.
            if (t.Vy > 0)
            {
                foreach (Ledge rect in _rects)
                {
                    if (t.X > rect.L - r && t.X < rect.R + r &&
                        t.Y > rect.T - r && t.Y < rect.T + 12)
                    {
                        t.Y = rect.T - r;
                        t.Vy = -t.Vy * 0.5;
                        t.Vx += _rng.NextDouble(-30, 30);
                        t.Vflip *= 0.85;
                    }
                }
            }

            // Floor: bounce (restitution 0.48) or settle.
            if (t.Y > _sceneHeight - r)
            {
                t.Y = _sceneHeight - r;
                if (Math.Abs(t.Vy) > 55)
                {
                    t.Vy = -Math.Abs(t.Vy) * 0.48;
                    t.Vx *= 0.7;
                    t.Vflip *= 0.7;
                }
                else
                {
                    t.Vy = 0;
                    t.Vx *= 0.82;
                    t.Vflip *= 0.86;
                    t.Rest += 1;
                }
            }

            // Removal.
            if (now > _fxStart + EasterEggFx.DurationMs + 800 || t.Rest > 26)
            {
                _tokens.RemoveAt(k);
                continue;
            }

            _tokens[k] = t;
        }

        if (now > _fxStart + EasterEggFx.DurationMs && _tokens.Count == 0)
        {
            Mode = SimulationMode.Idle;
            _clouds = Array.Empty<Cloud>();
        }
    }

    // MARK: - BOUNDARY POP

    /// <summary>Spawn a 10-coin row at the page edge that arcs out under REVERSE gravity.</summary>
    private void Boundary(EasterEggEdge edge, double now)
    {
        _ = now;
        double y0 = edge == EasterEggEdge.Top ? 8 : _sceneHeight - 8;
        double dir = edge == EasterEggEdge.Top ? 1 : -1;
        const int n = 10;
        for (int i = 0; i < n; i++)
        {
            double x = ((i + 0.5) / n * _sceneWidth) + _rng.NextDouble(-14, 14);
            double vy = dir * _rng.NextDouble(280, 460);
            double r = _rng.NextDouble(5, 9);
            bool gold = _rng.Next() % 2 == 0;
            double flip = _rng.NextDouble(0, 6.28);
            double vflip = _rng.NextDouble(6, 12);
            double tilt = _rng.NextDouble(0, 6.28);
            double vtilt = _rng.NextDouble(-2, 2);
            var token = new Token
            {
                X = x,
                Y = y0,
                Vx = 0,
                Vy = vy,
                R = r,
                Gold = gold,
                Flip = flip,
                Vflip = vflip,
                Tilt = tilt,
                Vtilt = vtilt,
                Rest = 0,
            };
            _edgeCoins.Add(new EdgeCoin { Token = token, G = -dir * 1150, T = 0, Alpha = 1 });
        }
    }

    private void StepEdgeCoins(double dt)
    {
        for (int i = _edgeCoins.Count - 1; i >= 0; i--)
        {
            EdgeCoin e = _edgeCoins[i];
            e.T += dt;
            e.Token.Vy += e.G * dt;
            e.Token.Y += e.Token.Vy * dt;
            e.Token.Flip += e.Token.Vflip * dt;
            e.Token.Tilt += e.Token.Vtilt * dt;
            double t = e.T;
            e.Alpha = t > 0.55 ? Clamp01((0.95 - t) / 0.4) : 1;
            if (t > 0.95)
            {
                _edgeCoins.RemoveAt(i);
                continue;
            }

            _edgeCoins[i] = e;
        }
    }

    private static double Clamp01(double x) => x < 0 ? 0 : x > 1 ? 1 : x;
}

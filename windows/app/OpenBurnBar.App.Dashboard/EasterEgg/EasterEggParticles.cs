namespace OpenBurnBar.App.Dashboard.EasterEgg;

// Particle value types — faithful ports of the structs nested in
// EasterEggSimulation (EasterEggScene.swift). Mutable structs stored in the
// simulation's arrays/lists; the Win2D host reads their public fields to draw and
// the tests snapshot them by value to assert exact per-frame positions.

/// <summary>A logo/crest sprite in the dark-appearance logo storm.</summary>
public struct Spark
{
    /// <summary>Logo index into the host's sprite deck.</summary>
    public int Li;

    public double X;
    public double Y;
    public double Vx;
    public double Vy;
    public double Size;
    public double Rot;

    /// <summary>Angular velocity.</summary>
    public double Vr;

    /// <summary>Twinkle / sway phase.</summary>
    public double Tw;

    /// <summary>Whether this spark is currently springing to a glyph target.</summary>
    public bool HasTarget;

    /// <summary>The glyph-raster target while converging (valid iff <see cref="HasTarget"/>).</summary>
    public Vec2 Target;
}

/// <summary>A gold/silver coin with edge-on-flip + tumble state (rain + boundary).</summary>
public struct Token
{
    public double X;
    public double Y;
    public double Vx;
    public double Vy;
    public double R;
    public bool Gold;

    /// <summary>Edge-on-flip phase (cos drives width squash).</summary>
    public double Flip;
    public double Vflip;

    /// <summary>In-plane rotation.</summary>
    public double Tilt;
    public double Vtilt;

    /// <summary>Settle counter (frames resting on the floor).</summary>
    public int Rest;
}

/// <summary>A fluffy procedural cloud that drifts overhead and rains coins.</summary>
public struct Cloud
{
    public double X;
    public double Y;
    public double W;
    public double Vx;

    /// <summary>Crest image index.</summary>
    public int Crest;

    /// <summary>Bob phase.</summary>
    public double Seed;
}

/// <summary>A collision ledge: coins bounce off the top band of an on-screen UI rect.</summary>
public readonly struct Ledge
{
    public Ledge(double l, double r, double t)
    {
        L = l;
        R = r;
        T = t;
    }

    public double L { get; }

    public double R { get; }

    public double T { get; }
}

/// <summary>A boundary-pop coin: arcs out from an edge under reverse gravity, then fades.</summary>
public struct EdgeCoin
{
    public Token Token;

    /// <summary>(Reverse) gravity applied to this coin.</summary>
    public double G;

    /// <summary>Lifetime in seconds.</summary>
    public double T;

    /// <summary>Current alpha (fades out after 0.55s).</summary>
    public double Alpha;
}

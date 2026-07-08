using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.Dashboard.EasterEgg;

/// <summary>
/// Rasterises a glyph string to a set of origin-centred normalised target points
/// (roughly -0.5…+0.5) the logo storm springs sprites toward. This is the seam
/// that <c>EasterEggGlyphSampler</c> fills on macOS with an AppKit bitmap raster;
/// the Win2D host can supply a <c>CanvasTextLayout</c>-based sampler on Windows
/// for pixel-identical glyphs, while <see cref="ProceduralGlyphSampler"/> keeps the
/// simulation fully portable + deterministic for the unit tests.
/// </summary>
public interface IGlyphSampler
{
    /// <summary>Target points for <paramref name="shape"/>, centred on the origin.</summary>
    IReadOnlyList<Vec2> Points(string shape);
}

/// <summary>
/// The portable, dependency-free glyph sampler. Each of the four shapes the storm
/// converges into (<c>$ :) &lt;/&gt; { }</c>) is authored as a set of normalised
/// polyline strokes, then sampled at a fixed arc-length spacing so the point set is
/// deterministic (no fonts, no rasteriser, no platform calls). Results are cached
/// per string, exactly like the Swift sampler's <c>cache</c>.
/// </summary>
public sealed class ProceduralGlyphSampler : IGlyphSampler
{
    /// <summary>Arc-length spacing between sampled points (normalised units).</summary>
    private const double Spacing = 0.045;

    private readonly Dictionary<string, IReadOnlyList<Vec2>> _cache = new(StringComparer.Ordinal);

    public IReadOnlyList<Vec2> Points(string shape)
    {
        if (_cache.TryGetValue(shape, out IReadOnlyList<Vec2>? cached))
        {
            return cached;
        }

        IReadOnlyList<Vec2> pts = Sample(StrokesFor(shape));
        _cache[shape] = pts;
        return pts;
    }

    private static IReadOnlyList<Vec2> Sample(IReadOnlyList<Vec2[]> strokes)
    {
        var pts = new List<Vec2>();
        foreach (Vec2[] stroke in strokes)
        {
            if (stroke.Length == 0)
            {
                continue;
            }

            pts.Add(stroke[0]);
            for (int i = 1; i < stroke.Length; i++)
            {
                Vec2 a = stroke[i - 1];
                Vec2 b = stroke[i];
                double dx = b.X - a.X;
                double dy = b.Y - a.Y;
                double len = Math.Sqrt((dx * dx) + (dy * dy));
                int steps = Math.Max(1, (int)(len / Spacing));
                for (int s = 1; s <= steps; s++)
                {
                    double t = (double)s / steps;
                    pts.Add(new Vec2(a.X + (dx * t), a.Y + (dy * t)));
                }
            }
        }

        return pts;
    }

    private static IReadOnlyList<Vec2[]> StrokesFor(string shape) => shape switch
    {
        "$" => Dollar,
        ":)" => Smiley,
        "</>" => CodeTags,
        "{ }" => Braces,
        _ => Array.Empty<Vec2[]>(),
    };

    // A tiny closed diamond so an "eye" samples to a handful of points.
    private static Vec2[] Dot(double cx, double cy)
    {
        const double r = 0.05;
        return new[]
        {
            new Vec2(cx, cy - r), new Vec2(cx + r, cy),
            new Vec2(cx, cy + r), new Vec2(cx - r, cy), new Vec2(cx, cy - r),
        };
    }

    private static readonly Vec2[][] Dollar =
    {
        // Central vertical stroke.
        new[] { new Vec2(0, -0.5), new Vec2(0, 0.5) },
        // The S.
        new[]
        {
            new Vec2(0.22, -0.42), new Vec2(0.0, -0.47), new Vec2(-0.22, -0.36),
            new Vec2(-0.22, -0.12), new Vec2(0.0, -0.02), new Vec2(0.22, 0.08),
            new Vec2(0.22, 0.32), new Vec2(0.0, 0.44), new Vec2(-0.22, 0.36),
        },
    };

    private static readonly Vec2[][] Smiley =
    {
        Dot(-0.18, -0.2),
        Dot(0.18, -0.2),
        // Smile arc.
        new[]
        {
            new Vec2(-0.28, 0.06), new Vec2(-0.14, 0.22),
            new Vec2(0.0, 0.3), new Vec2(0.14, 0.22), new Vec2(0.28, 0.06),
        },
    };

    private static readonly Vec2[][] CodeTags =
    {
        // '<'
        new[] { new Vec2(-0.1, -0.34), new Vec2(-0.4, 0.0), new Vec2(-0.1, 0.34) },
        // '/'
        new[] { new Vec2(0.07, 0.42), new Vec2(-0.07, -0.42) },
        // '>'
        new[] { new Vec2(0.1, -0.34), new Vec2(0.4, 0.0), new Vec2(0.1, 0.34) },
    };

    private static readonly Vec2[][] Braces =
    {
        // '{'
        new[]
        {
            new Vec2(-0.1, -0.44), new Vec2(-0.22, -0.34), new Vec2(-0.22, -0.06),
            new Vec2(-0.34, 0.0), new Vec2(-0.22, 0.06), new Vec2(-0.22, 0.34), new Vec2(-0.1, 0.44),
        },
        // '}'
        new[]
        {
            new Vec2(0.1, -0.44), new Vec2(0.22, -0.34), new Vec2(0.22, -0.06),
            new Vec2(0.34, 0.0), new Vec2(0.22, 0.06), new Vec2(0.22, 0.34), new Vec2(0.1, 0.44),
        },
    };
}

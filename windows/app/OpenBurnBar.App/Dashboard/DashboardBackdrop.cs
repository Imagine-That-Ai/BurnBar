// WINDOWS-ONLY / CI-DEFERRED (Win2D host). The frame-GENERATION math here mirrors the
// perf harness (portable, macOS-built), but this file lives in the WinUI app because it
// binds the LANDED SwarmCanvasHost (airspace-free Win2D CanvasImageSource). See SwarmCanvasHost.cs.

using System;
using System.Linq;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Dashboard.Layout;
using OpenBurnBar.App.Particles;
using OpenBurnBar.Particles.Math;
using OpenBurnBar.Particles.Model;
using OpenBurnBar.Particles.Substrates;
using Windows.UI.ViewManagement;

namespace OpenBurnBar.App.Dashboard;

/// <summary>
/// The dashboard's swarm/constellation/depth backdrop — the Windows analog of the
/// macOS <c>ConstellationBackgroundView</c> / <c>DashboardDepthBackdrop</c> /
/// <c>KernelBackdropView</c> that ride behind every concept layout. It CONSUMES the
/// landed particle engine: a <see cref="SwarmCanvasHost"/> (an airspace-free Win2D
/// <c>CanvasImageSource</c> renderer) painting a family-appropriate
/// <see cref="ISwarmSubstrate"/> from the ported <see cref="SubstrateCatalog"/>. The
/// active family follows the selected <see cref="DashboardLayout"/> so each concept has
/// its own signature backdrop, exactly like the macOS layouts.
/// </summary>
/// <remarks>
/// The per-frame <see cref="SwarmSubstrateFrame"/> is produced here by a dev-host
/// generator (a drifting synthetic field) so the backdrop renders standalone on the dev
/// host; in production the frame is vended by Swift Core over FFI
/// (<c>SwarmSubstrateFrameFfi.Decode</c>) — the same seam the SwarmCanvasHost documents.
/// The substrate PAINTERS are the real, parity-verified engine.
/// </remarks>
public sealed class DashboardBackdrop : IDisposable
{
    private readonly SwarmCanvasHost _host = new();
    private readonly UISettings _uiSettings = new();
    private SwarmSubstrateDot[] _dots = Array.Empty<SwarmSubstrateDot>();
    private double _fieldWidth;
    private double _fieldHeight;
    private SubstrateFamily _family = SubstrateFamily.Constellation;
    private SubstrateStage _stage;
    private bool _isDark = true;

    public DashboardBackdrop()
    {
        _stage = BuildStage(_family);
        _host.FrameProvider = ProvideFrame;
        SetLayout(DashboardLayoutMeta.Default);
    }

    /// <summary>The XAML image to place at the back of the dashboard visual tree.</summary>
    public Image Control => _host.Control;

    /// <summary>Pauses compositor-driven invalidation while the WebGL layer is active.</summary>
    public bool Paused
    {
        get => _host.Paused;
        set => _host.Paused = value;
    }

    /// <summary>Switch the backdrop family + substrate to match the selected layout.</summary>
    public void SetLayout(DashboardLayout layout)
    {
        SubstrateFamily next = FamilyFor(layout);
        SubstrateDescriptor[] bespoke = SubstrateCatalog.BespokeFor(next);
        ApplyDescriptor(
            bespoke.Length > 0
                ? bespoke[0]
                : SubstrateCatalog.Plain(next));
    }

    /// <summary>Render a shared kernel id through its native Win2D substrate analog.</summary>
    public void SetKernel(string? kernelId)
    {
        string substrateId = KernelSubstrateSelection.SubstrateIdFor(kernelId);
        SubstrateDescriptor descriptor = SubstrateCatalog.SubstrateList.First(
            candidate => string.Equals(candidate.Id, substrateId, StringComparison.Ordinal));
        ApplyDescriptor(descriptor);
    }

    /// <summary>Apply the active XAML theme polarity to every generated native frame.</summary>
    public void SetTheme(string? theme)
    {
        bool isDark = !string.Equals(theme, "light", StringComparison.OrdinalIgnoreCase);
        if (_isDark == isDark)
        {
            return;
        }

        _isDark = isDark;
        _stage = BuildStage(_family);
    }

    private void ApplyDescriptor(SubstrateDescriptor descriptor)
    {
        bool familyChanged = descriptor.Family != _family;
        _family = descriptor.Family;
        _stage = BuildStage(_family);
        _host.Substrate = descriptor.Make();
        // Rebuild the synthetic field when the family changes so accent/ramp reseed
        // and the switch is visibly different (not just a quieter painter swap).
        if (familyChanged && _fieldWidth > 1 && _fieldHeight > 1)
        {
            _dots = BuildField(_fieldWidth, _fieldHeight);
        }

        // Resume the vsync loop if it was paused while the kernel layer was on top.
        Paused = false;
    }

    /// <summary>
    /// Map each concept to a substrate family — kernel-forward concepts get the richest
    /// hero fields, structured concepts get calmer lattices, mirroring the macOS backdrops.
    /// </summary>
    private static SubstrateFamily FamilyFor(DashboardLayout layout) => layout switch
    {
        DashboardLayout.Atelier => SubstrateFamily.Volumetric,
        DashboardLayout.Constellation => SubstrateFamily.Constellation,
        DashboardLayout.Nebula => SubstrateFamily.Mesh,
        DashboardLayout.Aurora => SubstrateFamily.Aurora,
        DashboardLayout.Cockpit => SubstrateFamily.Flow,
        DashboardLayout.Classic => SubstrateFamily.Constellation,
        DashboardLayout.Stream => SubstrateFamily.Flow,
        DashboardLayout.Atlas => SubstrateFamily.Mesh,
        _ => SubstrateFamily.Constellation,
    };

    private SwarmSubstrateFrame? ProvideFrame(Windows.Foundation.Size size, TimeSpan elapsed)
    {
        double w = size.Width;
        double h = size.Height;
        if (w < 1 || h < 1)
        {
            return null;
        }

        // Rebuild the synthetic field when the canvas resizes materially.
        if (_dots.Length == 0 || Math.Abs(w - _fieldWidth) > 8 || Math.Abs(h - _fieldHeight) > 8)
        {
            _fieldWidth = w;
            _fieldHeight = h;
            _dots = BuildField(w, h);
        }

        double t = elapsed.TotalSeconds;
        bool reduced = !_uiSettings.AnimationsEnabled;
        return new SwarmSubstrateFrame(
            width: w, height: h, dark: _isDark, reduced: reduced, batteryThrottled: false,
            uiMode: UIMode.Standard, isShapeMode: false, formed: false, settleProgress: 0.0,
            t: t, dt: 1.0, stage: _stage,
            backdrop: _isDark ? new Rgba(0.03, 0.04, 0.08, 1.0) : new Rgba(0.96, 0.97, 1.0, 1.0),
            dots: _dots, cx: w / 2, cy: h / 2, cloudRadius: Math.Min(w, h) * 0.32,
            sizePx: 1.6);
    }

    // A soft disc of brand-tinted dots — the same field shape the harness uses, so the
    // ported painters render exactly what they were perf-verified against.
    private SwarmSubstrateDot[] BuildField(double w, double h)
    {
        int n = (int)Math.Clamp(w * h / 1400.0, 240, 1100);
        var rng = new SubstrateKit.XorShift32(0xD45B0A2D ^ (uint)n);
        var dots = new SwarmSubstrateDot[n];
        double cx = w / 2, cy = h / 2;
        double radius = Math.Min(w, h) * 0.42;
        Rgba accent = FamilyAccent.A(_family);
        for (int i = 0; i < n; i++)
        {
            double ang = rng.Next() * SubstrateKit.Tau;
            double rad = Math.Sqrt(rng.Next()) * radius;
            double x = cx + (Math.Cos(ang) * rad);
            double y = cy + (Math.Sin(ang) * rad * 0.72);
            double baseSize = rng.Range(0.8, 2.3);
            double colorIndex = SubstrateKit.Shash((i * 1.37) + 0.5);
            Rgba brand = SubstrateKit.SampleRamp(SubstrateKit.Iris, colorIndex).Mix(accent, 0.35);
            bool inShape = rng.Next() > 0.2;
            double r = Math.Max(0.4, baseSize * (inShape ? 1.2 : 0.85));
            dots[i] = new SwarmSubstrateDot(
                x, y,
                vx: rng.Range(-6, 6), vy: rng.Range(-6, 6),
                radius: r, baseSize: baseSize,
                rgba: brand.WithOpacity(rng.Range(0.65, 1.0)),
                opacity: rng.Range(0.65, 1.0), inShape: inShape,
                colorIndex: colorIndex, flowProgress: 0);
        }

        return dots;
    }

    private SubstrateStage BuildStage(SubstrateFamily family)
    {
        Rgba accent = FamilyAccent.A(family);
        Rgba accent2 = FamilyAccent.A2(family);
        Rgba ink = _isDark ? new Rgba(0.90, 0.93, 1.0) : new Rgba(0.10, 0.14, 0.22);
        return new SubstrateStage(accent, accent2, ink, dark: _isDark);
    }

    public void Dispose() => _host.Dispose();
}

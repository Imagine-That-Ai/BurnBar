using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using OpenBurnBar.Particles.Drawing;
using OpenBurnBar.Particles.Ffi;
using OpenBurnBar.Particles.Math;
using OpenBurnBar.Particles.Model;
using OpenBurnBar.Particles.Substrates;
using OpenBurnBar.Particles.Substrates.Mesh;
using OpenBurnBar.Particles.Substrates.Moire;

// =============================================================================
//  Headless particle-engine perf harness (Phase 3 / W6-DS-SWARM sub-spike).
//
//  WHAT IT MEASURES: the per-frame CPU cost of the substrate RENDERER pass —
//  particle iteration + field/lattice math + draw-command emission — for every
//  landed bespoke painter (Starfire + the Mesh & Moiré families) over
//  hundreds-to-thousands of particles. This is the parity-critical, ARM64-sensitive
//  work that lives in C# (the simulation math stays in Swift Core and is vended
//  per-frame; see Ffi/SwarmSubstrateFrameFfi.cs).
//
//  WHAT IT DOES NOT MEASURE: GPU rasterization / additive-bloom compositing /
//  GaussianBlur / gradient-brush + geometry fill — that is Win2D's job on a real
//  device and is Windows/CI-deferred (the CanvasAnimatedControl host in
//  windows/app/OpenBurnBar.App/Particles/). The 60fps budget below is the CPU-side
//  frame budget: if command emission alone blew 16.67 ms we'd never hit 60fps;
//  staying well under it is necessary (not sufficient) for the full ARM64 gate.
//
//  Draw against RecordingDrawingSession (counts commands, no rasterization), so a
//  frame's wall-time is the painter's own CPU cost.
// =============================================================================

int[] dotCounts = { 1080 };
int frames = 600;   // 10 s at 60fps
int warmup = 120;

for (int i = 0; i < args.Length - 1; i++)
{
    switch (args[i])
    {
        case "--dots":
            var parts = args[i + 1].Split(',', StringSplitOptions.RemoveEmptyEntries);
            var list = new List<int>();
            foreach (var p in parts) if (int.TryParse(p, out var v)) list.Add(v);
            if (list.Count > 0) dotCounts = list.ToArray();
            break;
        case "--frames":
            if (int.TryParse(args[i + 1], out var fr)) frames = fr;
            break;
        case "--warmup":
            if (int.TryParse(args[i + 1], out var wu)) warmup = wu;
            break;
    }
}

CultureInfo.CurrentCulture = CultureInfo.InvariantCulture;

// (name, factory). The full catalog under test — Starfire + the Mesh & Moiré families.
var painters = new (string Name, Func<ISwarmSubstrate> Make)[]
{
    ("Starfire (Constellation)", static () => new StarfireSubstrate()),
    ("Caustic Pool (Mesh)", static () => new MeshCausticSubstrate()),
    ("Gradient Patch (Mesh)", static () => new MeshPatchSubstrate()),
    ("Iso Contour (Mesh)", static () => new MeshIsolineSubstrate()),
    ("Living Grain (Mesh)", static () => new MeshGrainSubstrate()),
    ("Fringe Bloom (Moiré)", static () => new FringeBloomSubstrate()),
    ("Lattice Facet (Moiré)", static () => new LatticeFacetSubstrate()),
    ("Ruling Grating (Moiré)", static () => new RulingGratingSubstrate()),
    ("Film Bubble (Moiré)", static () => new FilmBubbleSubstrate()),
};

bool verifyOnly = Array.IndexOf(args, "--verify") >= 0;
if (verifyOnly)
{
    return RunVerify(painters);
}

Console.WriteLine("=================================================================");
Console.WriteLine(" OpenBurnBar particle-engine perf harness — Mesh + Moiré families");
Console.WriteLine("=================================================================");
Console.WriteLine($" Runtime : {System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription}");
Console.WriteLine($" Arch    : {System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture} on {System.Runtime.InteropServices.RuntimeInformation.OSDescription}");
Console.WriteLine($" Config  : {frames} timed frames (+{warmup} warmup), dt = 1/60, dark canvas");
Console.WriteLine($" Regimes : free-swarm (full-canvas field pass) + shape (per-node pass), full bloom path");
Console.WriteLine($" Measures: CPU field/lattice math + draw-command emission (GPU composite = Win2D, CI-deferred)");
Console.WriteLine($" Budget  : 60fps CPU frame budget = 16.67 ms  (120fps = 8.33 ms)");
Console.WriteLine();

const double frameBudget60 = 1000.0 / 60.0;
const double frameBudget120 = 1000.0 / 120.0;

bool allUnder60 = true;

foreach (int n in dotCounts)
{
    Console.WriteLine($"######## {n} particles ###############################################");
    Console.WriteLine();
    foreach (var (name, make) in painters)
    {
        RunScenario(name, make, n, isShapeMode: false, batteryThrottled: false);
        RunScenario(name, make, n, isShapeMode: true, batteryThrottled: false);
    }
}

Console.WriteLine("=================================================================");
Console.WriteLine(allUnder60
    ? " VERDICT: every substrate's median + p95 CPU frame time is under the 60fps budget."
    : " VERDICT: at least one substrate exceeded the 60fps CPU budget (see FAIL rows).");
Console.WriteLine("=================================================================");

return allUnder60 ? 0 : 1;

void RunScenario(string name, Func<ISwarmSubstrate> make, int n, bool isShapeMode, bool batteryThrottled)
{
    SwarmSubstrateDot[] dots = BuildSyntheticSwarm(n, inShape: isShapeMode);
    ISwarmSubstrate painter = make();
    var session = new RecordingDrawingSession { HashGeometry = false };
    var structure = new SubstrateStructureProvider();
    SubstrateStage stage = BuildStage();

    var timings = new double[frames];
    long lastTotal = 0, lastFills = 0, lastGlows = 0, lastLines = 0, lastSegs = 0,
         lastBlur = 0, lastMask = 0, lastPoly = 0, lastGrad = 0;

    var sw = new Stopwatch();
    for (int frame = 0; frame < warmup + frames; frame++)
    {
        double t = frame / 60.0;
        AdvanceSwarm(dots, t);
        var f = new SwarmSubstrateFrame(
            width: canvasWConst, height: canvasHConst, dark: true, reduced: false,
            batteryThrottled: batteryThrottled, uiMode: UIMode.Standard,
            isShapeMode: isShapeMode, formed: isShapeMode, settleProgress: 0.85,
            t: t, dt: 1.0, stage: stage, backdrop: null, dots: dots,
            cx: canvasWConst / 2, cy: canvasHConst / 2, cloudRadius: 260, sizePx: 1.6,
            structure: structure);

        session.Reset();
        if (frame >= warmup) sw.Restart();
        painter.Paint(f, session);
        if (frame >= warmup)
        {
            sw.Stop();
            timings[frame - warmup] = sw.Elapsed.TotalMilliseconds;
        }

        lastTotal = session.TotalCommands;
        lastFills = session.FillCircleCount;
        lastGlows = session.GlowSpriteCount;
        lastLines = session.LineBatchCount;
        lastSegs = session.LineSegmentCount;
        lastBlur = session.BlurLayerCount;
        lastMask = session.MaskLayerCount;
        lastPoly = session.FillPolygonCount;
        lastGrad = session.GradientQuadCount;
    }

    Array.Sort(timings);
    double min = timings[0];
    double max = timings[frames - 1];
    double median = Pct(timings, 0.50);
    double p95 = Pct(timings, 0.95);
    double p99 = Pct(timings, 0.99);

    bool under60 = median <= frameBudget60 && p95 <= frameBudget60;
    if (!under60) allUnder60 = false;

    string regime = isShapeMode ? "shape     " : "free-swarm";
    Console.WriteLine($"--- {name} · {regime} -------------------------------");
    Console.WriteLine($"  frame ms   : min {min,7:F4}  median {median,7:F4}  p95 {p95,7:F4}  p99 {p99,7:F4}  max {max,7:F4}");
    Console.WriteLine($"  eff. FPS   : median {1000.0 / median,8:F0}   p95 {1000.0 / p95,8:F0}");
    Console.WriteLine($"  draw cmds  : {lastTotal,6}  (fills {lastFills}, glows {lastGlows}, lines {lastLines}/{lastSegs}seg, poly {lastPoly}, grad {lastGrad}, blur {lastBlur}, mask {lastMask})");
    Console.WriteLine($"  60fps      : median {(median <= frameBudget60 ? "PASS" : "FAIL")}  p95 {(p95 <= frameBudget60 ? "PASS" : "FAIL")}   " +
                      $"| 120fps: median {(median <= frameBudget120 ? "PASS" : "FAIL")}  p95 {(p95 <= frameBudget120 ? "PASS" : "FAIL")}");
    Console.WriteLine($"  headroom@60: median {frameBudget60 / median,6:F1}x   p95 {frameBudget60 / p95,6:F1}x");
    Console.WriteLine();
}

static double Pct(double[] sorted, double p)
{
    if (sorted.Length == 0) return 0;
    int idx = (int)System.Math.Ceiling(p * sorted.Length) - 1;
    if (idx < 0) idx = 0;
    if (idx >= sorted.Length) idx = sorted.Length - 1;
    return sorted[idx];
}

// A synthetic swarm shaped like the real field: dots on a soft disc around center,
// brand-ish colors sampled off the iris ramp by a stable per-dot seed, mixed sizes.
// `inShape` toggles the shape/free-swarm regime the substrates branch on.
static SwarmSubstrateDot[] BuildSyntheticSwarm(int n, bool inShape)
{
    var rng = new SubstrateKit.XorShift32(0xC0FFEE ^ (uint)n);
    var dots = new SwarmSubstrateDot[n];
    const double cx = canvasWConst / 2, cy = canvasHConst / 2;
    for (int i = 0; i < n; i++)
    {
        double ang = rng.Next() * SubstrateKit.Tau;
        double rad = System.Math.Sqrt(rng.Next()) * 300.0;
        double x = cx + System.Math.Cos(ang) * rad;
        double y = cy + System.Math.Sin(ang) * rad * 0.7;
        double baseSize = rng.Range(0.8, 2.3);
        double colorIndex = SubstrateKit.Shash(i * 1.37 + 0.5);
        Rgba brand = SubstrateKit.SampleRamp(SubstrateKit.Iris, colorIndex).Mix(new Rgba(0.96, 0.31, 0.36), 0.25);
        double r = System.Math.Max(0.4, baseSize * (inShape ? 1.2 : 0.85));
        dots[i] = new SwarmSubstrateDot(
            x, y,
            vx: rng.Range(-8, 8), vy: rng.Range(-8, 8),
            radius: r, baseSize: baseSize,
            rgba: brand.WithOpacity(rng.Range(0.7, 1.0)),
            opacity: rng.Range(0.7, 1.0), inShape: inShape,
            colorIndex: colorIndex, flowProgress: 0);
    }
    return dots;
}

// Light per-frame motion (orbit) so successive frames present different geometry.
static void AdvanceSwarm(SwarmSubstrateDot[] dots, double t)
{
    const double cx = canvasWConst / 2, cy = canvasHConst / 2;
    for (int i = 0; i < dots.Length; i++)
    {
        SwarmSubstrateDot d = dots[i];
        double dx = d.X - cx, dy = d.Y - cy;
        double a = 0.0025 + 0.0005 * System.Math.Sin(t * 0.5 + i);
        double ca = System.Math.Cos(a), sa = System.Math.Sin(a);
        double nx = cx + dx * ca - dy * sa;
        double ny = cy + dx * sa + dy * ca;
        dots[i] = new SwarmSubstrateDot(
            nx, ny, d.Vx, d.Vy, d.Radius, d.BaseSize,
            d.Rgba, d.Opacity, d.InShape, d.ColorIndex, d.FlowProgress);
    }
}

static SwarmSubstrateFrame BuildFrame(int n, bool battery, double t, bool isShapeMode, SubstrateStructureProvider structure)
{
    SubstrateStage stage = BuildStage();
    return new SwarmSubstrateFrame(
        width: canvasWConst, height: canvasHConst, dark: true, reduced: false,
        batteryThrottled: battery, uiMode: UIMode.Standard,
        isShapeMode: isShapeMode, formed: isShapeMode, settleProgress: 0.85,
        t: t, dt: 1.0, stage: stage, backdrop: new Rgba(0.03, 0.04, 0.08, 1.0),
        dots: BuildSyntheticSwarm(n, inShape: isShapeMode), cx: canvasWConst / 2, cy: canvasHConst / 2,
        cloudRadius: 260, sizePx: 1.6, structure: structure);
}

// Self-check: proves the FFI vend contract round-trips and every painter renders
// DETERMINISTICALLY (identical checksum + command counts on a repeat render of the
// same frame) — both prerequisites for the W11 Mac↔Windows layout-parity gate.
static int RunVerify((string Name, Func<ISwarmSubstrate> Make)[] painters)
{
    Console.WriteLine("=== particle-engine self-check (--verify) ===");
    int failures = 0;

    // 1) FFI round-trip: Encode (reference emitter) → Decode == original.
    var structure = new SubstrateStructureProvider();
    SwarmSubstrateFrame frame = BuildFrame(1080, battery: false, t: 3.14159, isShapeMode: true, structure);
    (SwarmSubstrateFrameHeaderFfi header, SwarmSubstrateDotFfi[] wire) = SwarmSubstrateFrameFfi.Encode(frame);
    SwarmSubstrateFrame decoded = SwarmSubstrateFrameFfi.Decode(in header, wire);

    const double eps = 1e-4;
    bool roundTrip = decoded.Dots.Length == frame.Dots.Length
        && decoded.Dark == frame.Dark && decoded.IsShapeMode == frame.IsShapeMode
        && decoded.Formed == frame.Formed && decoded.Backdrop.HasValue == frame.Backdrop.HasValue
        && System.Math.Abs(decoded.SettleProgress - frame.SettleProgress) < eps
        && System.Math.Abs(decoded.Cx - frame.Cx) < 1e-2
        && System.Math.Abs(decoded.Stage.Accent.R - frame.Stage.Accent.R) < eps;
    for (int i = 0; i < frame.Dots.Length && roundTrip; i++)
    {
        SwarmSubstrateDot a = frame.Dots[i], b = decoded.Dots[i];
        if (System.Math.Abs(a.X - b.X) > 1e-2 || System.Math.Abs(a.Y - b.Y) > 1e-2
            || System.Math.Abs(a.Radius - b.Radius) > eps || a.InShape != b.InShape
            || System.Math.Abs(a.Rgba.R - b.Rgba.R) > eps || System.Math.Abs(a.Rgba.A - b.Rgba.A) > eps
            || System.Math.Abs(a.ColorIndex - b.ColorIndex) > eps)
        {
            roundTrip = false;
        }
    }
    Report("FFI Encode→Decode round-trip (1080 dots, float32 wire)", roundTrip, ref failures);

    // 2) Every painter renders deterministically in BOTH regimes, emits commands,
    //    and is FFI-transparent (the decoded frame yields the same command shape).
    foreach (var (name, make) in painters)
    {
        foreach (bool shapeMode in new[] { false, true })
        {
            var perStruct = new SubstrateStructureProvider();
            SwarmSubstrateFrame fr = BuildFrame(1080, battery: false, t: 2.0, isShapeMode: shapeMode, perStruct);

            // Two FRESH painters (stateful integrators like Living Grain seed their
            // grain arrays deterministically, so a fresh instance fed the identical
            // frame reproduces the render bit-for-bit; painting one instance twice
            // would instead advance its persistent drift state).
            var s1 = new RecordingDrawingSession { HashGeometry = true };
            var s2 = new RecordingDrawingSession { HashGeometry = true };
            make().Paint(fr, s1);
            make().Paint(fr, s2);
            bool deterministic = s1.Checksum == s2.Checksum && s1.TotalCommands == s2.TotalCommands;
            bool drew = s1.TotalCommands > 0;

            // FFI transparency: rendering the DECODED frame emits the same command shape.
            var decStruct = new SubstrateStructureProvider();
            (SwarmSubstrateFrameHeaderFfi h2, SwarmSubstrateDotFfi[] w2) = SwarmSubstrateFrameFfi.Encode(fr);
            SwarmSubstrateFrame dec = SwarmSubstrateFrameFfi.Decode(in h2, w2);
            SwarmSubstrateFrame decWithStruct = new(
                dec.Width, dec.Height, dec.Dark, dec.Reduced, dec.BatteryThrottled, dec.UiMode,
                dec.IsShapeMode, dec.Formed, dec.SettleProgress, dec.T, dec.Dt, dec.Stage,
                dec.Backdrop, dec.Dots, dec.Cx, dec.Cy, dec.CloudRadius, dec.SizePx, decStruct);
            var painter2 = make();
            var s3 = new RecordingDrawingSession { HashGeometry = false };
            painter2.Paint(decWithStruct, s3);
            bool structural = s3.FillCircleCount == s1.FillCircleCount
                && s3.GlowSpriteCount == s1.GlowSpriteCount
                && s3.LineBatchCount == s1.LineBatchCount
                && s3.FillPolygonCount == s1.FillPolygonCount
                && s3.GradientQuadCount == s1.GradientQuadCount
                && s3.StrokeCircleCount == s1.StrokeCircleCount
                && s3.StrokeRectCount == s1.StrokeRectCount
                && s3.BlurLayerCount == s1.BlurLayerCount
                && s3.MaskLayerCount == s1.MaskLayerCount;

            string regime = shapeMode ? "shape" : "free ";
            Report($"{name,-26} [{regime}] deterministic + FFI-transparent " +
                   $"(0x{s1.Checksum:X16}, {s1.TotalCommands,5} cmds)",
                   deterministic && drew && structural, ref failures);
        }
    }

    Console.WriteLine(failures == 0 ? "ALL CHECKS PASSED" : $"{failures} CHECK(S) FAILED");
    return failures == 0 ? 0 : 1;

    static void Report(string name, bool ok, ref int failures)
    {
        Console.WriteLine($"  [{(ok ? "PASS" : "FAIL")}] {name}");
        if (!ok) failures++;
    }
}

static SubstrateStage BuildStage()
{
    // Mesh family stage derivation (accent/accent2/ink) — representative for the lane.
    Rgba accent = FamilyAccent.A(SubstrateFamily.Mesh);
    Rgba accent2 = FamilyAccent.A2(SubstrateFamily.Mesh);
    Rgba ink = new Rgba(0.90, 0.93, 1.0);
    return new SubstrateStage(accent, accent2, ink, dark: true);
}

// canvas constants usable from static local funcs
partial class Program
{
    private const double canvasWConst = 1280;
    private const double canvasHConst = 800;
}

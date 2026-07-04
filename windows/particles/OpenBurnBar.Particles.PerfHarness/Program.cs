using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using OpenBurnBar.Particles.Drawing;
using OpenBurnBar.Particles.Ffi;
using OpenBurnBar.Particles.Math;
using OpenBurnBar.Particles.Model;
using OpenBurnBar.Particles.Substrates;
using OpenBurnBar.Particles.Substrates.Catalog;

// =============================================================================
//  Headless particle-engine perf + parity harness (Phase 3 / W6-DS-SWARM).
//
//  WHAT IT MEASURES: the per-frame CPU cost of the substrate RENDERER pass —
//  particle iteration + draw-command emission — for EVERY registered bespoke
//  painter (Starfire + the Constellation StarSapphire/Stellarium/Rimefrost + the
//  whole Volumetric family: Sunshaft/SmokedGlass/SilkFilament/DustMotes) over
//  hundreds-to-thousands of particles. This is the parity-critical, ARM64-sensitive
//  work that lives in C# (the simulation math stays in Swift Core and is vended
//  per-frame; see Ffi/SwarmSubstrateFrameFfi.cs).
//
//  WHAT IT DOES NOT MEASURE: GPU rasterization / additive-bloom compositing /
//  GaussianBlur — that is Win2D's job on a real device and is Windows/CI-deferred
//  (the CanvasAnimatedControl host + Win2DSubstrateDrawingSession in
//  windows/app/OpenBurnBar.App/Particles/). The 16.67ms budget below is therefore
//  the CPU-side frame budget: staying well under it is necessary (not sufficient)
//  for the full ARM64 60fps gate.
//
//  Draw against RecordingDrawingSession (counts commands, no rasterization), so a
//  frame's wall-time is the painter's own CPU cost.
// =============================================================================

int[] dotCounts = { 520, 1080, 2000 };
int frames = 600;   // 10 s at 60fps
int warmup = 120;

// crude arg parse: --dots 520,1080 --frames 600 --warmup 120
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

// The bespoke painters to exercise (plain defers to the default dot render).
var painters = new List<(string Name, Func<ISwarmSubstrate> Make)>();
foreach (SubstrateDescriptor d in SubstrateCatalog.SubstrateList)
{
    if (d.Id == SubstrateCatalog.PlainId) continue;
    painters.Add(($"{d.Label} [{d.Id}]", d.Make));
}

bool verifyOnly = Array.IndexOf(args, "--verify") >= 0;
if (verifyOnly)
{
    return RunVerify(painters);
}

Console.WriteLine("=================================================================");
Console.WriteLine(" OpenBurnBar particle-engine perf harness — W6-DS-SWARM (all substrates)");
Console.WriteLine("=================================================================");
Console.WriteLine($" Runtime : {System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription}");
Console.WriteLine($" Arch    : {System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture} on {System.Runtime.InteropServices.RuntimeInformation.OSDescription}");
Console.WriteLine($" Painters: {painters.Count} bespoke (Constellation + Volumetric families)");
Console.WriteLine($" Config  : {frames} timed frames (+{warmup} warmup), dt = 1/60, dark canvas");
Console.WriteLine($" Measures: CPU draw-command emission only (GPU composite = Win2D, CI-deferred)");
Console.WriteLine($" Budget  : 60fps CPU frame budget = 16.67 ms  (120fps = 8.33 ms)");
Console.WriteLine();

const double canvasW = 1280, canvasH = 800;
const double frameBudget60 = 1000.0 / 60.0;
const double frameBudget120 = 1000.0 / 120.0;

bool allUnder60 = true;

foreach ((string name, Func<ISwarmSubstrate> make) in painters)
{
    Console.WriteLine($"════ {name} ════════════════════════════════════════════");
    foreach (int n in dotCounts)
    {
        RunScenario(name, make, n, batteryThrottled: false);
        RunScenario(name, make, n, batteryThrottled: true);
    }
    Console.WriteLine();
}

Console.WriteLine("=================================================================");
Console.WriteLine(allUnder60
    ? " VERDICT: every substrate × scenario's median + p95 CPU frame time is under the 60fps budget."
    : " VERDICT: at least one scenario exceeded the 60fps CPU budget (see FAIL rows).");
Console.WriteLine("=================================================================");

return allUnder60 ? 0 : 1;

void RunScenario(string name, Func<ISwarmSubstrate> make, int n, bool batteryThrottled)
{
    SwarmSubstrateDot[] dots = BuildSyntheticSwarm(n);
    ISwarmSubstrate painter = make();
    var session = new RecordingDrawingSession { HashGeometry = false };

    SubstrateStage stage = BuildStage();
    var timings = new double[frames];
    long lastTotalCommands = 0, lastFills = 0, lastGlows = 0, lastLineBatches = 0, lastPolys = 0, lastBlur = 0;

    var sw = new Stopwatch();
    for (int frame = 0; frame < warmup + frames; frame++)
    {
        double t = frame / 60.0;
        AdvanceSwarm(dots, t);
        var f = new SwarmSubstrateFrame(
            width: canvasW, height: canvasH, dark: true, reduced: false,
            batteryThrottled: batteryThrottled, uiMode: UIMode.Standard,
            isShapeMode: true, formed: true, settleProgress: 0.85,
            t: t, dt: 1.0, stage: stage, backdrop: null, dots: dots,
            cx: canvasW / 2, cy: canvasH / 2, cloudRadius: 260, sizePx: 1.6);

        session.Reset();
        if (frame >= warmup) sw.Restart();
        painter.Paint(f, session);
        if (frame >= warmup)
        {
            sw.Stop();
            timings[frame - warmup] = sw.Elapsed.TotalMilliseconds;
        }

        lastTotalCommands = session.TotalCommands;
        lastFills = session.FillCircleCount;
        lastGlows = session.GlowSpriteCount;
        lastLineBatches = session.LineBatchCount + session.DashedLineBatchCount;
        lastPolys = session.FillPolygonCount + session.FillRoundedQuadCount + session.StrokePolylineCount;
        lastBlur = session.BlurLayerCount;
    }

    Array.Sort(timings);
    double min = timings[0];
    double max = timings[frames - 1];
    double median = Pct(timings, 0.50);
    double p95 = Pct(timings, 0.95);
    double p99 = Pct(timings, 0.99);
    double mean = Mean(timings);

    bool under60 = median <= frameBudget60 && p95 <= frameBudget60;
    if (!under60) allUnder60 = false;

    string label = batteryThrottled ? "throttled" : "full     ";
    Console.WriteLine($"--- {n,4} dots · {label} -----------------------------------------------");
    Console.WriteLine($"  frame ms : min {min,7:F4}  median {median,7:F4}  p95 {p95,7:F4}  p99 {p99,7:F4}  max {max,7:F4}  mean {mean,7:F4}");
    Console.WriteLine($"  eff FPS  : median {1000.0 / median,7:F0}   p95 {1000.0 / p95,7:F0}");
    Console.WriteLine($"  cmds     : {lastTotalCommands,6}  (fills {lastFills}, glow-sprites {lastGlows}, line-batches {lastLineBatches}, polys/quads {lastPolys}, blur-layers {lastBlur})");
    Console.WriteLine($"  60fps    : median {(median <= frameBudget60 ? "PASS" : "FAIL")}  p95 {(p95 <= frameBudget60 ? "PASS" : "FAIL")}   " +
                      $"| 120fps: median {(median <= frameBudget120 ? "PASS" : "FAIL")}  p95 {(p95 <= frameBudget120 ? "PASS" : "FAIL")}   " +
                      $"| headroom@60 median {frameBudget60 / median,5:F1}x");
}

static double Pct(double[] sorted, double p)
{
    if (sorted.Length == 0) return 0;
    int idx = (int)System.Math.Ceiling(p * sorted.Length) - 1;
    if (idx < 0) idx = 0;
    if (idx >= sorted.Length) idx = sorted.Length - 1;
    return sorted[idx];
}

static double Mean(double[] v)
{
    double s = 0;
    foreach (var x in v) s += x;
    return s / v.Length;
}

// A synthetic swarm shaped like the real field: dots on a soft disc around center,
// brand-ish colors sampled off the iris ramp by a stable per-dot seed, mixed sizes,
// most in-shape. Realistic geometry keeps the numbers honest.
static SwarmSubstrateDot[] BuildSyntheticSwarm(int n)
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
        bool inShape = rng.Next() > 0.15;
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

// Light per-frame motion (orbit + gentle radial breathing) so successive frames
// present different geometry — mirrors live-field cost, no constant folding.
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

static SwarmSubstrateFrame BuildFrame(int n, bool battery, double t)
{
    SubstrateStage stage = BuildStage();
    return new SwarmSubstrateFrame(
        width: canvasWConst, height: canvasHConst, dark: true, reduced: false,
        batteryThrottled: battery, uiMode: UIMode.Standard,
        isShapeMode: true, formed: true, settleProgress: 0.85,
        t: t, dt: 1.0, stage: stage, backdrop: new Rgba(0.03, 0.04, 0.08, 1.0),
        dots: BuildSyntheticSwarm(n), cx: canvasWConst / 2, cy: canvasHConst / 2,
        cloudRadius: 260, sizePx: 1.6);
}

// Self-check: proves the FFI vend contract round-trips and EVERY substrate renders
// deterministically (both prerequisites for the W11 Mac↔Windows layout-parity gate).
static int RunVerify(List<(string Name, Func<ISwarmSubstrate> Make)> painters)
{
    Console.WriteLine("=== particle-engine self-check (--verify) ===");
    int failures = 0;

    // 1) FFI round-trip: Encode (reference emitter) → Decode == original (within float32 epsilon).
    SwarmSubstrateFrame frame = BuildFrame(1080, battery: false, t: 3.14159);
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

    // 2) PlainDots defers (returns false) so the host runs its default dot pass.
    bool plainDefers = new PlainDotsSubstrate().Paint(frame, new RecordingDrawingSession()) == false;
    Report("PlainDotsSubstrate defers to default dot render", plainDefers, ref failures);

    // 3) Per-substrate parity goldens. For each bespoke painter, on a representative
    //    dark frame:
    //      (a) non-empty     — the paint LOGIC actually emits draw commands.
    //      (b) cross-instance determinism — two FRESH instances rendering the same
    //          frame fold to the SAME FNV-1a checksum + command counts (no hidden
    //          per-instance nondeterminism; caches build identically). This is the
    //          exact Mac↔Windows golden.
    //      (c) warm-cache stability — the same instance re-rendering the same frame
    //          reproduces its checksum (per-frame scratch never drifts).
    //      (d) reduced-motion determinism — with reduced=true a re-render is byte-stable.
    SwarmSubstrateFrame vf = BuildVerifyFrame(1080, reduced: false, t: 2.0);
    SwarmSubstrateFrame vfReduced = BuildVerifyFrame(1080, reduced: true, t: 2.0);
    foreach ((string name, Func<ISwarmSubstrate> make) in painters)
    {
        var a1 = new RecordingDrawingSession { HashGeometry = true };
        var a2 = new RecordingDrawingSession { HashGeometry = true };
        var a3 = new RecordingDrawingSession { HashGeometry = true };
        ISwarmSubstrate p1 = make();
        ISwarmSubstrate p2 = make();
        p1.Paint(vf, a1);   // fresh instance #1
        p2.Paint(vf, a2);   // fresh instance #2 (cross-instance determinism)
        p1.Paint(vf, a3);   // same instance, warm cache (stability)

        var r1 = new RecordingDrawingSession { HashGeometry = true };
        var r2 = new RecordingDrawingSession { HashGeometry = true };
        ISwarmSubstrate pr = make();
        pr.Paint(vfReduced, r1);
        pr.Paint(vfReduced, r2);

        bool nonEmpty = a1.TotalCommands > 0;
        bool crossInstance = a1.Checksum == a2.Checksum && a1.TotalCommands == a2.TotalCommands;
        bool warmStable = a3.Checksum == a1.Checksum && a3.TotalCommands == a1.TotalCommands;
        bool reducedStable = r1.Checksum == r2.Checksum && r1.TotalCommands == r2.TotalCommands && r1.TotalCommands > 0;
        bool ok = nonEmpty && crossInstance && warmStable && reducedStable;
        Report($"{name}  (cmds {a1.TotalCommands}, checksum 0x{a1.Checksum:X16})", ok, ref failures);
        if (!ok)
        {
            if (!nonEmpty) Console.WriteLine("        · FAIL: emitted 0 draw commands");
            if (!crossInstance) Console.WriteLine($"        · FAIL: cross-instance mismatch (0x{a1.Checksum:X16}/{a1.TotalCommands} vs 0x{a2.Checksum:X16}/{a2.TotalCommands})");
            if (!warmStable) Console.WriteLine($"        · FAIL: warm-cache drift (0x{a3.Checksum:X16}/{a3.TotalCommands})");
            if (!reducedStable) Console.WriteLine($"        · FAIL: reduced-motion nondeterminism (0x{r1.Checksum:X16}/{r1.TotalCommands} vs 0x{r2.Checksum:X16}/{r2.TotalCommands})");
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

// A representative verify frame: a settled dark shape with a fixed clock so a checksum
// is a stable golden. `reduced` freezes twinkle to the poised still (the reduced path).
static SwarmSubstrateFrame BuildVerifyFrame(int n, bool reduced, double t)
{
    SubstrateStage stage = BuildStage();
    return new SwarmSubstrateFrame(
        width: canvasWConst, height: canvasHConst, dark: true, reduced: reduced,
        batteryThrottled: false, uiMode: UIMode.Standard,
        isShapeMode: true, formed: true, settleProgress: 0.85,
        t: t, dt: 1.0, stage: stage, backdrop: new Rgba(0.03, 0.04, 0.08, 1.0),
        dots: BuildSyntheticSwarm(n), cx: canvasWConst / 2, cy: canvasHConst / 2,
        cloudRadius: 260, sizePx: 1.6);
}

static SubstrateStage BuildStage()
{
    // Mirror the Swift makeSubstrateFrame stage derivation for the Constellation family.
    Rgba accent = FamilyAccent.A(SubstrateFamily.Constellation);
    Rgba accent2 = accent.ToWhite(0.28).Mix(new Rgba(0.55, 0.78, 1.0), 0.35);
    Rgba ink = new Rgba(0.90, 0.93, 1.0);
    return new SubstrateStage(accent, accent2, ink, dark: true);
}

// canvas constants usable from static local funcs
partial class Program
{
    private const double canvasWConst = 1280;
    private const double canvasHConst = 800;
}

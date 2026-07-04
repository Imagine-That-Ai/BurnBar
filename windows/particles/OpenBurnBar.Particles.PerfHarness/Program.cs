using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using OpenBurnBar.Particles.Drawing;
using OpenBurnBar.Particles.Ffi;
using OpenBurnBar.Particles.Math;
using OpenBurnBar.Particles.Model;
using OpenBurnBar.Particles.Substrates;

// =============================================================================
//  Headless particle-engine perf harness (Phase 3 / W6-DS-SWARM sub-spike).
//
//  WHAT IT MEASURES: the per-frame CPU cost of the substrate RENDERER pass —
//  particle iteration + draw-command emission — for the flagship bespoke painter
//  (Starfire / "Stellar Plasma") over hundreds-to-thousands of particles. This is
//  the parity-critical, ARM64-sensitive work that lives in C# (the simulation math
//  stays in Swift Core and is vended per-frame; see Ffi/SwarmSubstrateFrameFfi.cs).
//
//  WHAT IT DOES NOT MEASURE: GPU rasterization / additive-bloom compositing /
//  GaussianBlur — that is Win2D's job on a real device and is Windows/CI-deferred
//  (the CanvasAnimatedControl host in windows/app/OpenBurnBar.App/Particles/). The
//  60fps budget below is therefore the CPU-side frame budget: if command emission
//  alone blew 16.67 ms we'd never hit 60fps; staying well under it is necessary
//  (not sufficient) for the full ARM64 60fps gate.
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

bool verifyOnly = Array.IndexOf(args, "--verify") >= 0;
if (verifyOnly)
{
    return RunVerify();
}

Console.WriteLine("=================================================================");
Console.WriteLine(" OpenBurnBar particle-engine perf harness — W6-DS-SWARM sub-spike");
Console.WriteLine("=================================================================");
Console.WriteLine($" Runtime : {System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription}");
Console.WriteLine($" Arch    : {System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture} on {System.Runtime.InteropServices.RuntimeInformation.OSDescription}");
Console.WriteLine($" Painter : Starfire (Constellation / \"Stellar Plasma\") — dark canvas, full bloom+cross path");
Console.WriteLine($" Config  : {frames} timed frames (+{warmup} warmup), dt = 1/60");
Console.WriteLine($" Measures: CPU draw-command emission only (GPU composite = Win2D, CI-deferred)");
Console.WriteLine($" Budget  : 60fps CPU frame budget = 16.67 ms  (120fps = 8.33 ms)");
Console.WriteLine();

const double canvasW = 1280, canvasH = 800;
const double frameBudget60 = 1000.0 / 60.0;
const double frameBudget120 = 1000.0 / 120.0;

bool allUnder60 = true;

foreach (int n in dotCounts)
{
    // Two scenarios: full path (batteryThrottled=false) and the throttled path.
    RunScenario(n, batteryThrottled: false);
    RunScenario(n, batteryThrottled: true);
}

Console.WriteLine("=================================================================");
Console.WriteLine(allUnder60
    ? " VERDICT: every scenario's median + p95 CPU frame time is under the 60fps budget."
    : " VERDICT: at least one scenario exceeded the 60fps CPU budget (see FAIL rows).");
Console.WriteLine("=================================================================");

return allUnder60 ? 0 : 1;

void RunScenario(int n, bool batteryThrottled)
{
    SwarmSubstrateDot[] dots = BuildSyntheticSwarm(n);
    var starfire = new StarfireSubstrate();
    var session = new RecordingDrawingSession { HashGeometry = false };

    SubstrateStage stage = BuildStage();
    var timings = new double[frames];
    long lastTotalCommands = 0, lastFills = 0, lastGlows = 0, lastLineBatches = 0, lastSegments = 0, lastBlur = 0;

    var sw = new Stopwatch();
    for (int frame = 0; frame < warmup + frames; frame++)
    {
        double t = frame / 60.0;
        // Animate the field a little so twinkle/positions vary frame-to-frame
        // (defeats any accidental constant-folding and mirrors live motion cost).
        AdvanceSwarm(dots, t);
        var f = new SwarmSubstrateFrame(
            width: canvasW, height: canvasH, dark: true, reduced: false,
            batteryThrottled: batteryThrottled, uiMode: UIMode.Standard,
            isShapeMode: true, formed: true, settleProgress: 0.85,
            t: t, dt: 1.0, stage: stage, backdrop: null, dots: dots,
            cx: canvasW / 2, cy: canvasH / 2, cloudRadius: 260, sizePx: 1.6);

        session.Reset();
        if (frame >= warmup) sw.Restart();
        starfire.Paint(f, session);
        if (frame >= warmup)
        {
            sw.Stop();
            timings[frame - warmup] = sw.Elapsed.TotalMilliseconds;
        }

        lastTotalCommands = session.TotalCommands;
        lastFills = session.FillCircleCount;
        lastGlows = session.GlowSpriteCount;
        lastLineBatches = session.LineBatchCount;
        lastSegments = session.LineSegmentCount;
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
    Console.WriteLine($"--- {n,4} dots · {label} path ---------------------------------------");
    Console.WriteLine($"  frame time ms : min {min,7:F4}  median {median,7:F4}  p95 {p95,7:F4}  p99 {p99,7:F4}  max {max,7:F4}  mean {mean,7:F4}");
    Console.WriteLine($"  eff. FPS      : median {1000.0 / median,8:F0}   p95 {1000.0 / p95,8:F0}");
    Console.WriteLine($"  draw commands : {lastTotalCommands,6}  (fills {lastFills}, glow-sprites {lastGlows}, line-batches {lastLineBatches}/{lastSegments} segs, blur-layers {lastBlur})");
    Console.WriteLine($"  60fps budget  : median {(median <= frameBudget60 ? "PASS" : "FAIL")}  p95 {(p95 <= frameBudget60 ? "PASS" : "FAIL")}   " +
                      $"| 120fps: median {(median <= frameBudget120 ? "PASS" : "FAIL")}  p95 {(p95 <= frameBudget120 ? "PASS" : "FAIL")}");
    Console.WriteLine($"  headroom @60  : median {frameBudget60 / median,6:F1}x   p95 {frameBudget60 / p95,6:F1}x");
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

static double Mean(double[] v)
{
    double s = 0;
    foreach (var x in v) s += x;
    return s / v.Length;
}

// A synthetic swarm shaped like the real field: dots on a soft disc around center,
// brand-ish colors sampled off the iris ramp by a stable per-dot seed, mixed sizes,
// most in-shape. The painter cost is independent of exact values, but realistic
// geometry keeps the numbers honest.
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

// Self-check: proves the FFI vend contract round-trips and the parity harness is
// deterministic (both are prerequisites for the W11 Mac↔Windows layout-parity gate).
static int RunVerify()
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

    // 2) Determinism: two renders of the same frame yield identical checksums + command counts.
    var painter = new StarfireSubstrate();
    var s1 = new RecordingDrawingSession { HashGeometry = true };
    var s2 = new RecordingDrawingSession { HashGeometry = true };
    painter.Paint(frame, s1);
    painter.Paint(frame, s2);
    bool deterministic = s1.Checksum == s2.Checksum && s1.TotalCommands == s2.TotalCommands;
    Report($"Deterministic render (checksum 0x{s1.Checksum:X16}, {s1.TotalCommands} cmds)", deterministic, ref failures);

    // 3) FFI transparency: rendering the DECODED frame emits the same command shape
    //    (fills/glows/lines/blur) as the original — the seam preserves structure.
    var s3 = new RecordingDrawingSession { HashGeometry = false };
    var s4 = new RecordingDrawingSession { HashGeometry = false };
    painter.Paint(frame, s3);
    painter.Paint(decoded, s4);
    bool structural = s3.FillCircleCount == s4.FillCircleCount
        && s3.GlowSpriteCount == s4.GlowSpriteCount
        && s3.LineBatchCount == s4.LineBatchCount
        && s3.BlurLayerCount == s4.BlurLayerCount;
    Report($"FFI-transparent command shape (fills {s3.FillCircleCount}, glows {s3.GlowSpriteCount}, blur {s3.BlurLayerCount})", structural, ref failures);

    // 4) PlainDots defers (returns false) so the host runs its default dot pass.
    bool plainDefers = new PlainDotsSubstrate().Paint(frame, new RecordingDrawingSession()) == false;
    Report("PlainDotsSubstrate defers to default dot render", plainDefers, ref failures);

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

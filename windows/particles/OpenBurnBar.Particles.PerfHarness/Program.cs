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
//  WHAT IT MEASURES: the per-frame CPU cost of every ported substrate RENDERER pass
//  — particle iteration + draw-command emission — over hundreds-to-thousands of
//  particles. This is the parity-critical, ARM64-sensitive work that lives in C#
//  (the simulation math stays in Swift Core and is vended per-frame; see
//  Ffi/SwarmSubstrateFrameFfi.cs). Substrates covered: the Constellation flagship
//  (Starfire) plus the full FLOW family (Plankton Wake / Glass Ribbon / Silk
//  Streamline / Petal Drift) and the full AURORA family (Wisp / Ice Prism / Aurora
//  Filament / Drift Motes).
//
//  WHAT IT DOES NOT MEASURE: GPU rasterization / additive-bloom compositing /
//  GaussianBlur — that is Win2D's job on a real device and is Windows/CI-deferred
//  (the CanvasAnimatedControl host in windows/app/OpenBurnBar.App/Particles/). The
//  60fps budget below is therefore the CPU-side frame budget: if command emission
//  alone blew 16.67 ms we'd never hit 60fps; staying well under it is necessary
//  (not sufficient) for the full ARM64 60fps gate.
//
//  METHODOLOGY: dots are held at a FORMED layout (steady-state hold), so the three
//  streamline substrates' cached NN-walk/kNN structure is warm — exactly what a
//  60fps hold sees. The one-time structure build cost (paid on a reform, not per
//  frame) is reported separately. Motion still varies every frame through `t`, so
//  there is no constant-folding. Draw against RecordingDrawingSession (counts
//  commands, no rasterization), so a frame's wall-time is the painter's own CPU cost.
// =============================================================================

int[] dotCounts = { 520, 1080, 2000 };
int frames = 400;   // ~6.7 s at 60fps
int warmup = 100;

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

// The bespoke painters under test (plain defers to the default dot render, so it is
// not timed). Ordered Constellation → Flow → Aurora, mirroring the catalog.
var painters = new List<(string Id, string Label, SubstrateFamily Family, Func<ISwarmSubstrate> Make)>();
foreach (SubstrateDescriptor d in SubstrateCatalog.SubstrateList)
{
    if (d.Id == SubstrateCatalog.PlainId) continue;
    painters.Add((d.Id, d.Label, d.Family, d.Make));
}

bool verifyOnly = Array.IndexOf(args, "--verify") >= 0;
if (verifyOnly)
{
    return RunVerify(painters);
}

Console.WriteLine("=================================================================");
Console.WriteLine(" OpenBurnBar particle-engine perf harness — Flow + Aurora families");
Console.WriteLine("=================================================================");
Console.WriteLine($" Runtime : {System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription}");
Console.WriteLine($" Arch    : {System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture} on {System.Runtime.InteropServices.RuntimeInformation.OSDescription}");
Console.WriteLine($" Painters: {painters.Count} bespoke (Constellation·1 + Flow·4 + Aurora·4) — dark canvas, full path");
Console.WriteLine($" Config  : {frames} timed frames (+{warmup} warmup), dt = 1/60, formed hold");
Console.WriteLine($" Measures: CPU draw-command emission only (GPU composite = Win2D, CI-deferred)");
Console.WriteLine($" Budget  : 60fps CPU frame budget = 16.67 ms  (120fps = 8.33 ms)");
Console.WriteLine();

const double canvasW = 1280, canvasH = 800;
const double frameBudget60 = 1000.0 / 60.0;
const double frameBudget120 = 1000.0 / 120.0;

bool allUnder60 = true;

foreach (var painter in painters)
{
    Console.WriteLine($"### {painter.Label}  ({painter.Id})");
    SubstrateStage stage = BuildStage(painter.Family);
    foreach (int n in dotCounts)
    {
        RunScenario(painter.Make, stage, n, batteryThrottled: false);
        RunScenario(painter.Make, stage, n, batteryThrottled: true);
    }
    Console.WriteLine();
}

// One-time structure (NN-walk + kNN) build cost — paid on a reform, NOT per frame —
// for the three streamline substrates that consume it.
Console.WriteLine("--- one-time NN-walk/kNN structure build cost (amortized once per reform) ---");
foreach (int n in dotCounts)
{
    var probe = new SubstrateStructure();
    SwarmSubstrateDot[] dots = BuildSyntheticSwarm(n);
    var sw = new Stopwatch();
    // discard first (JIT), then time a cold build via a fresh provider each iter.
    probe.Get(dots, 6);
    double best = double.MaxValue;
    for (int r = 0; r < 12; r++)
    {
        var cold = new SubstrateStructure();
        sw.Restart();
        cold.Get(dots, 6);
        sw.Stop();
        best = System.Math.Min(best, sw.Elapsed.TotalMilliseconds);
    }
    Console.WriteLine($"  {n,4} dots : {best,7:F3} ms (best of 12 cold builds)");
}
Console.WriteLine();

Console.WriteLine("=================================================================");
Console.WriteLine(allUnder60
    ? " VERDICT: every substrate/scenario median + p95 CPU frame time is under the 60fps budget."
    : " VERDICT: at least one scenario exceeded the 60fps CPU budget (see FAIL rows).");
Console.WriteLine("=================================================================");

return allUnder60 ? 0 : 1;

void RunScenario(Func<ISwarmSubstrate> make, SubstrateStage stage, int n, bool batteryThrottled)
{
    SwarmSubstrateDot[] dots = BuildSyntheticSwarm(n);
    ISwarmSubstrate painter = make();
    var session = new RecordingDrawingSession { HashGeometry = false };

    var timings = new double[frames];
    long lastTotalCommands = 0, lastFills = 0, lastGlows = 0, lastLineBatches = 0,
        lastPolys = 0, lastGradPolys = 0, lastStrokes = 0, lastBlur = 0;

    var sw = new Stopwatch();
    for (int frame = 0; frame < warmup + frames; frame++)
    {
        double t = frame / 60.0;
        // Positions held at a formed layout (streamline structure stays warm); motion
        // varies through `t` so there is no constant-folding.
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
        lastLineBatches = session.LineBatchCount;
        lastPolys = session.FillPolygonCount;
        lastGradPolys = session.FillPolygonGradientCount;
        lastStrokes = session.StrokePolylineCount;
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
    Console.WriteLine($"  {n,4} dots · {label} | ms med {median,7:F4} p95 {p95,7:F4} p99 {p99,7:F4} max {max,7:F4} " +
                      $"| fps~{1000.0 / median,6:F0} | cmds {lastTotalCommands,6} " +
                      $"(f{lastFills} g{lastGlows} lb{lastLineBatches} P{lastPolys} GP{lastGradPolys} s{lastStrokes} bl{lastBlur}) " +
                      $"| 60fps {(under60 ? "PASS" : "FAIL")} {frameBudget60 / System.Math.Max(median, 1e-9),5:F0}x " +
                      $"| 120fps {(median <= frameBudget120 && p95 <= frameBudget120 ? "PASS" : "FAIL")}");
    _ = min;
    _ = mean;
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

static SwarmSubstrateFrame BuildFrame(int n, SubstrateStage stage, bool battery, double t)
{
    return new SwarmSubstrateFrame(
        width: canvasWConst, height: canvasHConst, dark: true, reduced: false,
        batteryThrottled: battery, uiMode: UIMode.Standard,
        isShapeMode: true, formed: true, settleProgress: 0.85,
        t: t, dt: 1.0, stage: stage, backdrop: new Rgba(0.03, 0.04, 0.08, 1.0),
        dots: BuildSyntheticSwarm(n), cx: canvasWConst / 2, cy: canvasHConst / 2,
        cloudRadius: 260, sizePx: 1.6);
}

// Self-check: proves the FFI vend contract round-trips and that EVERY ported painter
// renders deterministically + FFI-transparently (both prerequisites for the W11
// Mac↔Windows layout-parity gate), plus catalog integrity.
static int RunVerify(List<(string Id, string Label, SubstrateFamily Family, Func<ISwarmSubstrate> Make)> painters)
{
    Console.WriteLine("=== particle-engine self-check (--verify) ===");
    int failures = 0;

    // 1) FFI round-trip: Encode (reference emitter) → Decode == original (float32 epsilon).
    SubstrateStage cstage = BuildStage(SubstrateFamily.Constellation);
    SwarmSubstrateFrame frame = BuildFrame(1080, cstage, battery: false, t: 3.14159);
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

    // 2+3) Per-painter determinism + FFI-transparency, on both canvas polarities and
    //      the throttled path (so every code branch is exercised deterministically).
    foreach (var painter in painters)
    {
        SubstrateStage stage = BuildStage(painter.Family);
        bool detOk = true, structOk = true;
        long cmds = 0;
        ulong checksum = 0;

        foreach (bool dark in new[] { true, false })
        foreach (bool battery in new[] { false, true })
        {
            SwarmSubstrateFrame fr = MakeFrame(1080, stage, dark, battery, t: 2.0);
            SwarmSubstrateFrame de = ReEncode(fr);

            var s1 = new RecordingDrawingSession { HashGeometry = true };
            var s2 = new RecordingDrawingSession { HashGeometry = true };
            painter.Make().Paint(fr, s1);
            painter.Make().Paint(fr, s2);
            if (s1.Checksum != s2.Checksum || s1.TotalCommands != s2.TotalCommands) detOk = false;

            var s3 = new RecordingDrawingSession { HashGeometry = false };
            var s4 = new RecordingDrawingSession { HashGeometry = false };
            painter.Make().Paint(fr, s3);
            painter.Make().Paint(de, s4);
            // FFI-transparency: painting the float32-decoded frame emits the SAME
            // command shape. Cover every command type any family emits.
            if (s3.FillCircleCount != s4.FillCircleCount || s3.GlowSpriteCount != s4.GlowSpriteCount
                || s3.StrokeCircleCount != s4.StrokeCircleCount
                || s3.LineBatchCount != s4.LineBatchCount || s3.BlurLayerCount != s4.BlurLayerCount
                || s3.MaskLayerCount != s4.MaskLayerCount
                || s3.FillPolygonCount != s4.FillPolygonCount
                || s3.GradientQuadCount != s4.GradientQuadCount
                || s3.StrokeRectCount != s4.StrokeRectCount
                || s3.FillPolygonGradientCount != s4.FillPolygonGradientCount
                || s3.StrokePolylineCount != s4.StrokePolylineCount)
            {
                structOk = false;
            }

            if (dark && !battery) { cmds = s1.TotalCommands; checksum = s1.Checksum; }
        }

        Report($"{painter.Label,-18} deterministic + FFI-transparent (dark cmds {cmds}, ck 0x{checksum:X16})",
            detOk && structOk, ref failures);
    }

    // 4) PlainDots defers (returns false) so the host runs its default dot pass.
    bool plainDefers = new OpenBurnBar.Particles.Substrates.PlainDotsSubstrate().Paint(frame, new RecordingDrawingSession()) == false;
    Report("PlainDotsSubstrate defers to default dot render", plainDefers, ref failures);

    // 5) Catalog integrity: the six per-family plain descriptors + every ported
    //    bespoke; each family's first Entries slot is its shared plain; the id index
    //    round-trips. Counts are DERIVED (not hard-coded) so this invariant holds as
    //    each Wave-4 family lands (Flow/Aurora #1212, Mesh/Moiré #1214, Volumetric +
    //    remaining Constellation #1213).
    SubstrateFamily[] allFamilies = (SubstrateFamily[])Enum.GetValues(typeof(SubstrateFamily));
    int bespokeTotal = 0;
    bool plainFirst = true;
    foreach (SubstrateFamily fam in allFamilies)
    {
        bespokeTotal += SubstrateCatalog.BespokeFor(fam).Length;
        if (SubstrateCatalog.Entries(fam)[0].Id != SubstrateCatalog.PlainId) plainFirst = false;
    }
    int expectedTotal = allFamilies.Length + bespokeTotal;
    bool catalogOk = plainFirst
        && SubstrateCatalog.SubstrateList.Length == expectedTotal
        && SubstrateCatalog.ById.ContainsKey(SubstrateCatalog.PlainId);
    Report($"Catalog integrity ({SubstrateCatalog.SubstrateList.Length} registered: {allFamilies.Length} plain + {bespokeTotal} bespoke)", catalogOk, ref failures);

    Console.WriteLine(failures == 0 ? "ALL CHECKS PASSED" : $"{failures} CHECK(S) FAILED");
    return failures == 0 ? 0 : 1;

    static void Report(string name, bool ok, ref int failures)
    {
        Console.WriteLine($"  [{(ok ? "PASS" : "FAIL")}] {name}");
        if (!ok) failures++;
    }
}

static SwarmSubstrateFrame MakeFrame(int n, SubstrateStage stage, bool dark, bool battery, double t)
{
    // Keep the test frame INTERNALLY CONSISTENT: the engine derives the stage's
    // dark flag from the canvas appearance, so Stage.Dark must track `dark` (some
    // substrates, e.g. Mesh "Gradient Patch", gate their catchlight pass on
    // frame.Stage.Dark — an inconsistent stage would make the frame fail its own
    // FFI round-trip, which resets Stage.Dark to frame.Dark).
    var frameStage = new SubstrateStage(stage.Accent, stage.Accent2, stage.Ink, dark);
    return new SwarmSubstrateFrame(
        width: canvasWConst, height: canvasHConst, dark: dark, reduced: false,
        batteryThrottled: battery, uiMode: UIMode.Standard,
        isShapeMode: true, formed: true, settleProgress: 0.85,
        t: t, dt: 1.0, stage: frameStage, backdrop: dark ? new Rgba(0.03, 0.04, 0.08, 1.0) : new Rgba(0.96, 0.97, 1.0, 1.0),
        dots: BuildSyntheticSwarm(n), cx: canvasWConst / 2, cy: canvasHConst / 2,
        cloudRadius: 260, sizePx: 1.6);
}

// Re-pack a frame through the FFI wire (Encode→Decode), preserving the stage +
// derived anchors so a painter sees a float32-round-tripped copy.
static SwarmSubstrateFrame ReEncode(SwarmSubstrateFrame fr)
{
    (SwarmSubstrateFrameHeaderFfi h, SwarmSubstrateDotFfi[] w) = SwarmSubstrateFrameFfi.Encode(fr);
    return SwarmSubstrateFrameFfi.Decode(in h, w);
}

static SubstrateStage BuildStage(SubstrateFamily family)
{
    // Mirror the picker/engine stage derivation: the family accent pair + a cool ink.
    Rgba accent = FamilyAccent.A(family);
    Rgba accent2 = FamilyAccent.A2(family);
    Rgba ink = new Rgba(0.90, 0.93, 1.0);
    return new SubstrateStage(accent, accent2, ink, dark: true);
}

// canvas constants usable from static local funcs
partial class Program
{
    private const double canvasWConst = 1280;
    private const double canvasHConst = 800;
}

using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Text.Json.Nodes;
using OpenBurnBar.Pretext;
using OpenBurnBar.Pretext.MetricParity;
using Xunit;

namespace OpenBurnBar.Pretext.Tests;

// Proves the metric-parity harness is complete + correct on macOS:
//   * the committed corpus + Mac golden load and are internally consistent;
//   * the golden is an authoritative capture, not a scaffold placeholder;
//   * the comparison passes on identity and fails on out-of-tolerance drift;
//   * MeasureAsync drives the corpus through the engine end-to-end (via a
//     golden-replay host) and lands back on the golden.
//
// The LIVE Chromium-vs-WebKit run (real WebView2 vs this golden) is the only piece
// that needs Windows; it is Skip-marked below and runs on the dev host / Windows CI.

public class MetricParityHarnessTests
{
    [Fact]
    public void Corpus_loads_with_cases()
    {
        var corpus = MetricParityRunner.LoadCorpus();
        Assert.True(corpus.Cases.Count >= 8, "corpus should cover the Chat-critical measurement paths");
        Assert.All(corpus.Cases, c => Assert.False(string.IsNullOrWhiteSpace(c.Id)));
        // Distinct ids.
        Assert.Equal(corpus.Cases.Count, corpus.Cases.Select(c => c.Id).Distinct().Count());
    }

    [Fact]
    public void Golden_is_authoritative_capture_not_scaffold()
    {
        var golden = MetricParityRunner.LoadGolden();
        Assert.False(golden.IsScaffold, "golden.mac.json must be a real WebKit capture, not a placeholder");
        Assert.Equal("macos-webkit", golden.CapturedOn);
    }

    [Fact]
    public void Every_corpus_case_has_a_golden_entry()
    {
        var corpus = MetricParityRunner.LoadCorpus();
        var golden = MetricParityRunner.LoadGolden();
        foreach (var c in corpus.Cases)
        {
            Assert.True(golden.Results.ContainsKey(c.Id), $"missing golden for case '{c.Id}'");
        }
    }

    [Fact]
    public void Golden_covers_the_method_shaped_fields()
    {
        var corpus = MetricParityRunner.LoadCorpus();
        var golden = MetricParityRunner.LoadGolden();
        foreach (var c in corpus.Cases)
        {
            var g = golden.Results[c.Id];
            switch (c.ResolvedMethod)
            {
                case ParityMethod.Layout:
                    Assert.NotNull(g.Height);
                    Assert.NotNull(g.LineCount);
                    break;
                case ParityMethod.LayoutWithLines:
                    Assert.NotNull(g.Height);
                    Assert.NotNull(g.LineCount);
                    Assert.NotNull(g.LineWidths);
                    Assert.Equal(g.LineCount, g.LineWidths!.Count);
                    break;
                case ParityMethod.MeasureLineStats:
                    Assert.NotNull(g.LineCount);
                    Assert.NotNull(g.MaxLineWidth);
                    break;
                case ParityMethod.MeasureNaturalWidth:
                    Assert.NotNull(g.Width);
                    break;
                case ParityMethod.LayoutRichInline:
                    Assert.NotNull(g.LineCount);
                    Assert.NotNull(g.LineWidths);
                    break;
            }
        }
    }

    [Fact]
    public void Compare_passes_on_identity()
    {
        var corpus = MetricParityRunner.LoadCorpus();
        var golden = MetricParityRunner.LoadGolden();
        var measured = GoldenAsMeasured(golden);
        var report = MetricParityRunner.Compare(corpus, measured, golden);
        Assert.True(report.Passed, MetricParityRunner.FormatReport(report));
        Assert.Empty(report.MissingCases);
        Assert.All(report.Discrepancies, d => Assert.True(d.WithinTolerance));
    }

    [Fact]
    public void Compare_flags_out_of_tolerance_drift()
    {
        var corpus = MetricParityRunner.LoadCorpus();
        var golden = MetricParityRunner.LoadGolden();
        var measured = GoldenAsMeasured(golden);

        // Perturb one scalar well beyond tolerance.
        var victim = corpus.Cases.First(c => c.ResolvedMethod == ParityMethod.LayoutWithLines);
        var g = golden.Results[victim.Id];
        measured[victim.Id] = new MeasuredResult
        {
            Height = (g.Height ?? 0) + 25, // way past the height tolerance
            LineCount = g.LineCount,
            LineWidths = g.LineWidths,
            LineTexts = g.LineTexts,
        };

        var report = MetricParityRunner.Compare(corpus, measured, golden);
        Assert.False(report.Passed);
        Assert.Contains(report.Failures, d => d.CaseId == victim.Id && d.Field == "height");
    }

    [Fact]
    public void Compare_flags_line_count_mismatch()
    {
        var corpus = MetricParityRunner.LoadCorpus();
        var golden = MetricParityRunner.LoadGolden();
        var measured = GoldenAsMeasured(golden);

        var victim = corpus.Cases.First(c => c.ResolvedMethod == ParityMethod.MeasureLineStats);
        var g = golden.Results[victim.Id];
        measured[victim.Id] = new MeasuredResult { LineCount = (g.LineCount ?? 0) + 3, MaxLineWidth = g.MaxLineWidth };

        var report = MetricParityRunner.Compare(corpus, measured, golden);
        Assert.False(report.Passed);
        Assert.Contains(report.Failures, d => d.CaseId == victim.Id && d.Field == "lineCount");
    }

    [Fact]
    public async Task MeasureAsync_drives_corpus_end_to_end_against_golden()
    {
        // A golden-replay host answers each measurement with the exact Mac golden for
        // that case, so running the whole corpus through the engine reproduces the
        // golden and Compare passes. This proves MeasureAsync's method dispatch +
        // result shaping + the engine/runner wiring end to end (the ONLY thing this
        // cannot prove is Chromium's real numbers — that is the Windows live run).
        var corpus = MetricParityRunner.LoadCorpus();
        var golden = MetricParityRunner.LoadGolden();

        var host = new GoldenReplayHost(corpus, golden);
        using var engine = new PretextEngine(host);

        var measured = await MetricParityRunner.MeasureAsync(engine, corpus);
        var report = MetricParityRunner.Compare(corpus, measured, golden);
        Assert.True(report.Passed, MetricParityRunner.FormatReport(report));
    }

    [Fact(Skip = "Live Chromium-vs-WebKit run needs a real offscreen WebView2 (Windows dev host / Windows CI). See docs/windows-port/design/0005-pretext-webview2-metric-parity.md (R22).")]
    public Task Live_webview2_matches_mac_golden_within_tolerance()
    {
        // On Windows: construct a PretextEngine over WebView2PretextHost, run
        // MetricParityRunner.MeasureAsync + Compare against golden.mac.json, and
        // assert report.Passed. Deferred here — no WebView2 on the macOS host.
        return Task.CompletedTask;
    }

    private static Dictionary<string, MeasuredResult> GoldenAsMeasured(PretextGolden golden)
    {
        var map = new Dictionary<string, MeasuredResult>();
        foreach (var kv in golden.Results)
        {
            var g = kv.Value;
            map[kv.Key] = new MeasuredResult
            {
                Height = g.Height,
                LineCount = g.LineCount,
                MaxLineWidth = g.MaxLineWidth,
                Width = g.Width,
                LineWidths = g.LineWidths,
                LineTexts = g.LineTexts,
            };
        }
        return map;
    }
}

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.Pretext.MetricParity;

// MARK: - Metric-parity runner
//
// Ties the corpus + golden together:
//   * LoadCorpus / LoadGolden read the committed embedded resources.
//   * MeasureAsync runs every corpus case through a PretextEngine (real WebView2 on
//     Windows, or any IPretextWebHost) and returns the measured geometry per case.
//   * Compare diffs measured vs golden field-by-field within tolerance and yields a
//     report Chat's parity gate consumes.
//
// The COMPARISON is pure and fully tested on macOS. The MEASUREMENT needs a live
// browser (Chromium metrics), so the end-to-end "Windows vs Mac golden" run is
// Windows/dev-host-deferred (see the design doc, R22).

/// Measured geometry for one case (peer of <see cref="GoldenResult"/>).
public sealed record MeasuredResult
{
    public double? Height { get; init; }
    public int? LineCount { get; init; }
    public double? MaxLineWidth { get; init; }
    public double? Width { get; init; }
    public IReadOnlyList<double>? LineWidths { get; init; }
    public IReadOnlyList<string>? LineTexts { get; init; }
}

/// One field-level parity discrepancy.
public sealed record ParityDiscrepancy(
    string CaseId,
    string Field,
    double Expected,
    double Actual,
    double Tolerance,
    bool WithinTolerance)
{
    public double Delta => Math.Abs(Expected - Actual);

    public override string ToString() =>
        $"{CaseId}.{Field}: expected {Expected.ToString("0.###", CultureInfo.InvariantCulture)}, " +
        $"actual {Actual.ToString("0.###", CultureInfo.InvariantCulture)}, " +
        $"delta {Delta.ToString("0.###", CultureInfo.InvariantCulture)} " +
        $"(tol {Tolerance.ToString("0.###", CultureInfo.InvariantCulture)}) " +
        $"=> {(WithinTolerance ? "OK" : "DRIFT")}";
}

/// The full parity outcome.
public sealed record ParityReport(
    bool Passed,
    IReadOnlyList<ParityDiscrepancy> Discrepancies,
    IReadOnlyList<string> MissingCases)
{
    /// Only the out-of-tolerance discrepancies.
    public IEnumerable<ParityDiscrepancy> Failures
    {
        get
        {
            foreach (var d in Discrepancies)
            {
                if (!d.WithinTolerance)
                {
                    yield return d;
                }
            }
        }
    }
}

/// Loads the corpus/golden and runs measurement + comparison.
public static class MetricParityRunner
{
    private const string CorpusResourceName = "pretext-corpus.json";
    private const string GoldenResourceName = "golden.mac.json";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
    };

    /// Load the committed corpus from the embedded resource.
    public static PretextCorpus LoadCorpus() =>
        Deserialize<PretextCorpus>(CorpusResourceName);

    /// Load the committed golden from the embedded resource.
    public static PretextGolden LoadGolden() =>
        Deserialize<PretextGolden>(GoldenResourceName);

    /// Measure every corpus case through <paramref name="engine"/>.
    public static async Task<IReadOnlyDictionary<string, MeasuredResult>> MeasureAsync(
        PretextEngine engine,
        PretextCorpus corpus,
        CancellationToken cancellationToken = default)
    {
        if (engine is null)
        {
            throw new ArgumentNullException(nameof(engine));
        }
        if (corpus is null)
        {
            throw new ArgumentNullException(nameof(corpus));
        }

        var measured = new Dictionary<string, MeasuredResult>(corpus.Cases.Count);
        foreach (var c in corpus.Cases)
        {
            measured[c.Id] = await MeasureCaseAsync(engine, c, cancellationToken).ConfigureAwait(false);
        }
        return measured;
    }

    private static async Task<MeasuredResult> MeasureCaseAsync(
        PretextEngine engine, PretextCorpusCase c, CancellationToken ct)
    {
        var options = c.Options?.ToPretextOptions() ?? PretextOptions.Normal;

        switch (c.ResolvedMethod)
        {
            case ParityMethod.Layout:
            {
                var h = await engine.PrepareAsync(c.Text ?? string.Empty, c.Font ?? string.Empty, options, ct).ConfigureAwait(false);
                var r = await engine.LayoutAsync(h, c.MaxWidth, c.LineHeight, ct).ConfigureAwait(false);
                return new MeasuredResult { Height = r.Height, LineCount = r.LineCount };
            }
            case ParityMethod.LayoutWithLines:
            {
                // `layoutWithLines` needs the segment-aware prepared text — matches
                // the macOS call site (HermesAtomComponents.swift: prepareWithSegments
                // feeds layoutWithLines, while plain prepare feeds layout).
                var h = await engine.PrepareWithSegmentsAsync(c.Text ?? string.Empty, c.Font ?? string.Empty, options, ct).ConfigureAwait(false);
                var r = await engine.LayoutWithLinesAsync(h, c.MaxWidth, c.LineHeight, ct).ConfigureAwait(false);
                var widths = new double[r.Lines.Count];
                var texts = new string[r.Lines.Count];
                for (var i = 0; i < r.Lines.Count; i++)
                {
                    widths[i] = r.Lines[i].Width;
                    texts[i] = r.Lines[i].Text;
                }
                return new MeasuredResult
                {
                    Height = r.Height,
                    LineCount = r.LineCount,
                    LineWidths = widths,
                    LineTexts = texts,
                };
            }
            case ParityMethod.MeasureLineStats:
            {
                var h = await engine.PrepareAsync(c.Text ?? string.Empty, c.Font ?? string.Empty, options, ct).ConfigureAwait(false);
                var s = await engine.MeasureLineStatsAsync(h, c.MaxWidth, ct).ConfigureAwait(false);
                return new MeasuredResult { LineCount = s.LineCount, MaxLineWidth = s.MaxLineWidth };
            }
            case ParityMethod.MeasureNaturalWidth:
            {
                var h = await engine.PrepareAsync(c.Text ?? string.Empty, c.Font ?? string.Empty, options, ct).ConfigureAwait(false);
                var w = await engine.MeasureNaturalWidthAsync(h, ct).ConfigureAwait(false);
                return new MeasuredResult { Width = w };
            }
            case ParityMethod.LayoutRichInline:
            {
                var items = new List<PretextRichInlineItem>();
                if (c.Items is not null)
                {
                    foreach (var item in c.Items)
                    {
                        items.Add(item.ToItem());
                    }
                }
                var h = await engine.PrepareRichInlineAsync(items, ct).ConfigureAwait(false);
                var lines = await engine.LayoutRichInlineAsync(h, c.MaxWidth, ct).ConfigureAwait(false);
                var widths = new double[lines.Count];
                for (var i = 0; i < lines.Count; i++)
                {
                    widths[i] = lines[i].Width;
                }
                return new MeasuredResult { LineCount = lines.Count, LineWidths = widths };
            }
            default:
                throw new InvalidOperationException($"Unknown parity method for case '{c.Id}'.");
        }
    }

    /// Diff measured vs golden, field-by-field, within each case's tolerance.
    public static ParityReport Compare(
        PretextCorpus corpus,
        IReadOnlyDictionary<string, MeasuredResult> measured,
        PretextGolden golden)
    {
        var discrepancies = new List<ParityDiscrepancy>();
        var missing = new List<string>();

        foreach (var c in corpus.Cases)
        {
            if (!golden.Results.TryGetValue(c.Id, out var gold) ||
                !measured.TryGetValue(c.Id, out var meas))
            {
                missing.Add(c.Id);
                continue;
            }

            var tol = c.Tolerance ?? corpus.DefaultTolerance;

            AddScalar(discrepancies, c.Id, "height", gold.Height, meas!.Height, tol.Height);
            AddScalar(discrepancies, c.Id, "maxLineWidth", gold.MaxLineWidth, meas.MaxLineWidth, tol.Width);
            AddScalar(discrepancies, c.Id, "width", gold.Width, meas.Width, tol.Width);
            AddScalarInt(discrepancies, c.Id, "lineCount", gold.LineCount, meas.LineCount, tol.LineCount);
            AddLineWidths(discrepancies, c.Id, gold.LineWidths, meas.LineWidths, tol.Width);
        }

        var passed = missing.Count == 0;
        foreach (var d in discrepancies)
        {
            if (!d.WithinTolerance)
            {
                passed = false;
                break;
            }
        }
        return new ParityReport(passed, discrepancies, missing);
    }

    private static void AddScalar(
        List<ParityDiscrepancy> into, string caseId, string field,
        double? expected, double? actual, double tolerance)
    {
        if (expected is null || actual is null)
        {
            return;
        }
        var within = Math.Abs(expected.Value - actual.Value) <= tolerance;
        into.Add(new ParityDiscrepancy(caseId, field, expected.Value, actual.Value, tolerance, within));
    }

    private static void AddScalarInt(
        List<ParityDiscrepancy> into, string caseId, string field,
        int? expected, int? actual, int tolerance)
    {
        if (expected is null || actual is null)
        {
            return;
        }
        var within = Math.Abs(expected.Value - actual.Value) <= tolerance;
        into.Add(new ParityDiscrepancy(caseId, field, expected.Value, actual.Value, tolerance, within));
    }

    private static void AddLineWidths(
        List<ParityDiscrepancy> into, string caseId,
        IReadOnlyList<double>? expected, IReadOnlyList<double>? actual, double tolerance)
    {
        if (expected is null || actual is null)
        {
            return;
        }
        var count = Math.Max(expected.Count, actual.Count);
        for (var i = 0; i < count; i++)
        {
            if (i >= expected.Count || i >= actual.Count)
            {
                // A line-count mismatch is already reported via lineCount; flag the
                // missing width as an explicit drift so it is never silently dropped.
                var present = i < expected.Count ? expected[i] : actual[i];
                into.Add(new ParityDiscrepancy(caseId, $"lineWidth[{i}]", present, double.NaN, tolerance, WithinTolerance: false));
                continue;
            }
            var within = Math.Abs(expected[i] - actual[i]) <= tolerance;
            into.Add(new ParityDiscrepancy(caseId, $"lineWidth[{i}]", expected[i], actual[i], tolerance, within));
        }
    }

    /// Render a human-readable report (used by the dev-host runner + CI logs).
    public static string FormatReport(ParityReport report)
    {
        var sb = new StringBuilder();
        sb.AppendLine(report.Passed ? "PARITY PASS" : "PARITY FAIL");
        if (report.MissingCases.Count > 0)
        {
            sb.AppendLine($"Missing cases (no golden or no measurement): {string.Join(", ", report.MissingCases)}");
        }
        foreach (var d in report.Discrepancies)
        {
            if (!d.WithinTolerance)
            {
                sb.AppendLine("  " + d);
            }
        }
        return sb.ToString();
    }

    private static T Deserialize<T>(string logicalName)
    {
        var assembly = typeof(MetricParityRunner).Assembly;
        using var stream = assembly.GetManifestResourceStream(logicalName)
            ?? throw new InvalidOperationException(
                $"Embedded parity resource '{logicalName}' not found. Available: {string.Join(", ", assembly.GetManifestResourceNames())}");
        using var reader = new StreamReader(stream);
        var json = reader.ReadToEnd();
        return JsonSerializer.Deserialize<T>(json, JsonOptions)
            ?? throw new InvalidOperationException($"Failed to deserialize parity resource '{logicalName}'.");
    }
}

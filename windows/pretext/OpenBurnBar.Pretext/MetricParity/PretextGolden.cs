using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace OpenBurnBar.Pretext.MetricParity;

// MARK: - Golden model
//
// `corpus/golden.mac.json` holds the macOS/WebKit measurement for each corpus case,
// keyed by case id. It is the parity reference the Windows/WebView2 run is compared
// against. Any field that a given case's method does not produce is left null.
//
// `CapturedOn` distinguishes a REAL Mac capture from a not-yet-captured scaffold:
//   * "macos-webkit"                 -> authoritative Mac golden (real numbers).
//   * "SCAFFOLD_PENDING_MAC_CAPTURE" -> placeholder; the live parity comparison must
//                                       be skipped/deferred until a real capture lands.
// The runner exposes <see cref="PretextGolden.IsScaffold"/> so callers/tests never
// mistake a placeholder for a real reference.

/// One case's golden geometry.
public sealed record GoldenResult
{
    [JsonPropertyName("height")] public double? Height { get; init; }
    [JsonPropertyName("lineCount")] public int? LineCount { get; init; }
    [JsonPropertyName("maxLineWidth")] public double? MaxLineWidth { get; init; }
    [JsonPropertyName("width")] public double? Width { get; init; }
    [JsonPropertyName("lineWidths")] public IReadOnlyList<double>? LineWidths { get; init; }
    [JsonPropertyName("lineTexts")] public IReadOnlyList<string>? LineTexts { get; init; }
}

/// The whole golden file.
public sealed record PretextGolden
{
    public const string ScaffoldMarker = "SCAFFOLD_PENDING_MAC_CAPTURE";

    [JsonPropertyName("schemaVersion")] public int SchemaVersion { get; init; } = 1;
    [JsonPropertyName("capturedOn")] public string CapturedOn { get; init; } = ScaffoldMarker;
    [JsonPropertyName("engine")] public string? Engine { get; init; }
    [JsonPropertyName("note")] public string? Note { get; init; }
    [JsonPropertyName("results")] public IReadOnlyDictionary<string, GoldenResult> Results { get; init; }
        = new Dictionary<string, GoldenResult>();

    /// True when the golden is a not-yet-captured placeholder — the live comparison
    /// must be deferred (not run as a hard gate) until a real Mac capture replaces it.
    [JsonIgnore]
    public bool IsScaffold => string.Equals(CapturedOn, ScaffoldMarker, System.StringComparison.Ordinal);
}

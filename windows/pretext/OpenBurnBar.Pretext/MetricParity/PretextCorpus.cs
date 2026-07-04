using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace OpenBurnBar.Pretext.MetricParity;

// MARK: - Metric-parity corpus model
//
// The committed corpus (`corpus/pretext-corpus.json`) is the fixed set of text /
// font / width cases the Chat layout depends on. It is measured on macOS/WebKit to
// produce the golden (`corpus/golden.mac.json`), then re-measured on Windows/WebView2
// and compared field-by-field within tolerance to gate risk R22.

/// One tolerance band (CSS pixels for geometry; exact integer for line counts).
public sealed record ParityTolerance
{
    [JsonPropertyName("height")] public double Height { get; init; } = 1.0;
    [JsonPropertyName("width")] public double Width { get; init; } = 1.0;
    [JsonPropertyName("lineCount")] public int LineCount { get; init; }
}

/// Corpus-level options (loose strings straight from JSON) mapped to the strongly
/// typed <see cref="PretextOptions"/>.
public sealed record CorpusOptions
{
    [JsonPropertyName("whiteSpace")] public string? WhiteSpace { get; init; }
    [JsonPropertyName("wordBreak")] public string? WordBreak { get; init; }
    [JsonPropertyName("letterSpacing")] public double? LetterSpacing { get; init; }

    public PretextOptions ToPretextOptions()
    {
        return new PretextOptions
        {
            WhiteSpace = WhiteSpace switch
            {
                "pre-wrap" => PretextOptions.WhiteSpaceMode.PreWrap,
                "normal" => PretextOptions.WhiteSpaceMode.Normal,
                _ => null,
            },
            WordBreak = WordBreak switch
            {
                "keep-all" => PretextOptions.WordBreakMode.KeepAll,
                "normal" => PretextOptions.WordBreakMode.Normal,
                _ => null,
            },
            LetterSpacing = LetterSpacing,
        };
    }
}

/// One rich-inline fragment in the corpus.
public sealed record CorpusRichItem
{
    [JsonPropertyName("text")] public string Text { get; init; } = string.Empty;
    [JsonPropertyName("font")] public string Font { get; init; } = string.Empty;
    [JsonPropertyName("breakNever")] public bool BreakNever { get; init; }
    [JsonPropertyName("extraWidth")] public double ExtraWidth { get; init; }

    public PretextRichInlineItem ToItem() => new()
    {
        Text = Text,
        Font = Font,
        BreakNever = BreakNever,
        ExtraWidth = ExtraWidth,
    };
}

/// The measurement a case exercises.
public enum ParityMethod
{
    Layout,
    LayoutWithLines,
    MeasureLineStats,
    MeasureNaturalWidth,
    LayoutRichInline,
}

/// One corpus case.
public sealed record PretextCorpusCase
{
    [JsonPropertyName("id")] public string Id { get; init; } = string.Empty;
    [JsonPropertyName("method")] public string Method { get; init; } = "layoutWithLines";
    [JsonPropertyName("text")] public string? Text { get; init; }
    [JsonPropertyName("font")] public string? Font { get; init; }
    [JsonPropertyName("maxWidth")] public double MaxWidth { get; init; }
    [JsonPropertyName("lineHeight")] public double LineHeight { get; init; }
    [JsonPropertyName("options")] public CorpusOptions? Options { get; init; }
    [JsonPropertyName("items")] public IReadOnlyList<CorpusRichItem>? Items { get; init; }
    [JsonPropertyName("tolerance")] public ParityTolerance? Tolerance { get; init; }

    public ParityMethod ResolvedMethod => Method switch
    {
        "layout" => ParityMethod.Layout,
        "layoutWithLines" => ParityMethod.LayoutWithLines,
        "measureLineStats" => ParityMethod.MeasureLineStats,
        "measureNaturalWidth" => ParityMethod.MeasureNaturalWidth,
        "layoutRichInline" => ParityMethod.LayoutRichInline,
        _ => ParityMethod.LayoutWithLines,
    };
}

/// The whole corpus.
public sealed record PretextCorpus
{
    [JsonPropertyName("schemaVersion")] public int SchemaVersion { get; init; } = 1;
    [JsonPropertyName("description")] public string? Description { get; init; }
    [JsonPropertyName("fontNote")] public string? FontNote { get; init; }
    [JsonPropertyName("defaultTolerance")] public ParityTolerance DefaultTolerance { get; init; } = new();
    [JsonPropertyName("cases")] public IReadOnlyList<PretextCorpusCase> Cases { get; init; } = new List<PretextCorpusCase>();
}

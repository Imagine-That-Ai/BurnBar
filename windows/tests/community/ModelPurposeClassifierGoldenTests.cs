using System.Text.Json;
using OpenBurnBar.App.Community;
using Xunit;

namespace OpenBurnBar.App.Community.Tests;

public sealed class ModelPurposeClassifierGoldenTests
{
    private static readonly string GoldensPath = Path.Combine(
        AppContext.BaseDirectory,
        "classifier-goldens.json");

    [Fact]
    public void ModelBiasTieOrder_MatchesO1BeforeDeepseek()
    {
        var result = ModelPurposeClassifier.ClassifyPurpose(
            new ClassifierSignals(Model: "o1-deepseek-hybrid"));
        Assert.Equal(ModelPurposeCategory.Research, result.Category);
        Assert.True(result.Confidence >= 0.2);
    }

    [Theory]
    [InlineData("ui-swift-file", "ui")]
    [InlineData("backend-go-sql", "backend")]
    [InlineData("no-signals-default", "other")]
    public void GoldenCategories_MatchCanonicalFixtures(string name, string expectedRaw)
    {
        var match = FindGolden(name);
        var signals = ParseSignals(match.GetProperty("signals"));
        var expected = ModelPurposeClassifier.ParseCategory(expectedRaw);
        var result = ModelPurposeClassifier.ClassifyPurpose(signals);
        Assert.Equal(expected, result.Category);
    }

    [Fact]
    public void AllClassifierGoldens_MatchSharedFixture()
    {
        foreach (var match in LoadGoldens())
        {
            var name = match.GetProperty("name").GetString()!;
            if (match.TryGetProperty("expectedFingerprint", out _))
            {
                continue;
            }
            var signals = ParseSignals(match.GetProperty("signals"));
            IReadOnlyList<PurposeCorrection>? corrections = null;
            if (match.TryGetProperty("corrections", out var correctionsEl) && correctionsEl.ValueKind == JsonValueKind.Array)
            {
                var list = new List<PurposeCorrection>();
                foreach (var row in correctionsEl.EnumerateArray())
                {
                    var fp = row.GetProperty("fingerprint").GetString()!;
                    var corrected = ModelPurposeClassifier.ParseCategory(row.GetProperty("correctedTo").GetString()!);
                    list.Add(new PurposeCorrection(fp, corrected));
                }
                corrections = list;
            }

            var result = ModelPurposeClassifier.ClassifyPurpose(signals, corrections);

            if (match.TryGetProperty("expected", out var expectedEl))
            {
                var expected = ModelPurposeClassifier.ParseCategory(expectedEl.GetString()!);
                Assert.Equal(expected, result.Category);
            }

            if (match.TryGetProperty("minConfidence", out var minEl))
            {
                Assert.True(result.Confidence >= minEl.GetDouble(), name);
            }

            if (match.TryGetProperty("expectedSignal", out var signalEl))
            {
                Assert.Contains(signalEl.GetString(), result.ContributingSignals);
            }
        }
    }

    [Fact]
    public void Fingerprint_Stability_MatchesFixture()
    {
        var cases = LoadGoldens();
        var match = cases.First(c => c.GetProperty("name").GetString() == "fingerprint-stability");
        var signals = ParseSignals(match.GetProperty("signals"));
        var expected = match.GetProperty("expectedFingerprint").GetString();
        Assert.Equal(expected, ModelPurposeClassifier.SignalFingerprint(signals));
    }

    private static JsonElement FindGolden(string name)
    {
        foreach (var c in LoadGoldens())
        {
            if (c.GetProperty("name").GetString() == name)
                return c;
        }

        throw new InvalidOperationException($"Golden not found: {name}");
    }

    private static JsonElement[] LoadGoldens()
    {
        var json = File.ReadAllText(GoldensPath);
        return JsonSerializer.Deserialize<JsonElement[]>(json) ?? Array.Empty<JsonElement>();
    }

    private static ClassifierSignals ParseSignals(JsonElement el)
    {
        IReadOnlyList<string>? exts = null;
        if (el.TryGetProperty("fileExtensions", out var extArr) && extArr.ValueKind == JsonValueKind.Array)
        {
            exts = extArr.EnumerateArray().Select(e => e.GetString()!).ToArray();
        }

        IReadOnlyList<string>? keywords = null;
        if (el.TryGetProperty("keywords", out var kwArr) && kwArr.ValueKind == JsonValueKind.Array)
        {
            keywords = kwArr.EnumerateArray().Select(e => e.GetString()!).ToArray();
        }

        string? model = el.TryGetProperty("model", out var m) ? m.GetString() : null;
        string? surface = el.TryGetProperty("appSurface", out var s) ? s.GetString() : null;
        bool hasErr = el.TryGetProperty("hasErrorOutput", out var he) && he.GetBoolean();
        bool hasExec = el.TryGetProperty("hasCodeExecution", out var hc) && hc.GetBoolean();
        bool hasSearch = el.TryGetProperty("hasSearchResults", out var hs) && hs.GetBoolean();
        bool hasPlan = el.TryGetProperty("hasMultiStepPlanning", out var hp) && hp.GetBoolean();

        return new ClassifierSignals(exts, model, surface, hasExec, hasErr, hasSearch, hasPlan, keywords);
    }
}
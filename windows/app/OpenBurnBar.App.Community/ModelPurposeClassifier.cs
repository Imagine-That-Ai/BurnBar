namespace OpenBurnBar.App.Community;

public enum ModelPurposeCategory
{
    Ui,
    Backend,
    Logic,
    Writing,
    Research,
    Debugging,
    Orchestration,
    Other,
}

public sealed record ClassifierSignals(
    IReadOnlyList<string>? FileExtensions = null,
    string? Model = null,
    string? AppSurface = null,
    bool HasCodeExecution = false,
    bool HasErrorOutput = false,
    bool HasSearchResults = false,
    bool HasMultiStepPlanning = false,
    IReadOnlyList<string>? Keywords = null);

public sealed record PurposeCorrection(string Fingerprint, ModelPurposeCategory CorrectedTo);

public sealed record ClassificationResult(
    ModelPurposeCategory Category,
    double Confidence,
    IReadOnlyList<string> ContributingSignals);

public static class ModelPurposeClassifier
{
    private static readonly ModelPurposeCategory[] PurposeCategories =
    {
        ModelPurposeCategory.Ui,
        ModelPurposeCategory.Backend,
        ModelPurposeCategory.Logic,
        ModelPurposeCategory.Writing,
        ModelPurposeCategory.Research,
        ModelPurposeCategory.Debugging,
        ModelPurposeCategory.Orchestration,
        ModelPurposeCategory.Other,
    };

    private static readonly Dictionary<string, ModelPurposeCategory> FileExtensionMap =
        new(StringComparer.OrdinalIgnoreCase)
        {
            ["swift"] = ModelPurposeCategory.Ui,
            ["xaml"] = ModelPurposeCategory.Ui,
            ["css"] = ModelPurposeCategory.Ui,
            ["scss"] = ModelPurposeCategory.Ui,
            ["html"] = ModelPurposeCategory.Ui,
            ["vue"] = ModelPurposeCategory.Ui,
            ["svelte"] = ModelPurposeCategory.Ui,
            ["go"] = ModelPurposeCategory.Backend,
            ["rs"] = ModelPurposeCategory.Backend,
            ["py"] = ModelPurposeCategory.Backend,
            ["java"] = ModelPurposeCategory.Backend,
            ["kt"] = ModelPurposeCategory.Backend,
            ["sql"] = ModelPurposeCategory.Backend,
            ["proto"] = ModelPurposeCategory.Backend,
            ["grpc"] = ModelPurposeCategory.Backend,
            ["ts"] = ModelPurposeCategory.Logic,
            ["tsx"] = ModelPurposeCategory.Logic,
            ["js"] = ModelPurposeCategory.Logic,
            ["mjs"] = ModelPurposeCategory.Logic,
            ["cjs"] = ModelPurposeCategory.Logic,
            ["dart"] = ModelPurposeCategory.Logic,
            ["md"] = ModelPurposeCategory.Writing,
            ["txt"] = ModelPurposeCategory.Writing,
            ["rst"] = ModelPurposeCategory.Writing,
            ["docx"] = ModelPurposeCategory.Writing,
            ["pdf"] = ModelPurposeCategory.Writing,
            ["json"] = ModelPurposeCategory.Research,
            ["yaml"] = ModelPurposeCategory.Research,
            ["yml"] = ModelPurposeCategory.Research,
            ["csv"] = ModelPurposeCategory.Research,
            ["toml"] = ModelPurposeCategory.Research,
        };

    private static readonly Dictionary<string, ModelPurposeCategory> KeywordMap =
        new(StringComparer.OrdinalIgnoreCase)
        {
            ["ui"] = ModelPurposeCategory.Ui,
            ["design"] = ModelPurposeCategory.Ui,
            ["frontend"] = ModelPurposeCategory.Ui,
            ["layout"] = ModelPurposeCategory.Ui,
            ["view"] = ModelPurposeCategory.Ui,
            ["button"] = ModelPurposeCategory.Ui,
            ["animation"] = ModelPurposeCategory.Ui,
            ["theme"] = ModelPurposeCategory.Ui,
            ["color"] = ModelPurposeCategory.Ui,
            ["responsive"] = ModelPurposeCategory.Ui,
            ["accessibility"] = ModelPurposeCategory.Ui,
            ["api"] = ModelPurposeCategory.Backend,
            ["server"] = ModelPurposeCategory.Backend,
            ["database"] = ModelPurposeCategory.Backend,
            ["migration"] = ModelPurposeCategory.Backend,
            ["endpoint"] = ModelPurposeCategory.Backend,
            ["auth"] = ModelPurposeCategory.Backend,
            ["deploy"] = ModelPurposeCategory.Backend,
            ["docker"] = ModelPurposeCategory.Backend,
            ["kubernetes"] = ModelPurposeCategory.Backend,
            ["grpc"] = ModelPurposeCategory.Backend,
            ["refactor"] = ModelPurposeCategory.Logic,
            ["algorithm"] = ModelPurposeCategory.Logic,
            ["function"] = ModelPurposeCategory.Logic,
            ["type"] = ModelPurposeCategory.Logic,
            ["interface"] = ModelPurposeCategory.Logic,
            ["state"] = ModelPurposeCategory.Logic,
            ["model"] = ModelPurposeCategory.Logic,
            ["parse"] = ModelPurposeCategory.Logic,
            ["docs"] = ModelPurposeCategory.Writing,
            ["documentation"] = ModelPurposeCategory.Writing,
            ["readme"] = ModelPurposeCategory.Writing,
            ["blog"] = ModelPurposeCategory.Writing,
            ["article"] = ModelPurposeCategory.Writing,
            ["essay"] = ModelPurposeCategory.Writing,
            ["summary"] = ModelPurposeCategory.Writing,
            ["research"] = ModelPurposeCategory.Research,
            ["search"] = ModelPurposeCategory.Research,
            ["analyze"] = ModelPurposeCategory.Research,
            ["data"] = ModelPurposeCategory.Research,
            ["benchmark"] = ModelPurposeCategory.Research,
            ["evaluate"] = ModelPurposeCategory.Research,
            ["bug"] = ModelPurposeCategory.Debugging,
            ["error"] = ModelPurposeCategory.Debugging,
            ["fix"] = ModelPurposeCategory.Debugging,
            ["crash"] = ModelPurposeCategory.Debugging,
            ["stacktrace"] = ModelPurposeCategory.Debugging,
            ["debug"] = ModelPurposeCategory.Debugging,
            ["test"] = ModelPurposeCategory.Debugging,
            ["fail"] = ModelPurposeCategory.Debugging,
            ["plan"] = ModelPurposeCategory.Orchestration,
            ["workflow"] = ModelPurposeCategory.Orchestration,
            ["pipeline"] = ModelPurposeCategory.Orchestration,
            ["agent"] = ModelPurposeCategory.Orchestration,
            ["automate"] = ModelPurposeCategory.Orchestration,
            ["schedule"] = ModelPurposeCategory.Orchestration,
            ["mission"] = ModelPurposeCategory.Orchestration,
        };

    private static readonly (string Key, Dictionary<ModelPurposeCategory, double> Bias)[] ModelBias =
    {
        ("o1", new() { [ModelPurposeCategory.Research] = 0.3, [ModelPurposeCategory.Logic] = 0.2 }),
        ("o3", new() { [ModelPurposeCategory.Research] = 0.3, [ModelPurposeCategory.Logic] = 0.2 }),
        ("deepseek", new() { [ModelPurposeCategory.Logic] = 0.3, [ModelPurposeCategory.Backend] = 0.2 }),
        ("claude-3.5-sonnet", new() { [ModelPurposeCategory.Writing] = 0.15, [ModelPurposeCategory.Logic] = 0.15 }),
        ("gpt-4o", new() { [ModelPurposeCategory.Ui] = 0.1, [ModelPurposeCategory.Writing] = 0.1 }),
        ("llama", new() { [ModelPurposeCategory.Backend] = 0.15 }),
    };

    private static readonly Dictionary<string, Dictionary<ModelPurposeCategory, double>> SurfaceBias =
        new(StringComparer.OrdinalIgnoreCase)
        {
            ["chat"] = new(),
            ["dashboard"] = new() { [ModelPurposeCategory.Orchestration] = 0.1 },
            ["editor"] = new() { [ModelPurposeCategory.Logic] = 0.1 },
            ["terminal"] = new() { [ModelPurposeCategory.Debugging] = 0.15, [ModelPurposeCategory.Backend] = 0.1 },
        };

    public static string SignalFingerprint(ClassifierSignals signals)
    {
        var parts = new List<string>();
        if (signals.FileExtensions is { Count: > 0 })
        {
            var sorted = signals.FileExtensions.OrderBy(e => e, StringComparer.Ordinal).ToArray();
            parts.Add($"ext:{string.Join(",", sorted)}");
        }

        if (!string.IsNullOrWhiteSpace(signals.AppSurface))
        {
            parts.Add($"surf:{signals.AppSurface}");
        }

        if (signals.HasCodeExecution) parts.Add("exec");
        if (signals.HasErrorOutput) parts.Add("err");
        if (signals.HasSearchResults) parts.Add("search");
        if (signals.HasMultiStepPlanning) parts.Add("plan");
        return parts.Count == 0 ? "default" : string.Join("|", parts);
    }

    public static ClassificationResult ClassifyPurpose(
        ClassifierSignals signals,
        IReadOnlyList<PurposeCorrection>? corrections = null)
    {
        var fp = SignalFingerprint(signals);
        var matched = corrections?.FirstOrDefault(c => c.Fingerprint == fp);
        if (matched is not null)
        {
            return new ClassificationResult(matched.CorrectedTo, 1.0, new[] { "user_correction" });
        }

        var scores = PurposeCategories.ToDictionary(c => c, _ => 0.0);
        var contributing = new List<string>();

        if (signals.FileExtensions is not null)
        {
            foreach (var ext in signals.FileExtensions)
            {
                if (FileExtensionMap.TryGetValue(ext, out var cat))
                {
                    scores[cat] += 1.0;
                    contributing.Add($"file:{ext}");
                }
            }
        }

        if (signals.Keywords is not null)
        {
            foreach (var kw in signals.Keywords)
            {
                if (KeywordMap.TryGetValue(kw, out var cat))
                {
                    scores[cat] += 0.5;
                    contributing.Add($"keyword:{kw}");
                }
            }
        }

        if (signals.HasErrorOutput)
        {
            scores[ModelPurposeCategory.Debugging] += 1.5;
            contributing.Add("error_output");
        }

        if (signals.HasCodeExecution)
        {
            scores[ModelPurposeCategory.Backend] += 0.5;
            scores[ModelPurposeCategory.Logic] += 0.5;
            contributing.Add("code_execution");
        }

        if (signals.HasSearchResults)
        {
            scores[ModelPurposeCategory.Research] += 1.0;
            contributing.Add("search_results");
        }

        if (signals.HasMultiStepPlanning)
        {
            scores[ModelPurposeCategory.Orchestration] += 1.0;
            contributing.Add("multi_step_planning");
        }

        if (!string.IsNullOrWhiteSpace(signals.Model))
        {
            var modelLower = signals.Model.ToLowerInvariant();
            foreach (var (key, bias) in ModelBias)
            {
                if (!modelLower.Contains(key, StringComparison.Ordinal))
                {
                    continue;
                }

                foreach (var (cat, weight) in bias)
                {
                    scores[cat] += weight;
                }

                contributing.Add($"model:{key}");
                break;
            }
        }

        if (!string.IsNullOrWhiteSpace(signals.AppSurface)
            && SurfaceBias.TryGetValue(signals.AppSurface, out var surfaceBias))
        {
            foreach (var (cat, weight) in surfaceBias)
            {
                scores[cat] += weight;
            }

            contributing.Add($"surface:{signals.AppSurface}");
        }

        var winner = ModelPurposeCategory.Other;
        var maxScore = 0.0;
        var totalScore = 0.0;

        foreach (var cat in PurposeCategories)
        {
            totalScore += scores[cat];
            if (scores[cat] > maxScore)
            {
                maxScore = scores[cat];
                winner = cat;
            }
        }

        if (totalScore <= 0)
        {
            return new ClassificationResult(ModelPurposeCategory.Other, 0, Array.Empty<string>());
        }

        var confidence = Math.Round(maxScore / totalScore, 2, MidpointRounding.AwayFromZero);
        return new ClassificationResult(winner, confidence, contributing);
    }

    public static string CategoryRaw(ModelPurposeCategory category) => category switch
    {
        ModelPurposeCategory.Ui => "ui",
        ModelPurposeCategory.Backend => "backend",
        ModelPurposeCategory.Logic => "logic",
        ModelPurposeCategory.Writing => "writing",
        ModelPurposeCategory.Research => "research",
        ModelPurposeCategory.Debugging => "debugging",
        ModelPurposeCategory.Orchestration => "orchestration",
        _ => "other",
    };

    public static ModelPurposeCategory ParseCategory(string? raw) => raw?.ToLowerInvariant() switch
    {
        "ui" => ModelPurposeCategory.Ui,
        "backend" => ModelPurposeCategory.Backend,
        "logic" => ModelPurposeCategory.Logic,
        "writing" => ModelPurposeCategory.Writing,
        "research" => ModelPurposeCategory.Research,
        "debugging" => ModelPurposeCategory.Debugging,
        "orchestration" => ModelPurposeCategory.Orchestration,
        _ => ModelPurposeCategory.Other,
    };
}
using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace OpenBurnBar.EngineBinding.Tests.Support;

/// <summary>Portable parser-output contract row (see docs/windows-port/PARSER_OUTPUT_CONTRACT.md).</summary>
public sealed class ParserContractUsage
{
    [JsonPropertyName("provider")]
    public string Provider { get; init; } = "";

    [JsonPropertyName("sessionId")]
    public string SessionId { get; init; } = "";

    [JsonPropertyName("projectName")]
    public string ProjectName { get; init; } = "";

    [JsonPropertyName("model")]
    public string Model { get; init; } = "";

    [JsonPropertyName("inputTokens")]
    public long InputTokens { get; init; }

    [JsonPropertyName("outputTokens")]
    public long OutputTokens { get; init; }

    [JsonPropertyName("cacheCreationTokens")]
    public long CacheCreationTokens { get; init; }

    [JsonPropertyName("cacheReadTokens")]
    public long CacheReadTokens { get; init; }

    [JsonPropertyName("reasoningTokens")]
    public long ReasoningTokens { get; init; }

    [JsonPropertyName("totalTokens")]
    public long TotalTokens { get; init; }

    [JsonPropertyName("costNanoUSD")]
    public long CostNanoUSD { get; init; }

    [JsonPropertyName("usageSource")]
    public string UsageSource { get; init; } = "";

    [JsonPropertyName("provenanceMethod")]
    public string ProvenanceMethod { get; init; } = "";

    [JsonPropertyName("provenanceConfidence")]
    public string ProvenanceConfidence { get; init; } = "";

    [JsonPropertyName("estimatorVersion")]
    public string EstimatorVersion { get; init; } = "";

    public double CostUsd => CostNanoUSD / 1_000_000_000.0;
}

internal sealed class ParserGoldenRoot
{
    [JsonPropertyName("fixtures")]
    public ParserGoldenFixture[] Fixtures { get; init; } = [];
}

internal sealed class ParserGoldenFixture
{
    [JsonPropertyName("fixtureId")]
    public string FixtureId { get; init; } = "";

    [JsonPropertyName("usages")]
    public ParserContractUsage[] Usages { get; init; } = [];
}

public static class ParserContractGolden
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = false,
    };

    public static ParserContractUsage LoadClaudeCodeSessionUsage()
    {
        string path = Path.Combine(AppContext.BaseDirectory, "Fixtures", "parser-output-golden.json");
        string json = File.ReadAllText(path);
        ParserGoldenRoot? root = JsonSerializer.Deserialize<ParserGoldenRoot>(json, JsonOptions)
            ?? throw new InvalidOperationException("Failed to deserialize parser-output-golden.json");

        ParserGoldenFixture? fixture = root.Fixtures.FirstOrDefault(f => f.FixtureId == "claudeCodeSession")
            ?? throw new InvalidOperationException("claudeCodeSession missing from golden.");

        if (fixture.Usages.Length != 1)
        {
            throw new InvalidOperationException(
                $"claudeCodeSession expected 1 usage row, got {fixture.Usages.Length}.");
        }

        return fixture.Usages[0];
    }
}
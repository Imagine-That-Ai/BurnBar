using System;
using System.IO;
using System.Text.Json;
using OpenBurnBar.EngineBinding.Tests.Support;
using Xunit;
using Xunit.Abstractions;

namespace OpenBurnBar.EngineBinding.Tests;

/// <summary>In-process Swift Engine parse via C-ABI (replaces subprocess G2 for binding proof).</summary>
public sealed class EngineInProcessParseTests
{
    private readonly ITestOutputHelper _output;

    public EngineInProcessParseTests(ITestOutputHelper output) => _output = output;

    [Fact]
    public void ParseCliStdout_ClaudeBasicSession_MatchesGoldenContract()
    {
        string? lib = OpenBurnBarEngineNative.TryResolveLibraryPath();
        if (lib is null)
        {
            _output.WriteLine(
                "SKIP: OpenBurnBarCoreCAbi native library not built. Run: " +
                "swift build --package-path OpenBurnBarCore --product OpenBurnBarCoreCAbi");
            return;
        }

        _output.WriteLine($"Loaded: {lib}");

        string stdout = File.ReadAllText(
            Path.Combine(AppContext.BaseDirectory, "Fixtures", "pc-claude-basic-session.jsonl"));

        string? json = OpenBurnBarEngineNative.TryParseCliStdout(stdout, "Claude Code");
        Assert.NotNull(json);

        using JsonDocument doc = JsonDocument.Parse(json!);
        JsonElement root = doc.RootElement;
        Assert.True(root.GetProperty("ok").GetBoolean(), root.TryGetProperty("error", out JsonElement err)
            ? err.GetString()
            : json);

        ParserContractUsage expected = ParserContractGolden.LoadClaudeCodeSessionUsage();
        JsonElement usage = root.GetProperty("usages")[0];

        Assert.Equal(expected.Provider, usage.GetProperty("provider").GetString());
        Assert.Equal(expected.SessionId, usage.GetProperty("sessionId").GetString());
        Assert.Equal(expected.ProjectName, usage.GetProperty("projectName").GetString());
        Assert.Equal(expected.Model, usage.GetProperty("model").GetString());
        Assert.Equal(expected.InputTokens, usage.GetProperty("inputTokens").GetInt64());
        Assert.Equal(expected.OutputTokens, usage.GetProperty("outputTokens").GetInt64());
        Assert.Equal(expected.CacheCreationTokens, usage.GetProperty("cacheCreationTokens").GetInt64());
        Assert.Equal(expected.CacheReadTokens, usage.GetProperty("cacheReadTokens").GetInt64());
        Assert.Equal(expected.ReasoningTokens, usage.GetProperty("reasoningTokens").GetInt64());
        Assert.Equal(expected.TotalTokens, usage.GetProperty("totalTokens").GetInt64());
        Assert.Equal(expected.CostNanoUSD, usage.GetProperty("costNanoUSD").GetInt64());
        Assert.Equal(expected.UsageSource, usage.GetProperty("usageSource").GetString());
        Assert.Equal(expected.ProvenanceMethod, usage.GetProperty("provenanceMethod").GetString());
        Assert.Equal(expected.ProvenanceConfidence, usage.GetProperty("provenanceConfidence").GetString());
        Assert.Equal(expected.EstimatorVersion, usage.GetProperty("estimatorVersion").GetString());
    }
}
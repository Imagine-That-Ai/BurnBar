using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using OpenBurnBar.EngineBinding.Tests.Support;
using Xunit;
using Xunit.Abstractions;

namespace OpenBurnBar.EngineBinding.Tests;

/// <summary>
/// In-process Swift Engine insights via C-ABI (obb_build_insight_digest + obb_build_local_canvas).
/// Proves the rule-based, no-LLM insights path works in-process — the same path
/// the macOS "Local rules · free, on-device" option uses. This replaces InsightSampleData
/// for the complex widgets (narratives, recommendations, rankings).
/// </summary>
public sealed class EngineInProcessInsightsTests
{
    private readonly ITestOutputHelper _output;

    public EngineInProcessInsightsTests(ITestOutputHelper output) => _output = output;

    [Fact]
    public void BuildInsightDigest_FromUsageJson_ReturnsValidDigest()
    {
        string? lib = OpenBurnBarEngineNative.TryResolveLibraryPath();
        if (lib is null)
        {
            _output.WriteLine("SKIP: OpenBurnBarCoreCAbi native library not built.");
            return;
        }

        _output.WriteLine($"Loaded: {lib}");

        // Simulate TokenUsage JSON (the shape obb_parse_cli_stdout returns).
        string usageJson = """[{"provider":"Claude Code","sessionId":"s1","projectName":"test","model":"claude-3","inputTokens":1000,"outputTokens":500,"totalTokens":1500,"costUSD":0.45},{"provider":"Codex","sessionId":"s2","projectName":"test","model":"gpt-4","inputTokens":2000,"outputTokens":800,"totalTokens":2800,"costUSD":0.89}]""";

        string? digestResult = OpenBurnBarEngineNative.CallExport(lib, "obb_build_insight_digest", usageJson, 7);
        Assert.NotNull(digestResult);

        using JsonDocument doc = JsonDocument.Parse(digestResult!);
        JsonElement root = doc.RootElement;
        Assert.True(root.GetProperty("ok").GetBoolean(), digestResult);

        string digestJson = root.GetProperty("digestJson").GetString()!;
        using JsonDocument digestDoc = JsonDocument.Parse(digestJson);
        Assert.True(digestDoc.RootElement.GetProperty("totalCost").GetDouble() > 0, "digest should have totalCost > 0");
        Assert.True(digestDoc.RootElement.GetProperty("totalSessions").GetInt32() == 2, "digest should have 2 sessions");
        _output.WriteLine($"Digest: {digestJson}");
    }

    [Fact]
    public void BuildLocalCanvas_FromDigest_ReturnsRealWidgets()
    {
        string? lib = OpenBurnBarEngineNative.TryResolveLibraryPath();
        if (lib is null)
        {
            _output.WriteLine("SKIP: OpenBurnBarCoreCAbi native library not built.");
            return;
        }

        _output.WriteLine($"Loaded: {lib}");

        // Build a digest first.
        string usageJson = """[{"provider":"Claude Code","sessionId":"s1","projectName":"test","model":"claude-3","inputTokens":1000,"outputTokens":500,"totalTokens":1500,"costUSD":0.45}]""";
        string? digestResult = OpenBurnBarEngineNative.CallExport(lib, "obb_build_insight_digest", usageJson, 7);
        Assert.NotNull(digestResult);

        using JsonDocument digestResponse = JsonDocument.Parse(digestResult!);
        string digestJson = digestResponse.RootElement.GetProperty("digestJson").GetString()!;

        // Build the canvas from the digest.
        string? canvasResult = OpenBurnBarEngineNative.CallExportTwoArgs(lib, "obb_build_local_canvas", digestJson, "Show me my insights");
        Assert.NotNull(canvasResult);

        using JsonDocument canvasResponse = JsonDocument.Parse(canvasResult!);
        JsonElement canvasRoot = canvasResponse.RootElement;
        Assert.True(canvasRoot.GetProperty("ok").GetBoolean(), canvasResult);

        string canvasJson = canvasRoot.GetProperty("canvasJson").GetString()!;
        using JsonDocument canvasDoc = JsonDocument.Parse(canvasJson);

        // Verify the canvas has real widgets (not sample data).
        JsonElement widgets = canvasDoc.RootElement.GetProperty("widgets");
        Assert.True(widgets.GetArrayLength() >= 3, "canvas should have at least 3 widgets");

        // Check for KPI tiles + narrative + recommendation.
        bool hasKpi = false, hasNarrative = false, hasRecommendation = false;
        foreach (JsonElement widget in widgets.EnumerateArray())
        {
            string kind = widget.GetProperty("kind").GetString()!;
            if (kind == "kpiTile") hasKpi = true;
            if (kind == "narrative") hasNarrative = true;
            if (kind == "recommendation") hasRecommendation = true;
        }
        Assert.True(hasKpi, "canvas should have a KPI tile");
        Assert.True(hasNarrative, "canvas should have a narrative (deterministic, no LLM)");
        Assert.True(hasRecommendation, "canvas should have a recommendation (deterministic, no LLM)");

        _output.WriteLine($"Canvas: {canvasJson}");
    }
}

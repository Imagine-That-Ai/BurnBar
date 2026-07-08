using System.Text.Json;
using OpenBurnBar.App.CursorConnector;
using Xunit;

namespace OpenBurnBar.App.CursorConnector.Tests;

/// <summary>VAL-TOKEN token-bucket reconciliation parity.</summary>
public sealed class UsageEventNormalizerTests
{
    private static NormalizedUsageEvent Normalize(string json)
    {
        using var document = JsonDocument.Parse(json);
        return UsageEventNormalizer.Normalize(document.RootElement);
    }

    [Fact]
    public void ExplicitPrimaryBuckets_ArePreserved()
    {
        var result = Normalize("{\"prompt_tokens\":100,\"completion_tokens\":50}");

        Assert.Equal(100, result.PromptTokens);
        Assert.Equal(50, result.CompletionTokens);
        Assert.Equal(150, result.TotalTokens);
        Assert.True(result.HasExplicitPrimaryBucket);
        Assert.False(result.HasNoExplicitBuckets);
    }

    [Fact]
    public void TotalOnly_SplitsWithDefaultRatio()
    {
        var result = Normalize("{\"total_tokens\":1000}");

        // Default 0.62 input ratio when no char hints are present.
        Assert.Equal(620, result.PromptTokens);
        Assert.Equal(380, result.CompletionTokens);
        Assert.Equal(1000, result.TotalTokens);
    }

    [Fact]
    public void InclusiveCachedTokens_AreSubtractedFromPrompt()
    {
        var result = Normalize(
            "{\"prompt_tokens\":100,\"completion_tokens\":40,\"total_tokens\":200," +
            "\"prompt_tokens_details\":{\"cached_tokens\":30}}");

        Assert.Equal(70, result.PromptTokens);
        Assert.Equal(100, result.CompletionTokens);
        Assert.Equal(30, result.CacheReadTokens);
        Assert.Equal(200, result.TotalTokens);
    }

    [Fact]
    public void ReasoningTokens_StayADistinctBucket()
    {
        var result = Normalize(
            "{\"prompt_tokens\":50,\"completion_tokens\":30,\"reasoning_tokens\":20,\"total_tokens\":100}");

        Assert.Equal(50, result.PromptTokens);
        Assert.Equal(30, result.CompletionTokens);
        Assert.Equal(20, result.ReasoningTokens);
        Assert.Equal(100, result.TotalTokens);
    }

    [Fact]
    public void CharEstimateFallback_OnlyWhenNoTokenData()
    {
        var result = Normalize("{\"input_char_estimate\":335,\"output_char_estimate\":670}");

        Assert.Equal(100, result.PromptTokens);
        Assert.Equal(200, result.CompletionTokens);
        Assert.Equal(300, result.TotalTokens);
    }

    [Fact]
    public void StringNumbers_AreParsed()
    {
        var result = Normalize("{\"prompt_tokens\":\"100\",\"completion_tokens\":\"50.0\"}");

        Assert.Equal(100, result.PromptTokens);
        Assert.Equal(50, result.CompletionTokens);
        Assert.Equal(150, result.TotalTokens);
    }

    [Fact]
    public void CamelCaseSpellings_AreRecognized()
    {
        var result = Normalize("{\"promptTokens\":10,\"completionTokens\":20,\"totalTokens\":30}");

        Assert.Equal(10, result.PromptTokens);
        Assert.Equal(20, result.CompletionTokens);
        Assert.Equal(30, result.TotalTokens);
    }

    [Fact]
    public void EmptyRecord_HasNoExplicitBuckets()
    {
        var result = Normalize("{}");

        Assert.True(result.HasNoExplicitBuckets);
        Assert.Equal(0, result.TotalTokens);
    }

    [Fact]
    public void ExclusiveCacheRead_TakesPrecedenceOverInclusive()
    {
        var result = Normalize(
            "{\"prompt_tokens\":80,\"completion_tokens\":20,\"cache_read_tokens\":15," +
            "\"prompt_tokens_details\":{\"cached_tokens\":40},\"total_tokens\":140}");

        // Exclusive present → prompt is NOT reduced by the inclusive value.
        Assert.Equal(80, result.PromptTokens);
        Assert.Equal(15, result.CacheReadTokens);
    }
}

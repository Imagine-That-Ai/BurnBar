using System.Linq;
using OpenBurnBar.App.MemorySearch.Memory;
using Xunit;

namespace OpenBurnBar.App.MemorySearch.Tests;

/// <summary>
/// Strict-JSON extraction parser parity. Swift: <c>MemoryExtractionParser</c>. Clean-JSON-first
/// then brace-slice fallback; field-level leniency; kind fallback; confidence clamp; per-job cap.
/// </summary>
public sealed class MemoryExtractionParserTests
{
    [Fact]
    public void Parse_CleanJson_ExtractsCandidates()
    {
        const string json = "{\"memories\":[{\"text\":\"User prefers vim\",\"kind\":\"preference\",\"confidence\":0.8,\"messageId\":\"m1\"}]}";
        var results = MemoryExtractionParser.Parse(json, 12);
        var only = Assert.Single(results);
        Assert.Equal("User prefers vim", only.Text);
        Assert.Equal(MemoryKind.Preference, only.Kind);
        Assert.Equal(0.8, only.Confidence, 12);
        Assert.Equal("m1", only.ClaimedMessageId);
    }

    [Fact]
    public void Parse_ProseWrappedJson_UsesBraceSliceFallback()
    {
        const string reply = "Here you go:\n{\"memories\":[{\"text\":\"Lives in Berlin\",\"kind\":\"fact\"}]}\nHope that helps!";
        var results = MemoryExtractionParser.Parse(reply, 12);
        Assert.Single(results);
        Assert.Equal("Lives in Berlin", results[0].Text);
    }

    [Fact]
    public void Parse_UnknownKind_FallsBackToFact()
    {
        var results = MemoryExtractionParser.Parse("{\"memories\":[{\"text\":\"x\",\"kind\":\"whatever\"}]}", 12);
        Assert.Equal(MemoryKind.Fact, results[0].Kind);
    }

    [Fact]
    public void Parse_MissingOrNonNumericConfidence_DefaultsToHalf()
    {
        var noConfidence = MemoryExtractionParser.Parse("{\"memories\":[{\"text\":\"x\"}]}", 12);
        Assert.Equal(0.5, noConfidence[0].Confidence, 12);

        var stringConfidence = MemoryExtractionParser.Parse("{\"memories\":[{\"text\":\"x\",\"confidence\":\"high\"}]}", 12);
        Assert.Equal(0.5, stringConfidence[0].Confidence, 12);
    }

    [Fact]
    public void Parse_ConfidenceClampedToUnitRange()
    {
        Assert.Equal(1.0, MemoryExtractionParser.Parse("{\"memories\":[{\"text\":\"x\",\"confidence\":9.0}]}", 12)[0].Confidence, 12);
        Assert.Equal(0.0, MemoryExtractionParser.Parse("{\"memories\":[{\"text\":\"x\",\"confidence\":-2.0}]}", 12)[0].Confidence, 12);
    }

    [Fact]
    public void Parse_BlankOrMissingText_IsDropped()
    {
        var results = MemoryExtractionParser.Parse("{\"memories\":[{\"text\":\"   \"},{\"kind\":\"fact\"},{\"text\":\"keep\"}]}", 12);
        Assert.Single(results);
        Assert.Equal("keep", results[0].Text);
    }

    [Fact]
    public void Parse_NonObjectArrayElement_IsDropped()
    {
        var results = MemoryExtractionParser.Parse("{\"memories\":[\"not-an-object\",{\"text\":\"keep\"}]}", 12);
        Assert.Single(results);
        Assert.Equal("keep", results[0].Text);
    }

    [Fact]
    public void Parse_EmptyMessageId_NormalizesToNull()
    {
        var results = MemoryExtractionParser.Parse("{\"memories\":[{\"text\":\"x\",\"messageId\":\"   \"}]}", 12);
        Assert.Null(results[0].ClaimedMessageId);
    }

    [Fact]
    public void Parse_RespectsCandidateCap()
    {
        const string json = "{\"memories\":[{\"text\":\"a\"},{\"text\":\"b\"},{\"text\":\"c\"}]}";
        Assert.Equal(2, MemoryExtractionParser.Parse(json, 2).Count);
        Assert.Empty(MemoryExtractionParser.Parse(json, 0));
    }

    [Fact]
    public void Parse_BodyTruncatedTo1000Chars()
    {
        string big = new string('a', 5000);
        var results = MemoryExtractionParser.Parse("{\"memories\":[{\"text\":\"" + big + "\"}]}", 12);
        Assert.Equal(1000, results[0].Text.Length);
    }

    [Fact]
    public void Parse_UnparseableOrEmpty_ReturnsEmpty()
    {
        Assert.Empty(MemoryExtractionParser.Parse("not json at all", 12));
        Assert.Empty(MemoryExtractionParser.Parse("", 12));
        Assert.Empty(MemoryExtractionParser.Parse("{\"memories\":\"not-an-array\"}", 12));
    }

    [Fact]
    public void Parse_MissingMemoriesKey_ReturnsEmptyButNotNullPayload()
    {
        Assert.Empty(MemoryExtractionParser.Parse("{\"other\":1}", 12));
    }
}

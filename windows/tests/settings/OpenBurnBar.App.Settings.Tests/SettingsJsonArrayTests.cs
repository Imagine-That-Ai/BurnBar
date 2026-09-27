using OpenBurnBar.App.Settings;
using Xunit;

namespace OpenBurnBar.App.Settings.Tests;

/// <summary>
/// Parity tests for <see cref="SettingsJsonArray"/> — the lossless string-list
/// codec (SettingsManager.swift). Decode fails soft to an empty list; encode
/// normalizes; the manual serializer is byte-compatible with Foundation.
/// </summary>
public sealed class SettingsJsonArrayTests
{
    [Fact]
    public void Decode_ValidArray_TrimsAndDropsEmpties()
    {
        Assert.Equal(
            new[] { "a", "b" },
            SettingsJsonArray.Decode("[\"a\",\"b\"]"));
        Assert.Equal(
            new[] { "a", "b" },
            SettingsJsonArray.Decode("[\" a \",\"\",\"b\"]"));
        Assert.Empty(SettingsJsonArray.Decode("[]"));
    }

    [Theory]
    [InlineData("not json")]
    [InlineData("{\"a\":1}")]
    [InlineData("[\"a\",1]")]
    [InlineData("[null]")]
    [InlineData("[{\"a\":1}]")]
    [InlineData("")]
    public void Decode_MalformedOrMistyped_FailsToEmpty(string json)
    {
        Assert.Empty(SettingsJsonArray.Decode(json));
    }

    [Fact]
    public void Encode_NormalizesAndRoundTrips()
    {
        Assert.Equal("[\"a\",\"b\"]", SettingsJsonArray.Encode(new[] { " a ", "", "b" }));
        Assert.Equal("[]", SettingsJsonArray.Encode(System.Array.Empty<string>()));
        var values = new[] { "plain", "quo\"te", "back\\slash", "uni→é" };
        Assert.Equal(values, SettingsJsonArray.Decode(SettingsJsonArray.Encode(values)));
    }

    [Fact]
    public void ManuallySerialize_MatchesTheSwiftByteShape()
    {
        Assert.Equal(
            "[\"a\\/b\\\"c\\\\d\\n\"]",
            SettingsJsonArray.ManuallySerialize(new[] { "a/b\"c\\d\n" }));
        Assert.Equal(
            "[\"\\b\\f\\n\\r\\t\\u0001\"]",
            SettingsJsonArray.ManuallySerialize(new[] { "\b\f\n\r\t\u0001" }));
        Assert.Equal("[\"→é\"]", SettingsJsonArray.ManuallySerialize(new[] { "→é" }));
        Assert.Equal("[]", SettingsJsonArray.ManuallySerialize(System.Array.Empty<string>()));
    }

    [Fact]
    public void ManuallySerialize_OutputSurvivesTheLenientDecoder()
    {
        var tricky = new[] { "a/b", "q\"q", "c\\c", "line\nbreak", "tab\there", "snowman☃" };
        Assert.Equal(tricky, SettingsJsonArray.Decode(SettingsJsonArray.ManuallySerialize(tricky)));
    }
}

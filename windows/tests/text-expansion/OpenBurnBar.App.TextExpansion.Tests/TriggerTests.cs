using Xunit;

namespace OpenBurnBar.App.TextExpansion.Tests;

/// <summary>
/// Mirrors Swift <c>TextExpansionTests.testTriggerNormalizationAndValidation</c>
/// (OpenBurnBarCore/Tests/.../TextExpansionTests.swift), plus the trigger-canonicalization
/// edge cases the engine depends on.
/// </summary>
public sealed class TriggerTests
{
    [Fact]
    public void CanonicalName_StripsPrefix_TrimsAndLowercases()
    {
        Assert.Equal("confident", TextExpansionTrigger.CanonicalName("&&Confident"));
        Assert.Equal("confident", TextExpansionTrigger.CanonicalName("  &&&&Confident  "));
        Assert.Equal("confident", TextExpansionTrigger.CanonicalName("CONFIDENT"));
    }

    [Fact]
    public void ActivationToken_ReattachesPrefixToCanonicalName()
    {
        Assert.Equal("&&confident", TextExpansionTrigger.ActivationToken("confident"));
        Assert.Equal("&&confident", TextExpansionTrigger.ActivationToken("&&Confident"));
    }

    [Theory]
    [InlineData("confident_reply")]
    [InlineData("follow-up_2")]
    [InlineData("ab")]
    public void ValidationError_IsNull_ForValidTriggers(string trigger)
    {
        Assert.Null(TextExpansionTrigger.ValidationError(trigger));
        Assert.True(TextExpansionTrigger.IsValid(trigger));
    }

    [Theory]
    [InlineData("a")]              // too short (< MinLength)
    [InlineData("with space")]    // space is not allowed
    [InlineData("bad$")]          // symbol is not allowed
    [InlineData("Ünïcode")]       // non-ASCII letters are not allowed
    public void ValidationError_IsNotNull_ForInvalidTriggers(string trigger)
    {
        Assert.NotNull(TextExpansionTrigger.ValidationError(trigger));
        Assert.False(TextExpansionTrigger.IsValid(trigger));
    }

    [Fact]
    public void ValidationError_RejectsOverLongTriggers()
    {
        string tooLong = new string('a', TextExpansionTrigger.MaxLength + 1);
        Assert.NotNull(TextExpansionTrigger.ValidationError(tooLong));

        string atLimit = new string('a', TextExpansionTrigger.MaxLength);
        Assert.Null(TextExpansionTrigger.ValidationError(atLimit));
    }
}

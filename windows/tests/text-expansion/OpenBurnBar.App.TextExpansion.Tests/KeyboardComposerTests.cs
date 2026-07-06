using Xunit;

namespace OpenBurnBar.App.TextExpansion.Tests;

/// <summary>Mirrors Swift <c>testKeyboardComposerMakeSnippetValidatesAndCreates</c>.</summary>
public sealed class KeyboardComposerTests
{
    private static readonly TextExpansionSnippet[] Existing =
    {
        new(title: "Already", trigger: "already", body: "Existing"),
    };

    [Fact]
    public void MakeSnippet_Success_CanonicalizesTrigger_AndKeepsTitle()
    {
        var result = TextExpansionKeyboardComposer.MakeSnippet(
            rawTrigger: "&&hello",
            body: "World!",
            existing: Existing,
            title: "Hello Snippet");

        Assert.True(result.IsSuccess);
        Assert.Equal("hello", result.Snippet!.Trigger);
        Assert.Equal("World!", result.Snippet.Body);
        Assert.Equal("Hello Snippet", result.Snippet.Title);
        Assert.True(result.Snippet.IsEnabled);
    }

    [Fact]
    public void MakeSnippet_DefaultsTitleToTrigger_WhenTitleBlank()
    {
        var result = TextExpansionKeyboardComposer.MakeSnippet(
            rawTrigger: "&&hello", body: "World!", existing: Existing, title: "   ");
        Assert.True(result.IsSuccess);
        Assert.Equal("hello", result.Snippet!.Title);
    }

    [Fact]
    public void MakeSnippet_DuplicateTrigger_Fails()
    {
        var result = TextExpansionKeyboardComposer.MakeSnippet(
            rawTrigger: "&&already", body: "New Body", existing: Existing);
        Assert.False(result.IsSuccess);
        Assert.Equal(TextExpansionComposeError.DuplicateTrigger, result.Error);
        Assert.Equal("That trigger already exists.", result.ErrorMessage);
    }

    [Fact]
    public void MakeSnippet_EmptyBody_Fails()
    {
        var result = TextExpansionKeyboardComposer.MakeSnippet(
            rawTrigger: "&&new", body: "   \n  ", existing: Existing);
        Assert.False(result.IsSuccess);
        Assert.Equal(TextExpansionComposeError.EmptyBody, result.Error);
    }

    [Fact]
    public void MakeSnippet_InvalidTrigger_FailsWithMessage()
    {
        var result = TextExpansionKeyboardComposer.MakeSnippet(
            rawTrigger: "&&invalid trigger", body: "Body", existing: Existing);
        Assert.False(result.IsSuccess);
        Assert.Equal(TextExpansionComposeError.InvalidTrigger, result.Error);
        Assert.Equal("Use lowercase letters, numbers, hyphen, or underscore.", result.ErrorMessage);
    }
}

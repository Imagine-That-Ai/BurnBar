using System.Collections.Generic;
using Xunit;

namespace OpenBurnBar.App.TextExpansion.Tests;

/// <summary>
/// The golden trigger→expansion corpus. Every case here is a behavior mirror of the
/// Swift <c>TextExpansionMatcher</c> XCTest suite
/// (OpenBurnBarCore/Tests/.../TextExpansionTests.swift), extended with the edge cases
/// the port must preserve: partial triggers, prefix overlap, symbol-vs-punctuation
/// boundaries, hyphen/underscore-in-trigger, multi-char/unicode bodies, cursor
/// placement, and the escaping cases where a symbol glues into the token.
/// </summary>
public sealed class MatcherGoldenCorpusTests
{
    private static TextExpansionSnippet Snip(
        string trigger,
        string body,
        TextExpansionMode mode = TextExpansionMode.StaticText,
        TextExpansionScope? scope = null) =>
        new(title: trigger, trigger: trigger, body: body, mode: mode, scope: scope);

    // ── Swift parity: testStaticExpansionReplacesTokenAndPreservesBoundary ─────────
    [Fact]
    public void StaticExpansion_ReplacesToken_AndPreservesTrailingSpace()
    {
        var snippet = Snip("confident", "I'm confident this is the right next step.");
        var result = TextExpansionMatcher.ExpandStaticIfAvailable(
            "Send &&confident ", new[] { snippet }, TextExpansionSurface.InAppThread);

        Assert.NotNull(result);
        Assert.Equal("Send I'm confident this is the right next step. ", result!.Text);
        Assert.Equal("&&confident", result.Match.Token);
        Assert.Equal(' ', result.Match.Boundary);
    }

    // ── Swift parity: testStaticExpansionTreatsSentencePunctuationAsBoundary ───────
    [Fact]
    public void StaticExpansion_TreatsSentencePunctuationAsBoundary()
    {
        var snippet = Snip("thanks", "Thank you");
        var result = TextExpansionMatcher.ExpandStaticIfAvailable(
            "Send &&thanks.", new[] { snippet }, TextExpansionSurface.InAppThread);

        Assert.NotNull(result);
        Assert.Equal("Send Thank you.", result!.Text);
        Assert.Equal('.', result.Match.Boundary);
    }

    // ── Swift parity: testDoesNotExpandPrefixCollisionBeforeBoundary ──────────────
    [Fact]
    public void PrefixCollision_DoesNotExpandBeforeBoundary_ExpandsAfter()
    {
        var pro = Snip("pro", "professional");
        var proposal = Snip("proposal", "proposal draft");
        var snippets = new[] { pro, proposal };

        Assert.Null(TextExpansionMatcher.ExpandStaticIfAvailable("&&pro", snippets, TextExpansionSurface.InAppThread));
        Assert.Equal(
            "professional ",
            TextExpansionMatcher.ExpandStaticIfAvailable("&&pro ", snippets, TextExpansionSurface.InAppThread)!.Text);
        Assert.Equal(
            "proposal draft ",
            TextExpansionMatcher.ExpandStaticIfAvailable("&&proposal ", snippets, TextExpansionSurface.InAppThread)!.Text);
    }

    // ── Swift parity: testUnambiguousTokenCanExpandWithoutBoundary ────────────────
    [Fact]
    public void UnambiguousToken_ExpandsWithoutBoundary()
    {
        var snippet = Snip("confident", "Ready.");
        var result = TextExpansionMatcher.ExpandStaticIfAvailable(
            "&&confident", new[] { snippet }, TextExpansionSurface.InAppThread);

        Assert.NotNull(result);
        Assert.Equal("Ready.", result!.Text);
        Assert.Null(result.Match.Boundary);
    }

    [Fact]
    public void ExpandWhenUnambiguousFalse_SuppressesNoBoundaryMatch()
    {
        var snippet = Snip("confident", "Ready.");
        Assert.Null(TextExpansionMatcher.ExpandStaticIfAvailable(
            "&&confident", new[] { snippet }, TextExpansionSurface.InAppThread, expandWhenUnambiguous: false));
        // With a boundary the same token still expands even when unambiguous-expansion is off.
        Assert.NotNull(TextExpansionMatcher.ExpandStaticIfAvailable(
            "&&confident ", new[] { snippet }, TextExpansionSurface.InAppThread, expandWhenUnambiguous: false));
    }

    // ── Swift parity: testLLMModeReturnsPreviewMatchInsteadOfExpanding ────────────
    [Fact]
    public void LlmMode_ReturnsPreviewMatch_ButDoesNotStaticExpand()
    {
        var snippet = Snip("ctx", "Make this fit.", TextExpansionMode.LlmRewrite);
        var match = TextExpansionMatcher.Match("Please &&ctx ", new[] { snippet }, TextExpansionSurface.InAppThread);

        Assert.NotNull(match);
        Assert.Equal("&&ctx", match!.Token);
        Assert.True(match.RequiresPreview);
        Assert.Null(TextExpansionMatcher.ExpandStaticIfAvailable(
            "Please &&ctx ", new[] { snippet }, TextExpansionSurface.InAppThread));
    }

    // ── Swift parity: testScopeBlocksUnavailableSurfaces ──────────────────────────
    [Fact]
    public void Scope_BlocksUnavailableSurfacesAndThreads()
    {
        var snippet = Snip(
            "thread",
            "Thread text",
            scope: new TextExpansionScope(
                surfaces: new[] { TextExpansionSurface.InAppThread },
                threadIds: new[] { "abc" }));
        var snippets = new[] { snippet };

        Assert.Null(TextExpansionMatcher.Match("&&thread ", snippets, TextExpansionSurface.MacGlobal));
        Assert.Null(TextExpansionMatcher.Match("&&thread ", snippets, TextExpansionSurface.InAppThread, threadId: "other"));
        Assert.NotNull(TextExpansionMatcher.Match("&&thread ", snippets, TextExpansionSurface.InAppThread, threadId: "abc"));
    }

    [Fact]
    public void Scope_BundleIdentifierMatchIsCaseInsensitive()
    {
        var snippet = Snip(
            "signoff",
            "Best,",
            scope: new TextExpansionScope(
                surfaces: new[] { TextExpansionSurface.MacGlobal },
                bundleIdentifiers: new[] { "com.apple.TextEdit" }));
        var snippets = new[] { snippet };

        Assert.NotNull(TextExpansionMatcher.Match("&&signoff ", snippets, TextExpansionSurface.MacGlobal, bundleIdentifier: "COM.APPLE.textedit"));
        Assert.Null(TextExpansionMatcher.Match("&&signoff ", snippets, TextExpansionSurface.MacGlobal, bundleIdentifier: "com.other.app"));
        Assert.Null(TextExpansionMatcher.Match("&&signoff ", snippets, TextExpansionSurface.MacGlobal, bundleIdentifier: null));
    }

    // ── Edge: symbols are NOT boundaries (only P* punctuation is) ─────────────────
    [Theory]
    [InlineData('.')]
    [InlineData(',')]
    [InlineData('!')]
    [InlineData('?')]
    [InlineData(';')]
    [InlineData(':')]
    [InlineData(')')]
    [InlineData('"')]
    [InlineData('@')] // U+0040 is Unicode Po (OtherPunctuation), a boundary in Swift + C#
    [InlineData('#')] // U+0023 is Unicode Po (OtherPunctuation), a boundary in Swift + C#
    public void IsBoundary_TreatsPunctuationAsBoundary(char punctuation)
    {
        Assert.True(TextExpansionMatcher.IsBoundary(punctuation));
    }

    // Sm/Sc/Sk symbols are NOT punctuation, so Swift's CharacterSet.punctuationCharacters
    // (Unicode P*) and C#'s char.IsPunctuation both exclude them → never a boundary.
    [Theory]
    [InlineData('$')] // Sc CurrencySymbol
    [InlineData('+')] // Sm MathSymbol
    [InlineData('=')] // Sm
    [InlineData('<')] // Sm
    [InlineData('>')] // Sm
    [InlineData('|')] // Sm
    [InlineData('~')] // Sm
    [InlineData('^')] // Sk ModifierSymbol
    [InlineData('&')] // explicitly excluded even though not punctuation
    [InlineData('_')] // Pc, but explicitly excluded (part of triggers)
    [InlineData('-')] // Pd, but explicitly excluded (part of triggers)
    public void IsBoundary_TreatsSymbolsAndTriggerCharsAsNonBoundary(char symbol)
    {
        Assert.False(TextExpansionMatcher.IsBoundary(symbol));
    }

    [Fact]
    public void SymbolSuffix_GluesIntoToken_AndPreventsMatch()
    {
        // '$' is a symbol, not punctuation → no boundary → the token becomes
        // "&&confident$", whose canonical name "confident$" matches no snippet.
        var snippet = Snip("confident", "Ready.");
        Assert.Null(TextExpansionMatcher.Match("&&confident$", new[] { snippet }, TextExpansionSurface.InAppThread));
    }

    // ── Edge: hyphen + underscore are legal trigger characters, never boundaries ───
    [Fact]
    public void HyphenAndUnderscore_AreTriggerCharacters_NotBoundaries()
    {
        var snippet = Snip("follow-up_2", "Following up on this.");
        var result = TextExpansionMatcher.ExpandStaticIfAvailable(
            "&&follow-up_2 ", new[] { snippet }, TextExpansionSurface.InAppThread);
        Assert.NotNull(result);
        Assert.Equal("Following up on this. ", result!.Text);
    }

    // ── Edge: multi-char / unicode body inserts verbatim ──────────────────────────
    [Fact]
    public void UnicodeBody_ExpandsVerbatim()
    {
        var snippet = Snip("wave", "👋 hi");
        var result = TextExpansionMatcher.ExpandStaticIfAvailable(
            "&&wave ", new[] { snippet }, TextExpansionSurface.InAppThread);
        Assert.NotNull(result);
        Assert.Equal("👋 hi ", result!.Text);
    }

    // ── Edge: partial trigger does not expand ─────────────────────────────────────
    [Fact]
    public void PartialTrigger_DoesNotExpand()
    {
        var snippet = Snip("confident", "Ready.");
        Assert.Null(TextExpansionMatcher.Match("&&conf", new[] { snippet }, TextExpansionSurface.InAppThread));
    }

    // ── Edge: token must carry the full && prefix ─────────────────────────────────
    [Theory]
    [InlineData("confident ")]  // no prefix
    [InlineData("&confident ")] // single ampersand
    [InlineData("&& ")]         // empty canonical name
    public void NonPrefixedOrEmptyTokens_DoNotMatch(string text)
    {
        var snippet = Snip("confident", "Ready.");
        Assert.Null(TextExpansionMatcher.Match(text, new[] { snippet }, TextExpansionSurface.InAppThread));
    }

    // ── Edge: empty / no-active-snippet inputs ────────────────────────────────────
    [Fact]
    public void EmptyText_OrNoActiveSnippets_ReturnsNull()
    {
        var snippet = Snip("confident", "Ready.");
        Assert.Null(TextExpansionMatcher.Match(string.Empty, new[] { snippet }, TextExpansionSurface.InAppThread));
        Assert.Null(TextExpansionMatcher.Match("&&confident ", new List<TextExpansionSnippet>(), TextExpansionSurface.InAppThread));
    }

    [Fact]
    public void DisabledOrDeletedSnippets_AreIgnored()
    {
        var disabled = new TextExpansionSnippet(title: "off", trigger: "off", body: "x", isEnabled: false);
        var deleted = new TextExpansionSnippet(title: "gone", trigger: "gone", body: "x", deletedAt: System.DateTimeOffset.UtcNow);
        Assert.Null(TextExpansionMatcher.Match("&&off ", new[] { disabled }, TextExpansionSurface.InAppThread));
        Assert.Null(TextExpansionMatcher.Match("&&gone ", new[] { deleted }, TextExpansionSurface.InAppThread));
    }

    // ── Edge: cursor placement expands mid-string and preserves the tail ──────────
    [Fact]
    public void Cursor_ExpandsAtCaret_AndPreservesTrailingText()
    {
        var snippet = Snip("confident", "Ready.");
        // Caret sits right after "&&confident"; the trailing " tail" is untouched.
        var result = TextExpansionMatcher.ExpandStaticIfAvailable(
            "&&confident tail", new[] { snippet }, TextExpansionSurface.InAppThread, cursor: 11);
        Assert.NotNull(result);
        Assert.Equal("Ready. tail", result!.Text);
        Assert.Equal(0, result.Match.ReplacementStart);
        Assert.Equal(11, result.Match.ReplacementEnd);
    }

    // ── Edge: replacing a token embedded in surrounding text ──────────────────────
    [Fact]
    public void ReplacingMatch_OverwritesOnlyTheTokenRange()
    {
        var snippet = Snip("sig", "Best regards");
        var match = TextExpansionMatcher.Match("Hello &&sig.", new[] { snippet }, TextExpansionSurface.InAppThread);
        Assert.NotNull(match);
        Assert.Equal("Hello Best regards.", TextExpansionMatcher.ReplacingMatch("Hello &&sig.", match!));
        // Custom replacement (e.g. an LLM rewrite) overrides the body.
        Assert.Equal("Hello CUSTOM.", TextExpansionMatcher.ReplacingMatch("Hello &&sig.", match!, "CUSTOM"));
    }
}

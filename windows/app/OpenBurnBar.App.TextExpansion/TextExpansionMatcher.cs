using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.TextExpansion;

/// <summary>
/// A resolved trigger match. Faithful port of Swift <c>TextExpansionMatch</c>.
/// The replacement range is expressed as a half-open <c>[Start, End)</c> pair of
/// UTF-16 offsets into the matched text (the Swift <c>Range&lt;String.Index&gt;</c>).
/// </summary>
public sealed class TextExpansionMatch
{
    public TextExpansionMatch(
        TextExpansionSnippet snippet,
        string token,
        int replacementStart,
        int replacementEnd,
        char? boundary,
        bool requiresPreview)
    {
        Snippet = snippet;
        Token = token;
        ReplacementStart = replacementStart;
        ReplacementEnd = replacementEnd;
        Boundary = boundary;
        RequiresPreview = requiresPreview;
    }

    public TextExpansionSnippet Snippet { get; }

    /// <summary>The literal <c>&amp;&amp;trigger</c> token as typed (original case preserved).</summary>
    public string Token { get; }

    public int ReplacementStart { get; }

    public int ReplacementEnd { get; }

    /// <summary>The boundary character that closed the token (space, punctuation…), or null when unambiguous.</summary>
    public char? Boundary { get; }

    /// <summary>True for <see cref="TextExpansionMode.LlmRewrite"/> snippets: needs the preview seam, not a static expand.</summary>
    public bool RequiresPreview { get; }
}

/// <summary>A completed static expansion: the rewritten text plus the match that produced it. Swift <c>TextExpansionResult</c>.</summary>
public sealed class TextExpansionResult
{
    public TextExpansionResult(string text, TextExpansionMatch match)
    {
        Text = text;
        Match = match;
    }

    public string Text { get; }

    public TextExpansionMatch Match { get; }
}

/// <summary>
/// The pure <c>&amp;&amp;</c>-trigger detection + expansion engine. Faithful port of Swift
/// <c>TextExpansionMatcher</c> (OpenBurnBarCore/.../TextExpansion/TextExpansion.swift).
/// This is the byte/behavior-critical core; the golden corpus in
/// windows/tests/text-expansion/ mirrors the Swift XCTest suite one-for-one.
/// </summary>
public static class TextExpansionMatcher
{
    /// <summary>
    /// Port of Swift <c>isBoundary(_:)</c>. Whitespace/newline is always a boundary.
    /// Otherwise a single-scalar punctuation character is a boundary EXCEPT
    /// <c>&amp;</c>, <c>_</c>, <c>-</c>. Symbols (<c>$ + = &lt; &gt; | ~ ^ @ #</c>) are NOT
    /// punctuation and therefore NOT boundaries — matching Swift's
    /// <c>CharacterSet.punctuationCharacters</c> (Unicode categories P*), which
    /// <see cref="char.IsPunctuation(char)"/> reproduces exactly.
    /// </summary>
    public static bool IsBoundary(char character)
    {
        if (char.IsWhiteSpace(character))
        {
            // Covers space, tab, and newline (\n, \r) — Swift `isWhitespace || isNewline`.
            return true;
        }

        if (char.IsPunctuation(character))
        {
            return character != '&' && character != '_' && character != '-';
        }

        return false;
    }

    /// <summary>
    /// Faithful port of Swift <c>match(in:snippets:surface:...)</c>.
    /// Walks back from <paramref name="cursor"/> to the last boundary to isolate the
    /// typed token, requires the <c>&amp;&amp;</c> prefix, resolves the snippet by
    /// canonical name, and applies the ambiguity guard (a no-boundary token that is a
    /// strict prefix of a longer active trigger does not expand).
    /// </summary>
    /// <param name="cursor">UTF-16 offset of the caret; null means end of <paramref name="text"/>.</param>
    public static TextExpansionMatch? Match(
        string text,
        IReadOnlyList<TextExpansionSnippet> snippets,
        TextExpansionSurface surface,
        string? bundleIdentifier = null,
        string? threadId = null,
        int? cursor = null,
        bool expandWhenUnambiguous = true)
    {
        int caret = cursor ?? text.Length;
        if (caret <= 0)
        {
            return null;
        }

        var active = snippets
            .Where(s => s.IsActive && s.Scope.Allows(surface, bundleIdentifier, threadId))
            .ToList();
        if (active.Count == 0)
        {
            return null;
        }

        // prefixText = text[0..caret)
        char last = text[caret - 1];
        bool hasBoundary = IsBoundary(last);
        int tokenEnd = hasBoundary ? caret - 1 : caret;
        if (tokenEnd <= 0)
        {
            return null;
        }

        int tokenStart = tokenEnd;
        while (tokenStart > 0)
        {
            int previous = tokenStart - 1;
            if (IsBoundary(text[previous]))
            {
                break;
            }

            tokenStart = previous;
        }

        string token = text.Substring(tokenStart, tokenEnd - tokenStart);
        if (!token.StartsWith(Prefix, StringComparison.Ordinal))
        {
            return null;
        }

        string canonical = TextExpansionTrigger.CanonicalName(token);
        if (canonical.Length == 0)
        {
            return null;
        }

        var snippet = active.FirstOrDefault(s => string.Equals(s.Trigger, canonical, StringComparison.Ordinal));
        if (snippet is null)
        {
            return null;
        }

        if (!hasBoundary && !expandWhenUnambiguous)
        {
            return null;
        }

        if (!hasBoundary &&
            active.Any(s => !string.Equals(s.Trigger, canonical, StringComparison.Ordinal)
                            && s.Trigger.StartsWith(canonical, StringComparison.Ordinal)))
        {
            return null;
        }

        return new TextExpansionMatch(
            snippet: snippet,
            token: token,
            replacementStart: tokenStart,
            replacementEnd: tokenEnd,
            boundary: hasBoundary ? last : null,
            requiresPreview: snippet.Mode == TextExpansionMode.LlmRewrite);
    }

    /// <summary>
    /// Port of Swift <c>replacingMatch(in:match:replacement:)</c>: overwrite the
    /// token's range with <paramref name="replacement"/> (default: the snippet body).
    /// </summary>
    public static string ReplacingMatch(string text, TextExpansionMatch match, string? replacement = null)
    {
        string insert = replacement ?? match.Snippet.Body;
        return string.Concat(
            text.AsSpan(0, match.ReplacementStart),
            insert,
            text.AsSpan(match.ReplacementEnd));
    }

    /// <summary>
    /// Port of Swift <c>expandStaticIfAvailable(...)</c>: returns the expanded text
    /// only for a non-preview (static) match; returns null for LLM-preview snippets
    /// and when no match is found.
    /// </summary>
    public static TextExpansionResult? ExpandStaticIfAvailable(
        string text,
        IReadOnlyList<TextExpansionSnippet> snippets,
        TextExpansionSurface surface,
        string? bundleIdentifier = null,
        string? threadId = null,
        int? cursor = null,
        bool expandWhenUnambiguous = true)
    {
        var match = Match(text, snippets, surface, bundleIdentifier, threadId, cursor, expandWhenUnambiguous);
        if (match is null || match.RequiresPreview)
        {
            return null;
        }

        return new TextExpansionResult(ReplacingMatch(text, match), match);
    }

    private const string Prefix = TextExpansionTrigger.Prefix;
}

using System;

namespace OpenBurnBar.App.TextExpansion;

/// <summary>
/// Cached policy inputs for the OS-wide keystroke interceptor. Faithful port of
/// Swift <c>TextExpansionGlobalTapPolicy</c>. On macOS the CGEvent tap reads this
/// snapshot from a lock instead of calling AX APIs on the hot path; the Windows
/// low-level keyboard hook (bucket B/C) reads the identical snapshot.
/// </summary>
public sealed class TextExpansionGlobalTapPolicy : IEquatable<TextExpansionGlobalTapPolicy>
{
    public TextExpansionGlobalTapPolicy(
        bool globalExpansionEnabled = false,
        bool accessibilityTrusted = false,
        string? frontmostBundleIdentifier = null,
        string? ownBundleIdentifier = null,
        bool focusedSurfaceDenied = false)
    {
        GlobalExpansionEnabled = globalExpansionEnabled;
        AccessibilityTrusted = accessibilityTrusted;
        FrontmostBundleIdentifier = frontmostBundleIdentifier;
        OwnBundleIdentifier = ownBundleIdentifier;
        FocusedSurfaceDenied = focusedSurfaceDenied;
    }

    public bool GlobalExpansionEnabled { get; }

    /// <summary>macOS: Accessibility TCC grant. Windows peer: the hook/injection capability probe.</summary>
    public bool AccessibilityTrusted { get; }

    public string? FrontmostBundleIdentifier { get; }

    public string? OwnBundleIdentifier { get; }

    public bool FocusedSurfaceDenied { get; }

    /// <summary>
    /// Swift <c>shouldInterceptKeystrokes</c>: enabled AND trusted AND the front app is
    /// NOT our own app AND the focused surface is not denied (e.g. a secure field).
    /// </summary>
    public bool ShouldInterceptKeystrokes =>
        GlobalExpansionEnabled
        && AccessibilityTrusted
        && !string.Equals(FrontmostBundleIdentifier, OwnBundleIdentifier, StringComparison.Ordinal)
        && !FocusedSurfaceDenied;

    public bool Equals(TextExpansionGlobalTapPolicy? other)
    {
        if (other is null)
        {
            return false;
        }

        return GlobalExpansionEnabled == other.GlobalExpansionEnabled
            && AccessibilityTrusted == other.AccessibilityTrusted
            && string.Equals(FrontmostBundleIdentifier, other.FrontmostBundleIdentifier, StringComparison.Ordinal)
            && string.Equals(OwnBundleIdentifier, other.OwnBundleIdentifier, StringComparison.Ordinal)
            && FocusedSurfaceDenied == other.FocusedSurfaceDenied;
    }

    public override bool Equals(object? obj) => Equals(obj as TextExpansionGlobalTapPolicy);

    public override int GetHashCode() => HashCode.Combine(
        GlobalExpansionEnabled,
        AccessibilityTrusted,
        FrontmostBundleIdentifier,
        OwnBundleIdentifier,
        FocusedSurfaceDenied);
}

/// <summary>
/// Plans how many backspaces + what text to synthesize after a match, for a
/// NON-swallowing global monitor (the boundary character is already in the field
/// because a passive monitor cannot eat the key). Faithful port of Swift
/// <c>TextExpansionGlobalReplacementPlanner</c>.
/// </summary>
/// <remarks>
/// This is the passive-monitor model. The active/swallowing model (the CGEvent tap
/// peer) is computed inside <see cref="TextExpansionRuntimeController"/> — see
/// <see cref="TextExpansionReplacementCommand"/> — where the triggering key is eaten
/// and so the boundary is NOT yet in the field. The Windows OS adapter (bucket B/C)
/// selects the model that matches its capture mechanism.
/// </remarks>
public static class TextExpansionGlobalReplacementPlanner
{
    /// <summary>A delete-count + replacement-text instruction for the keystroke injector.</summary>
    public readonly record struct Plan(int DeleteCount, string Replacement);

    /// <summary>
    /// Swift <c>plan(for:)</c>: with a boundary, delete the token PLUS the boundary
    /// char (already typed) and re-append it after the body; without a boundary,
    /// delete exactly the token and type the body.
    /// </summary>
    public static Plan PlanFor(TextExpansionMatch match)
    {
        string boundary = match.Boundary is { } b ? b.ToString() : string.Empty;
        if (match.Boundary is not null)
        {
            return new Plan(match.Token.Length + 1, match.Snippet.Body + boundary);
        }

        return new Plan(match.Token.Length, match.Snippet.Body);
    }
}

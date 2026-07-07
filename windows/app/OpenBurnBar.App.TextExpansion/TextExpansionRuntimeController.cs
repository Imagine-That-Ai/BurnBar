using System;

namespace OpenBurnBar.App.TextExpansion;

/// <summary>What the OS adapter should do with the key that was just handed to the controller.</summary>
public enum TextExpansionKeyDecision
{
    /// <summary>Let the keystroke reach the focused field unchanged.</summary>
    PassThrough,

    /// <summary>Eat the keystroke: a trigger fired and the controller emitted a replacement command.</summary>
    Swallow,
}

/// <summary>A "delete N characters, then type this" instruction for the keystroke injector (bucket B/C).</summary>
public readonly record struct TextExpansionReplacementCommand(int DeleteCount, string Replacement, string Trigger);

/// <summary>
/// The keystroke injection seam. The portable controller decides WHAT to inject; the
/// OS adapter (a Win32 <c>SendInput</c> peer of the Mac <c>MacInputController</c> /
/// AX value mutation) performs the delete + type. Bucket B/C.
/// </summary>
public interface ITextExpansionKeystrokeSink
{
    void Replace(TextExpansionReplacementCommand command);
}

/// <summary>
/// The OS-agnostic global text-expansion state machine. Faithful behavior port of the
/// hot path in Swift <c>TextExpansionRuntimeController.handleEvent</c>
/// (AgentLens/Services/TextExpansion/TextExpansionRuntimeController.swift): a rolling
/// keystroke buffer, per-key trigger matching, the swallowing-tap delete-count model,
/// and a post-expansion suppression window that ignores the synthetic keystrokes the
/// injector itself produces.
/// </summary>
/// <remarks>
/// Everything OS-specific is behind seams: keystroke capture is the adapter calling
/// <see cref="HandleCharacter"/> / <see cref="HandleBackspace"/> / etc.; injection is
/// <see cref="ITextExpansionKeystrokeSink"/>; the snippet set is
/// <see cref="ITextExpansionSnippetSource"/>; the clock is injected for deterministic
/// tests of the suppression window; and the secure-field guard is a predicate. The
/// controller is single-threaded by contract (the adapter serializes calls onto its
/// hook thread), matching the Mac controller's lock-confined callback state.
/// </remarks>
public sealed class TextExpansionRuntimeController
{
    /// <summary>Swift buffer cap: keep only the trailing 160 characters.</summary>
    public const int MaxBufferLength = 160;

    /// <summary>Swift <c>setSuppressEvents(for: 1.5)</c>.</summary>
    public static readonly TimeSpan DefaultSuppressWindow = TimeSpan.FromSeconds(1.5);

    private readonly ITextExpansionSnippetSource _snippetSource;
    private readonly ITextExpansionKeystrokeSink _keystrokeSink;
    private readonly Func<DateTimeOffset> _clock;
    private readonly Func<bool> _isSecureSurface;
    private readonly TimeSpan _suppressWindow;

    private string _buffer = string.Empty;
    private DateTimeOffset _suppressUntil = DateTimeOffset.MinValue;

    public TextExpansionRuntimeController(
        ITextExpansionSnippetSource snippetSource,
        ITextExpansionKeystrokeSink keystrokeSink,
        TextExpansionGlobalTapPolicy? policy = null,
        Func<DateTimeOffset>? clock = null,
        Func<bool>? isSecureSurface = null,
        TimeSpan? suppressWindow = null)
    {
        _snippetSource = snippetSource;
        _keystrokeSink = keystrokeSink;
        Policy = policy ?? new TextExpansionGlobalTapPolicy();
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
        _isSecureSurface = isSecureSurface ?? (() => false);
        _suppressWindow = suppressWindow ?? DefaultSuppressWindow;
    }

    /// <summary>Cached policy inputs (enabled, trusted, own/frontmost bundle). Refreshed off the hot path.</summary>
    public TextExpansionGlobalTapPolicy Policy { get; set; }

    /// <summary>The current rolling keystroke buffer (exposed for diagnostics + tests).</summary>
    public string Buffer => _buffer;

    /// <summary>True while the post-expansion suppression window is open at <paramref name="at"/>.</summary>
    public bool IsSuppressed(DateTimeOffset at) => at < _suppressUntil;

    /// <summary>
    /// Feed one or more printable characters (a keyDown that produced text). Returns
    /// whether the OS adapter should swallow the key. Port of the printable-key branch
    /// of <c>handleEvent</c>.
    /// </summary>
    public TextExpansionKeyDecision HandleCharacter(string characters)
    {
        if (!TryEnterHotPath(out var failDecision))
        {
            return failDecision;
        }

        if (string.IsNullOrEmpty(characters))
        {
            // Swift: empty character payload passes through WITHOUT touching the buffer.
            return TextExpansionKeyDecision.PassThrough;
        }

        var match = AppendAndMatch(characters);
        if (match is null || match.RequiresPreview)
        {
            return TextExpansionKeyDecision.PassThrough;
        }

        // Only on an actual trigger match do we pay for the secure-field check, and we
        // do it BEFORE swallowing — never expand into a secure/password field.
        if (_isSecureSurface())
        {
            Reset();
            return TextExpansionKeyDecision.PassThrough;
        }

        var command = BuildReplacementCommand(match, characters);
        _suppressUntil = _clock().Add(_suppressWindow);
        _keystrokeSink.Replace(command);
        Reset();
        return TextExpansionKeyDecision.Swallow;
    }

    /// <summary>Feed a Backspace/Delete keyDown. Port of the <c>keyCode == 51</c> branch.</summary>
    public TextExpansionKeyDecision HandleBackspace()
    {
        if (!TryEnterHotPath(out var failDecision))
        {
            return failDecision;
        }

        if (_buffer.Length > 0)
        {
            _buffer = _buffer.Substring(0, _buffer.Length - 1);
        }

        return TextExpansionKeyDecision.PassThrough;
    }

    /// <summary>
    /// Feed a keyDown that carried a Command/Control/Alt modifier. Port of the modifier
    /// branch: it clears the in-progress token so a shortcut never completes a trigger.
    /// </summary>
    public TextExpansionKeyDecision HandleModifierCombo()
    {
        if (!TryEnterHotPath(out var failDecision))
        {
            return failDecision;
        }

        Reset();
        return TextExpansionKeyDecision.PassThrough;
    }

    /// <summary>
    /// Update the cached frontmost app (off the hot path, e.g. on an app-activation
    /// notification), mirroring the Mac controller's <c>refreshTapRuntimeSnapshot</c>.
    /// </summary>
    public void SetFrontmostBundleIdentifier(string? frontmostBundleIdentifier)
    {
        Policy = new TextExpansionGlobalTapPolicy(
            globalExpansionEnabled: Policy.GlobalExpansionEnabled,
            accessibilityTrusted: Policy.AccessibilityTrusted,
            frontmostBundleIdentifier: frontmostBundleIdentifier,
            ownBundleIdentifier: Policy.OwnBundleIdentifier,
            focusedSurfaceDenied: Policy.FocusedSurfaceDenied);
    }

    /// <summary>Clear the in-progress keystroke buffer (Swift <c>resetBuffer</c> / tap teardown).</summary>
    public void Reset() => _buffer = string.Empty;

    /// <summary>
    /// Entry gates shared by every key branch, in Swift order: the suppression window
    /// first (pass through untouched), then the enabled/trusted gate and the
    /// own-app-is-frontmost gate (both reset the buffer on failure).
    /// </summary>
    private bool TryEnterHotPath(out TextExpansionKeyDecision failDecision)
    {
        failDecision = TextExpansionKeyDecision.PassThrough;

        if (IsSuppressed(_clock()))
        {
            // Suppressed: the synthetic replacement keystrokes flow through untouched.
            return false;
        }

        if (!Policy.GlobalExpansionEnabled || !Policy.AccessibilityTrusted)
        {
            Reset();
            return false;
        }

        if (Policy.OwnBundleIdentifier is not null &&
            string.Equals(Policy.OwnBundleIdentifier, Policy.FrontmostBundleIdentifier, StringComparison.Ordinal))
        {
            Reset();
            return false;
        }

        return true;
    }

    /// <summary>Append to the buffer (capped to the trailing <see cref="MaxBufferLength"/>) and match. Swift <c>appendAndMatch</c>.</summary>
    private TextExpansionMatch? AppendAndMatch(string characters)
    {
        _buffer += characters;
        if (_buffer.Length > MaxBufferLength)
        {
            _buffer = _buffer.Substring(_buffer.Length - MaxBufferLength);
        }

        var snippets = _snippetSource.LoadEnabled(
            TextExpansionSurface.MacGlobal,
            Policy.FrontmostBundleIdentifier);

        return TextExpansionMatcher.Match(
            text: _buffer,
            snippets: snippets,
            surface: TextExpansionSurface.MacGlobal,
            bundleIdentifier: Policy.FrontmostBundleIdentifier);
    }

    /// <summary>
    /// The SWALLOWING-tap delete-count model from <c>handleEvent</c>: the triggering key
    /// was eaten, so with a boundary delete exactly the token (the boundary was eaten too
    /// and is re-typed after the body); without a boundary delete the token minus the
    /// just-typed characters. Replacement is always <c>body + boundary</c>.
    /// </summary>
    private static TextExpansionReplacementCommand BuildReplacementCommand(TextExpansionMatch match, string typedCharacters)
    {
        string boundary = match.Boundary is { } b ? b.ToString() : string.Empty;
        int deleteCount = match.Boundary is null
            ? Math.Max(0, match.Token.Length - typedCharacters.Length)
            : match.Token.Length;

        return new TextExpansionReplacementCommand(
            DeleteCount: deleteCount,
            Replacement: match.Snippet.Body + boundary,
            Trigger: match.Snippet.Trigger);
    }
}

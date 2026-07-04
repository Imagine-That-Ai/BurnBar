using System;
using System.Collections.Generic;

namespace OpenBurnBar.Pretext;

// MARK: - Pretext Value Types
//
// C# mirror of `OpenBurnBarCore/Sources/OpenBurnBarCore/Pretext/PretextTypes.swift`
// — the public @chenglou/pretext API surface in value types. Handles reference
// state living inside the Pretext WebView2 shell; C# never sees the underlying JS
// structures, only opaque integer IDs that round-trip through the bridge.
//
// All measurements are CSS pixels (`double`, matching CGFloat on the Swift side).
// Pretext's measurement basis is the canvas font metric, which matches CSS box
// dimensions for text rendering. Do not confuse with logical points or device
// pixels.

/// Opaque handle to a `PreparedText` / `PreparedTextWithSegments` living inside
/// the Pretext engine. Released via <see cref="PretextEngine.ReleaseAsync(PretextHandle)"/>.
public readonly record struct PretextHandle(int Id);

/// Opaque handle to a prepared rich-inline run.
public readonly record struct PretextRichHandle(int Id);

/// Mirror of `prepare()` / `prepareWithSegments()` options.
public sealed record PretextOptions
{
    public enum WhiteSpaceMode
    {
        Normal,
        PreWrap,
    }

    public enum WordBreakMode
    {
        Normal,
        KeepAll,
    }

    public WhiteSpaceMode? WhiteSpace { get; init; }
    public WordBreakMode? WordBreak { get; init; }

    /// CSS pixel value, matching the JS API.
    public double? LetterSpacing { get; init; }

    /// Default normal-flow options (== Swift `PretextOptions.normal`).
    public static readonly PretextOptions Normal = new();

    /// The JS-facing string for a white-space mode (matches the CSS keyword).
    public static string ToCssValue(WhiteSpaceMode mode) => mode switch
    {
        WhiteSpaceMode.Normal => "normal",
        WhiteSpaceMode.PreWrap => "pre-wrap",
        _ => "normal",
    };

    /// The JS-facing string for a word-break mode (matches the CSS keyword).
    public static string ToCssValue(WordBreakMode mode) => mode switch
    {
        WordBreakMode.Normal => "normal",
        WordBreakMode.KeepAll => "keep-all",
        _ => "normal",
    };

    /// Emit the same sparse `{ whiteSpace?, wordBreak?, letterSpacing? }` object
    /// the Swift `optionsJSON(_:)` builds — only non-null keys are present.
    public IReadOnlyDictionary<string, object> ToJsonObject()
    {
        var dict = new Dictionary<string, object>();
        if (WhiteSpace is { } ws)
        {
            dict["whiteSpace"] = ToCssValue(ws);
        }
        if (WordBreak is { } wb)
        {
            dict["wordBreak"] = ToCssValue(wb);
        }
        if (LetterSpacing is { } ls)
        {
            dict["letterSpacing"] = ls;
        }
        return dict;
    }
}

/// Result of `layout()` — paragraph height + line count.
public readonly record struct PretextLayoutResult(double Height, int LineCount);

/// One line produced by `layoutWithLines()`.
public readonly record struct PretextLine(string Text, double Width);

/// Result of `layoutWithLines()` — height, line count, and the actual lines.
public sealed record PretextLinesResult(double Height, int LineCount, IReadOnlyList<PretextLine> Lines);

/// Result of `measureLineStats()`.
public readonly record struct PretextLineStats(int LineCount, double MaxLineWidth);

// MARK: - Rich Inline

/// One fragment of input for `prepareRichInline()`.
///
/// `Font` uses the same canvas string format as everywhere else
/// (`"500 17px Inter"`). Set <see cref="BreakNever"/> to <c>true</c> for atomic
/// items like chips and mentions, and pass <see cref="ExtraWidth"/> to reserve
/// space for pill chrome.
public sealed record PretextRichInlineItem
{
    public required string Text { get; init; }
    public required string Font { get; init; }
    public bool BreakNever { get; init; }
    public double ExtraWidth { get; init; }
}

/// One fragment of laid-out rich-inline text. <see cref="ItemIndex"/> points back
/// into the original item list so callers can recover the source font, color, and
/// any caller-owned chrome.
public readonly record struct PretextRichFragment(string Text, int ItemIndex, double GapBefore);

/// One line of laid-out rich-inline text.
public sealed record PretextRichLine(double Width, IReadOnlyList<PretextRichFragment> Fragments);

// MARK: - Errors

/// Peer of the Swift `PretextError` enum. Thrown by the engine on bridge/protocol
/// failures.
public sealed class PretextException : Exception
{
    public enum Reason
    {
        EngineUnavailable,
        Timeout,
        InvalidResponse,
        BridgeError,
    }

    public Reason Kind { get; }

    public PretextException(Reason kind, string? message = null)
        : base(message ?? DefaultMessage(kind))
    {
        Kind = kind;
    }

    public static PretextException EngineUnavailable() => new(Reason.EngineUnavailable);
    public static PretextException Timeout() => new(Reason.Timeout);
    public static PretextException InvalidResponse() => new(Reason.InvalidResponse);
    public static PretextException Bridge(string message) =>
        new(Reason.BridgeError, $"Pretext bridge error: {message}");

    private static string DefaultMessage(Reason kind) => kind switch
    {
        Reason.EngineUnavailable => "Pretext engine is not loaded yet.",
        Reason.Timeout => "Pretext call timed out.",
        Reason.InvalidResponse => "Pretext returned a malformed response.",
        Reason.BridgeError => "Pretext bridge error.",
        _ => "Pretext error.",
    };
}

using System;

namespace OpenBurnBar.App.Presentation.Chat;

// MARK: - Hermes Rich Run
//
// C# peer of the `HermesRichRun` / `HermesRichRunKind` value types in
// `OpenBurnBarCore/Sources/OpenBurnBarCore/Hermes/HermesAtomParser.swift`.
//
// One typed segment of a parsed Hermes message. Runs preserve the original
// reading order; rendering always concatenates them in sequence. The WinUI
// atom-router (windows/app/OpenBurnBar.App/Chat) turns each run into an inline
// element: body text, an atom chip, an @mention pill, or an inline-code span.

/// Inline-markdown styling carried by a `.Body` run (peer of Swift
/// `HermesInlineStyle`). Combines like an OptionSet so a heading line (bold)
/// containing `*emphasis*` unions to Bold | Italic.
[Flags]
public enum HermesInlineStyle
{
    None = 0,
    Bold = 1 << 0,
    Italic = 1 << 1,
    Strikethrough = 1 << 2,
}

/// Discriminator for <see cref="HermesRichRun"/> (peer of Swift
/// `HermesRichRunKind`).
public enum HermesRichRunKind
{
    /// Plain prose. <see cref="HermesRichRun.Style"/> carries inline emphasis;
    /// markers are stripped from <see cref="HermesRichRun.Text"/> by design.
    Body,

    /// A tappable atom chip. <see cref="HermesRichRun.Atom"/> is non-null.
    Atom,

    /// `@handle` mention — atomic, accent-colored chip.
    Mention,

    /// `` `inline code` `` — splittable mono span.
    Code,
}

/// One typed segment of a parsed Hermes message.
public sealed record HermesRichRun
{
    public string Text { get; }

    public HermesRichRunKind Kind { get; }

    /// Emphasis for <see cref="HermesRichRunKind.Body"/> runs (None otherwise).
    public HermesInlineStyle Style { get; }

    /// The atom for <see cref="HermesRichRunKind.Atom"/> runs (null otherwise).
    public HermesAtom? Atom { get; }

    private HermesRichRun(string text, HermesRichRunKind kind, HermesInlineStyle style, HermesAtom? atom)
    {
        Text = text;
        Kind = kind;
        Style = style;
        Atom = atom;
    }

    public static HermesRichRun Body(string text, HermesInlineStyle style = HermesInlineStyle.None) =>
        new(text, HermesRichRunKind.Body, style, null);

    public static HermesRichRun MakeAtom(HermesAtom atom, string label) =>
        new(label, HermesRichRunKind.Atom, HermesInlineStyle.None, atom);

    public static HermesRichRun Mention(string handle) =>
        new(handle, HermesRichRunKind.Mention, HermesInlineStyle.None, null);

    public static HermesRichRun Code(string text) =>
        new(text, HermesRichRunKind.Code, HermesInlineStyle.None, null);

    /// Atomic runs never wrap across lines (peer of Swift `isAtomic`).
    public bool IsAtomic => Kind is HermesRichRunKind.Atom or HermesRichRunKind.Mention;
}

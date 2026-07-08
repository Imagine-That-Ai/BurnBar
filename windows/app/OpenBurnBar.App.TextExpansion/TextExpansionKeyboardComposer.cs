using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.TextExpansion;

/// <summary>Why a keyboard-composed snippet was rejected. Faithful port of Swift <c>ComposeError</c>.</summary>
public enum TextExpansionComposeError
{
    InvalidTrigger,
    EmptyBody,
    DuplicateTrigger,
}

/// <summary>
/// Result of <see cref="TextExpansionKeyboardComposer.MakeSnippet"/>: either a
/// validated snippet or a typed error with the user-facing message. Mirrors the
/// Swift <c>Result&lt;TextExpansionSnippet, ComposeError&gt;</c>.
/// </summary>
public sealed class TextExpansionComposeResult
{
    private TextExpansionComposeResult(TextExpansionSnippet? snippet, TextExpansionComposeError? error, string? message)
    {
        Snippet = snippet;
        Error = error;
        ErrorMessage = message;
    }

    public TextExpansionSnippet? Snippet { get; }

    public TextExpansionComposeError? Error { get; }

    public string? ErrorMessage { get; }

    public bool IsSuccess => Snippet is not null;

    public static TextExpansionComposeResult Success(TextExpansionSnippet snippet) => new(snippet, null, null);

    public static TextExpansionComposeResult Failure(TextExpansionComposeError error, string message) =>
        new(null, error, message);
}

/// <summary>
/// The self-contained "add a snippet from the keyboard" flow. Faithful port of Swift
/// <c>TextExpansionKeyboardComposer.makeSnippet(...)</c> — the pure, disk-free half
/// (validate trigger, guard duplicate active triggers, resolve title, build the
/// snippet scoped to all surfaces). The disk-merge + inbox half is macOS App-Group
/// glue and is out of scope for the portable core.
/// </summary>
public static class TextExpansionKeyboardComposer
{
    public static TextExpansionComposeResult MakeSnippet(
        string rawTrigger,
        string body,
        IReadOnlyList<TextExpansionSnippet> existing,
        string? title = null,
        string? sourceDeviceId = null,
        DateTimeOffset? now = null)
    {
        string trigger = TextExpansionTrigger.CanonicalName(rawTrigger);
        string? validationError = TextExpansionTrigger.ValidationError(trigger);
        if (validationError is not null)
        {
            return TextExpansionComposeResult.Failure(TextExpansionComposeError.InvalidTrigger, validationError);
        }

        string trimmedBody = body.Trim();
        if (trimmedBody.Length == 0)
        {
            return TextExpansionComposeResult.Failure(
                TextExpansionComposeError.EmptyBody,
                "Add the text this snippet should insert.");
        }

        bool duplicate = existing.Any(s =>
            s.DeletedAt is null && string.Equals(s.Trigger, trigger, StringComparison.Ordinal));
        if (duplicate)
        {
            return TextExpansionComposeResult.Failure(
                TextExpansionComposeError.DuplicateTrigger,
                "That trigger already exists.");
        }

        string resolvedTitle = !string.IsNullOrWhiteSpace(title) ? title!.Trim() : trigger;
        DateTimeOffset timestamp = now ?? DateTimeOffset.UtcNow;

        var snippet = new TextExpansionSnippet(
            title: resolvedTitle,
            trigger: trigger,
            body: trimmedBody,
            mode: TextExpansionMode.StaticText,
            isEnabled: true,
            scope: new TextExpansionScope(surfaces: TextExpansionRawValues.AllSurfaces),
            createdAt: timestamp,
            updatedAt: timestamp,
            sourceDeviceId: sourceDeviceId);

        return TextExpansionComposeResult.Success(snippet);
    }
}

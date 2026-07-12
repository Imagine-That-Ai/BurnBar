using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.TextExpansion;

/// <summary>
/// How a snippet expands. Faithful port of Swift <c>TextExpansionMode</c>
/// (OpenBurnBarCore/.../TextExpansion/TextExpansion.swift).
/// </summary>
public enum TextExpansionMode
{
    /// <summary>Swift raw value <c>"static"</c>.</summary>
    StaticText,

    /// <summary>Swift raw value <c>"llm_rewrite"</c>.</summary>
    LlmRewrite,
}

/// <summary>
/// The surface an expansion can fire on. Faithful port of Swift
/// <c>TextExpansionSurface</c>. Declaration order matches Swift <c>allCases</c>.
/// </summary>
public enum TextExpansionSurface
{
    /// <summary>Swift raw value <c>"in_app_thread"</c>.</summary>
    InAppThread,

    /// <summary>Swift raw value <c>"mac_global"</c>. On Windows this is the OS-wide surface.</summary>
    MacGlobal,

    /// <summary>Swift raw value <c>"ios_keyboard"</c>.</summary>
    IosKeyboard,

    /// <summary>Swift raw value <c>"android_ime"</c>.</summary>
    AndroidIme,
}

/// <summary>Swift <c>rawValue</c> &lt;-&gt; enum bridging so JSON/DB text stays byte-identical to macOS.</summary>
public static class TextExpansionRawValues
{
    public static string ToRawValue(this TextExpansionMode mode) => mode switch
    {
        TextExpansionMode.StaticText => "static",
        TextExpansionMode.LlmRewrite => "llm_rewrite",
        _ => "static",
    };

    /// <summary>Parses a Swift <c>TextExpansionMode</c> raw value; unknown values fall back to static (matches DB read seam).</summary>
    public static TextExpansionMode ParseMode(string? raw) => raw switch
    {
        "llm_rewrite" => TextExpansionMode.LlmRewrite,
        _ => TextExpansionMode.StaticText,
    };

    public static string ToRawValue(this TextExpansionSurface surface) => surface switch
    {
        TextExpansionSurface.InAppThread => "in_app_thread",
        TextExpansionSurface.MacGlobal => "mac_global",
        TextExpansionSurface.IosKeyboard => "ios_keyboard",
        TextExpansionSurface.AndroidIme => "android_ime",
        _ => "in_app_thread",
    };

    /// <summary>Parses a Swift <c>TextExpansionSurface</c> raw value; returns null for an unknown token.</summary>
    public static TextExpansionSurface? ParseSurface(string? raw) => raw switch
    {
        "in_app_thread" => TextExpansionSurface.InAppThread,
        "mac_global" => TextExpansionSurface.MacGlobal,
        "ios_keyboard" => TextExpansionSurface.IosKeyboard,
        "android_ime" => TextExpansionSurface.AndroidIme,
        _ => null,
    };

    /// <summary>Swift <c>TextExpansionSurface.allCases</c>, in declaration order.</summary>
    public static IReadOnlyList<TextExpansionSurface> AllSurfaces { get; } = new[]
    {
        TextExpansionSurface.InAppThread,
        TextExpansionSurface.MacGlobal,
        TextExpansionSurface.IosKeyboard,
        TextExpansionSurface.AndroidIme,
    };
}

/// <summary>
/// Which surfaces / apps / threads a snippet is allowed on. Faithful port of Swift
/// <c>TextExpansionScope</c>, including the case-insensitive bundle-identifier match
/// and the case-sensitive thread-id match.
/// </summary>
public sealed class TextExpansionScope : IEquatable<TextExpansionScope>
{
    public IReadOnlyList<TextExpansionSurface> Surfaces { get; }

    public IReadOnlyList<string> BundleIdentifiers { get; }

    public IReadOnlyList<string> ThreadIds { get; }

    public TextExpansionScope(
        IReadOnlyList<TextExpansionSurface>? surfaces = null,
        IReadOnlyList<string>? bundleIdentifiers = null,
        IReadOnlyList<string>? threadIds = null)
    {
        Surfaces = surfaces ?? TextExpansionRawValues.AllSurfaces;
        BundleIdentifiers = bundleIdentifiers ?? Array.Empty<string>();
        ThreadIds = threadIds ?? Array.Empty<string>();
    }

    /// <summary>Swift <c>TextExpansionScope.global</c>: all surfaces, no bundle/thread restriction.</summary>
    public static TextExpansionScope Global { get; } = new();

    /// <summary>Faithful port of Swift <c>allows(surface:bundleIdentifier:threadID:)</c>.</summary>
    public bool Allows(TextExpansionSurface surface, string? bundleIdentifier = null, string? threadId = null)
    {
        if (!Surfaces.Contains(surface))
        {
            return false;
        }

        if (BundleIdentifiers.Count > 0)
        {
            if (bundleIdentifier is null ||
                !BundleIdentifiers.Any(id => string.Equals(id, bundleIdentifier, StringComparison.OrdinalIgnoreCase)))
            {
                return false;
            }
        }

        if (ThreadIds.Count > 0)
        {
            if (threadId is null || !ThreadIds.Contains(threadId, StringComparer.Ordinal))
            {
                return false;
            }
        }

        return true;
    }

    public bool Equals(TextExpansionScope? other)
    {
        if (other is null)
        {
            return false;
        }

        return Surfaces.SequenceEqual(other.Surfaces)
            && BundleIdentifiers.SequenceEqual(other.BundleIdentifiers, StringComparer.Ordinal)
            && ThreadIds.SequenceEqual(other.ThreadIds, StringComparer.Ordinal);
    }

    public override bool Equals(object? obj) => Equals(obj as TextExpansionScope);

    public override int GetHashCode()
    {
        var hash = new HashCode();
        foreach (var surface in Surfaces)
        {
            hash.Add(surface);
        }

        foreach (var bundle in BundleIdentifiers)
        {
            hash.Add(bundle, StringComparer.Ordinal);
        }

        foreach (var thread in ThreadIds)
        {
            hash.Add(thread, StringComparer.Ordinal);
        }

        return hash.ToHashCode();
    }
}

/// <summary>
/// A single saved snippet. Faithful port of Swift <c>TextExpansionSnippet</c>: the
/// constructor canonicalizes the trigger, and <see cref="ActivationToken"/> /
/// <see cref="IsActive"/> mirror the Swift computed properties.
/// </summary>
public sealed class TextExpansionSnippet
{
    public string Id { get; }

    public string Title { get; }

    /// <summary>Canonical trigger name WITHOUT the <c>&amp;&amp;</c> prefix (lowercased, trimmed).</summary>
    public string Trigger { get; }

    public string Body { get; }

    public TextExpansionMode Mode { get; }

    public bool IsEnabled { get; }

    public TextExpansionScope Scope { get; }

    public int Revision { get; }

    public DateTimeOffset CreatedAt { get; }

    public DateTimeOffset UpdatedAt { get; }

    public DateTimeOffset? DeletedAt { get; }

    public DateTimeOffset? SyncedAt { get; }

    public string? SourceDeviceId { get; }

    public TextExpansionSnippet(
        string title,
        string trigger,
        string body,
        string? id = null,
        TextExpansionMode mode = TextExpansionMode.StaticText,
        bool isEnabled = true,
        TextExpansionScope? scope = null,
        int revision = 1,
        DateTimeOffset? createdAt = null,
        DateTimeOffset? updatedAt = null,
        DateTimeOffset? deletedAt = null,
        DateTimeOffset? syncedAt = null,
        string? sourceDeviceId = null)
    {
        Id = id ?? Guid.NewGuid().ToString();
        Title = title;
        Trigger = TextExpansionTrigger.CanonicalName(trigger);
        Body = body;
        Mode = mode;
        IsEnabled = isEnabled;
        Scope = scope ?? TextExpansionScope.Global;
        Revision = revision;
        CreatedAt = createdAt ?? DateTimeOffset.UtcNow;
        UpdatedAt = updatedAt ?? DateTimeOffset.UtcNow;
        DeletedAt = deletedAt;
        SyncedAt = syncedAt;
        SourceDeviceId = sourceDeviceId;
    }

    /// <summary>The full <c>&amp;&amp;trigger</c> token that fires this snippet.</summary>
    public string ActivationToken => TextExpansionTrigger.Prefix + Trigger;

    /// <summary>Swift <c>isActive</c>: enabled, not soft-deleted, non-empty trigger.</summary>
    public bool IsActive => IsEnabled && DeletedAt is null && Trigger.Length > 0;

    /// <summary>Returns a copy with the supplied fields overridden (immutable-update helper).</summary>
    public TextExpansionSnippet With(
        string? title = null,
        string? trigger = null,
        string? body = null,
        TextExpansionMode? mode = null,
        bool? isEnabled = null,
        TextExpansionScope? scope = null,
        int? revision = null,
        DateTimeOffset? createdAt = null,
        DateTimeOffset? updatedAt = null,
        Optional<DateTimeOffset?>? deletedAt = null,
        Optional<DateTimeOffset?>? syncedAt = null,
        Optional<string?>? sourceDeviceId = null)
    {
        return new TextExpansionSnippet(
            title: title ?? Title,
            trigger: trigger ?? Trigger,
            body: body ?? Body,
            id: Id,
            mode: mode ?? Mode,
            isEnabled: isEnabled ?? IsEnabled,
            scope: scope ?? Scope,
            revision: revision ?? Revision,
            createdAt: createdAt ?? CreatedAt,
            updatedAt: updatedAt ?? UpdatedAt,
            deletedAt: deletedAt is { } d ? d.Value : DeletedAt,
            syncedAt: syncedAt is { } s ? s.Value : SyncedAt,
            sourceDeviceId: sourceDeviceId is { } sd ? sd.Value : SourceDeviceId);
    }
}

/// <summary>Lets <see cref="TextExpansionSnippet.With"/> distinguish "leave unchanged" from "set to null".</summary>
public readonly struct Optional<T>
{
    public Optional(T value) => Value = value;

    public T Value { get; }

    public static implicit operator Optional<T>(T value) => new(value);
}

/// <summary>
/// A portable, exportable set of snippets. Faithful port of Swift
/// <c>TextExpansionSnapshot</c>.
/// </summary>
public sealed class TextExpansionSnapshot
{
    public int SchemaVersion { get; }

    public DateTimeOffset ExportedAt { get; }

    public IReadOnlyList<TextExpansionSnippet> Snippets { get; }

    public TextExpansionSnapshot(
        IReadOnlyList<TextExpansionSnippet> snippets,
        int schemaVersion = 1,
        DateTimeOffset? exportedAt = null)
    {
        SchemaVersion = schemaVersion;
        ExportedAt = exportedAt ?? DateTimeOffset.UtcNow;
        Snippets = snippets;
    }
}
